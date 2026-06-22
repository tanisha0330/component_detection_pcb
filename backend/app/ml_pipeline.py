import os
import uuid
import gc
import json
import cv2
import asyncio
import numpy as np
import supervision as sv
import torch
from PIL import Image, ImageOps
from fastapi import APIRouter, Depends, UploadFile, File, HTTPException
from sqlalchemy.orm import Session
from ultralytics import YOLOE, YOLO
from ultralytics.models.yolo.yoloe.predict_vp import YOLOEVPSegPredictor
from pydantic import BaseModel
from typing import List

from . import models, database

router = APIRouter()
inference_lock = asyncio.Lock()

# ─────────────────────────────────────────────────────────────
# Per-class minimum confidence thresholds for YOLOE VP.
# Capacitor is intentionally absent — it is handled by the
# trained YOLOv10 model instead.
# ─────────────────────────────────────────────────────────────
YOLOE_CLASS_THRESHOLDS: dict[str, float] = {
    "led":                       0.116,
    "resistor":                  0.114,
    "ic":                        0.160,
    "transistor":                0.140,
    "switch":                    0.120,
    "headers":                   0.110,
    "microcontroller":           0.120,
    "icsp":                      0.140,
    "atmega328 microcontroller": 0.140,
    "crystal oscillator":        0.165,
    "voltage regulator":         0.160,
    "r105":                      0.170,
    "comp1":                     0.113,
    "comp2":                     0.160,
    "comp3":                     0.160,
    "usb":                       0.170,
    "dc":                        0.160,
}

# Trained model confidence threshold (for capacitor detection)
TRAINED_CONF_THRESHOLD = 0.20

# ─────────────────────────────────────────────────────────────
# Pydantic schemas
# ─────────────────────────────────────────────────────────────

class BoundingBoxIn(BaseModel):
    label: str
    x1: float
    y1: float
    x2: float
    y2: float


class BoundingBoxListIn(BaseModel):
    boxes: List[BoundingBoxIn]


class BoundingBoxOut(BaseModel):
    id: int
    label: str
    x1: float
    y1: float
    x2: float
    y2: float

    class Config:
        from_attributes = True


# ─────────────────────────────────────────────────────────────
# CRUD endpoints
# ─────────────────────────────────────────────────────────────

@router.get("/projects/{project_id}/boxes", response_model=List[BoundingBoxOut])
def get_boxes(project_id: int, db: Session = Depends(database.get_db)):
    print(f"Step: Fetching boxes for project {project_id}...")
    project = db.query(models.Project).filter(models.Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")
    return db.query(models.BoundingBox).filter(
        models.BoundingBox.project_id == project_id
    ).all()


@router.put("/projects/{project_id}/boxes", response_model=List[BoundingBoxOut])
def save_boxes(
    project_id: int,
    payload: BoundingBoxListIn,
    db: Session = Depends(database.get_db),
):
    print(f"Step: Saving {len(payload.boxes)} boxes for project {project_id}...")
    project = db.query(models.Project).filter(models.Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")
    db.query(models.BoundingBox).filter(
        models.BoundingBox.project_id == project_id
    ).delete()
    db.flush()
    new_boxes = []
    for b in payload.boxes:
        box = models.BoundingBox(
            project_id=project_id,
            label=b.label,
            x1=b.x1, y1=b.y1, x2=b.x2, y2=b.y2,
        )
        db.add(box)
        new_boxes.append(box)
    db.commit()
    for box in new_boxes:
        db.refresh(box)

    # --- DEBUG: Draw saved boxes on prototype ---
    if project.prototype_path and os.path.exists(project.prototype_path):
        try:
            source_image = Image.open(project.prototype_path).convert("RGB")
            source_image = ImageOps.exif_transpose(source_image)
            debug_proto = np.array(source_image)
            
            for b in payload.boxes:
                x1, y1, x2, y2 = map(int, [b.x1, b.y1, b.x2, b.y2])
                cv2.rectangle(debug_proto, (x1, y1), (x2, y2), (0, 0, 255), 3)
                cv2.putText(debug_proto, b.label, (x1, y1 - 10),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
            
            os.makedirs("storage/samples", exist_ok=True)
            cv2.imwrite("storage/samples/debug_save_boxes.jpg",
                        cv2.cvtColor(debug_proto, cv2.COLOR_RGB2BGR))
            print("Saved debug_save_boxes.jpg")
        except Exception as e:
            print(f"Failed to generate debug image: {e}")
    # --------------------------------------------

    return new_boxes


# ─────────────────────────────────────────────────────────────
# Device detection
# ─────────────────────────────────────────────────────────────
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
print(f"ML Pipeline running on: {DEVICE.upper()}")
if DEVICE == "cuda":
    print(f"   GPU : {torch.cuda.get_device_name(0)}")
    print(f"   VRAM: {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB")


# ─────────────────────────────────────────────────────────────
# Load models ONCE at startup
# ─────────────────────────────────────────────────────────────
print("Loading Phase 1 Alignment Model (align_model)...")
align_model = YOLOE("yoloe-v8l-seg.pt")
if DEVICE == "cuda":
    align_model = align_model.cuda()
align_model.set_classes(["ARDUINO"], align_model.get_text_pe(["ARDUINO"]))
print("  align_model ready")

print("Loading Phase 2 VP Inference Model (vp_model)...")
vp_model = YOLOE("yoloe-v8l-seg.pt")
if DEVICE == "cuda":
    vp_model = vp_model.cuda()
print("  vp_model ready")

print("Loading Phase 3 Trained Model (trained_model)...")
trained_model = YOLO("yolov10n_pcb_10classes_best.pt")
if DEVICE == "cuda":
    trained_model = trained_model.cuda()
print(f"  trained_model ready — classes: {trained_model.names}")


# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

def order_points(pts):
    rect = np.zeros((4, 2), dtype="float32")
    s = pts.sum(axis=1)
    rect[0] = pts[np.argmin(s)]
    rect[2] = pts[np.argmax(s)]
    diff = np.diff(pts, axis=1)
    rect[1] = pts[np.argmin(diff)]
    rect[3] = pts[np.argmax(diff)]
    return rect


def normalize_bboxes_to_image(bboxes: np.ndarray, img_w: int, img_h: int) -> np.ndarray:
    bboxes = bboxes.copy()
    x_coords = np.sort(bboxes[:, [0, 2]], axis=1)
    y_coords = np.sort(bboxes[:, [1, 3]], axis=1)
    bboxes[:, [0, 2]] = x_coords
    bboxes[:, [1, 3]] = y_coords
    bboxes[:, [0, 2]] = np.clip(bboxes[:, [0, 2]], 0, img_w)
    bboxes[:, [1, 3]] = np.clip(bboxes[:, [1, 3]], 0, img_h)
    return bboxes


def log_bboxes(bboxes: np.ndarray, labels: list, img_w: int, img_h: int):
    print(f"\n  Proto image : {img_w} × {img_h} px")
    for i, (box, label) in enumerate(zip(bboxes, labels)):
        w = box[2] - box[0]
        h = box[3] - box[1]
        area_pct = (w * h) / (img_w * img_h) * 100
        flag = ""
        if area_pct < 0.1:
            flag = "  [Warning] <0.1% area — likely coordinate mismatch!"
        elif area_pct > 50:
            flag = "  [Warning] >50% area — box may be too large!"
        print(
            f"  Box [{i}] {label:25s}: ({box[0]:.0f},{box[1]:.0f}) → "
            f"({box[2]:.0f},{box[3]:.0f})  "
            f"{w:.0f}×{h:.0f}px  area={area_pct:.2f}%{flag}"
        )


def filter_yoloe_by_threshold(
    detections: sv.Detections,
    class_names: list[str],
) -> sv.Detections:
    """
    Keep only detections whose confidence meets the per-class minimum
    defined in YOLOE_CLASS_THRESHOLDS. Classes not listed in the dict
    use a default threshold of 0.10.
    """
    if len(detections) == 0:
        return detections

    keep = []
    for i, (cls_id, conf) in enumerate(
        zip(detections.class_id, detections.confidence)
    ):
        label = class_names[int(cls_id)].lower()
        min_conf = YOLOE_CLASS_THRESHOLDS.get(label, 0.10)
        passes = bool(conf >= min_conf)
        if passes:
            keep.append(i)
        else:
            print(
                f"    [filtered] {label} conf={conf:.3f} < threshold {min_conf:.2f}"
            )

    if not keep:
        return sv.Detections.empty()

    return sv.Detections(
        xyxy=detections.xyxy[keep],
        confidence=detections.confidence[keep],
        class_id=detections.class_id[keep],
        mask=detections.mask[keep] if detections.mask is not None else None,
    )


# ─────────────────────────────────────────────────────────────
# Inference endpoint
# ─────────────────────────────────────────────────────────────

@router.post("/projects/{project_id}/inference")
async def run_inference(
    project_id: int,
    file: UploadFile = File(...),
    db: Session = Depends(database.get_db),
):
    global vp_model
    
    async with inference_lock:
        final_detections_count = 0
        result_filename = None

        # ── Validate project ──────────────────────────────────────
        print("Step: Validating project...")
        project = db.query(models.Project).filter(models.Project.id == project_id).first()
        if not project or not project.prototype_path:
            raise HTTPException(status_code=400, detail="Prototype missing.")

        # ── Resolve bounding boxes directly from Database ─────────
        print("\n── Bounding Box Source ──────────────────────────────────────")
        boxes_db = db.query(models.BoundingBox).filter(
            models.BoundingBox.project_id == project_id
        ).all()
        if not boxes_db:
            raise HTTPException(status_code=400, detail="No prompt boxes found.")
        
        raw_box_dicts = [
            {"label": b.label, "x1": b.x1, "y1": b.y1, "x2": b.x2, "y2": b.y2}
            for b in boxes_db
        ]
        print(f"  Source: database ({len(raw_box_dicts)} boxes)")

        # ── Save uploaded target image ────────────────────────────
        run_id = uuid.uuid4().hex[:8]
        unique_filename = f"{run_id}_{file.filename}"
        target_path = os.path.join("storage/samples", f"raw_{project_id}_{unique_filename}")
        print(f"Step: Saving uploaded target image to {target_path}...")
        with open(target_path, "wb") as buffer:
            buffer.write(await file.read())

        try:
            # ── Load prototype ────────────────────────────────────
            print("Step: Loading prototype image...")
            source_image = Image.open(project.prototype_path).convert("RGB")
            print(f"Prototype size before EXIF: {source_image.size}")
            source_image = ImageOps.exif_transpose(source_image)
            print(f"Prototype size after EXIF:  {source_image.size}")
            proto_w, proto_h = source_image.size

            # ── Build prompt bboxes (no capacitor) ───────────────
            print("Step: Building prompt bboxes (excluding capacitors)...")
            # Filter out any "capacitor" boxes — those are handled
            # exclusively by the trained model in Phase 3.
            prompt_box_dicts = [
                b for b in raw_box_dicts
                if b["label"].lower() != "capacitor"
            ]
            capacitor_box_count = len(raw_box_dicts) - len(prompt_box_dicts)
            if capacitor_box_count:
                print(
                    f"  Info: Excluded {capacitor_box_count} capacitor box(es) from "
                    "YOLOE prompts (handled by trained model)"
                )

            unique_labels = sorted(set(b["label"] for b in prompt_box_dicts))
            print(f"  YOLOE prompt classes: {unique_labels}")

            raw_bboxes = np.array(
                [[b["x1"], b["y1"], b["x2"], b["y2"]] for b in prompt_box_dicts],
                dtype=np.float64,
            )
            bboxes = normalize_bboxes_to_image(raw_bboxes, proto_w, proto_h)
            log_bboxes(bboxes, [b["label"] for b in prompt_box_dicts], proto_w, proto_h)

            cls_arr = np.array(
                [unique_labels.index(b["label"]) for b in prompt_box_dicts],
                dtype=np.int32,
            )
            prompts = dict(bboxes=bboxes, cls=cls_arr)

            # Draw the prompt boxes ON the prototype and save it
            debug_proto = np.array(source_image.copy())
            for box, label in zip(bboxes, [b["label"] for b in prompt_box_dicts]):
                x1, y1, x2, y2 = map(int, box)
                cv2.rectangle(debug_proto, (x1, y1), (x2, y2), (0, 255, 0), 3)
                cv2.putText(debug_proto, label, (x1, y1 - 10),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
            cv2.imwrite("storage/samples/debug_prompt_boxes.jpg",
                        cv2.cvtColor(debug_proto, cv2.COLOR_RGB2BGR))

            # ── Load target image ─────────────────────────────────
            print("Step: Loading target image for processing...")
            target_image_pil = Image.open(target_path).convert("RGB")
            print(f"Target size before EXIF: {target_image_pil.size}")
            target_image_pil = ImageOps.exif_transpose(target_image_pil)
            print(f"Target size after EXIF:  {target_image_pil.size}")
            raw_target_cv = cv2.cvtColor(np.array(target_image_pil), cv2.COLOR_RGB2BGR)

            # =====================================================================
            # PHASE 1: ALIGNMENT
            # =====================================================================
            print("\n── Phase 1: Alignment ───────────────────────────────────────")
            align_results = align_model.predict(target_image_pil, conf=0.1, verbose=False)
            align_detections = sv.Detections.from_ultralytics(align_results[0])

            aligned_target_pil = target_image_pil
            aligned_target_cv = raw_target_cv

            if align_detections.mask is not None and len(align_detections.mask) > 0:
                conf_val = (
                    align_detections.confidence[0]
                    if align_detections.confidence is not None
                    else 0
                )
                print(f"  Board detected (conf={conf_val:.3f}) — applying perspective warp")
                mask = (align_detections.mask[0] * 255).astype(np.uint8)
                y_idx, x_idx = np.where(mask > 0)
                if len(y_idx) > 0:
                    pts = np.column_stack((x_idx, y_idx))
                    rect = cv2.minAreaRect(pts)
                    box = np.intp(cv2.boxPoints(rect))
                    corners = order_points(box)
                    (tl, tr, br, bl) = corners
                    maxWidth = max(
                        int(np.linalg.norm(br - bl)), int(np.linalg.norm(tr - tl))
                    )
                    maxHeight = max(
                        int(np.linalg.norm(tr - br)), int(np.linalg.norm(tl - bl))
                    )
                    dst = np.array(
                        [
                            [0, 0],
                            [maxWidth - 1, 0],
                            [maxWidth - 1, maxHeight - 1],
                            [0, maxHeight - 1],
                        ],
                        dtype="float32",
                    )
                    M = cv2.getPerspectiveTransform(corners, dst)
                    aligned_target_cv = cv2.warpPerspective(
                        raw_target_cv, M, (maxWidth, maxHeight)
                    )
                    aligned_target_pil = Image.fromarray(
                        cv2.cvtColor(aligned_target_cv, cv2.COLOR_BGR2RGB)
                    )
                    print(f"  Aligned size: {aligned_target_pil.size}")
                    aligned_target_pil.save("storage/samples/debug_aligned.jpg")
                    print("  debug_aligned.jpg saved")
            else:
                print("  No board detected — using original image (no warp applied)")

            # =====================================================================
            # PHASE 2: YOLOE VISUAL PROMPTING (all classes except capacitor)
            # =====================================================================
            print("\n── Phase 2: YOLOE VP Inference ──────────────────────────────")
            print(f"  unique_labels : {unique_labels}")
            print(f"  num prompts   : {len(bboxes)}")

            print("  Step 0: Reloading fresh VP model to clear old memory...")
            del vp_model
            gc.collect()
            if DEVICE == "cuda":
                torch.cuda.empty_cache()
                
            vp_model = YOLOE("yoloe-v8l-seg.pt")
            if DEVICE == "cuda":
                vp_model = vp_model.cuda()

            print("  Resizing model architecture to match prompt classes...")
            vp_model.set_classes(unique_labels, vp_model.get_text_pe(unique_labels))

            # Step 1: Encode visual prompt embeddings from the PROTOTYPE image
            print("  Step 1: Encoding VPE from prototype...")
            vp_model.predict(
                source_image,
                prompts=prompts,
                predictor=YOLOEVPSegPredictor,
                return_vpe=True,
                verbose=False,
                imgsz=(640, 640),
            )

            # Verify the right predictor was attached
            predictor_type = type(vp_model.predictor).__name__
            print(f"  Predictor type after VPE encode: {predictor_type}")
            if not hasattr(vp_model.predictor, 'vpe'):
                raise RuntimeError(
                    f"VPE encoding failed — predictor is '{predictor_type}', not YOLOEVPSegPredictor. "
                    "Check your ultralytics/yoloe version."
                )

            # Step 2: Save learned features as named classes inside the model
            print("  Step 2: Saving VPE as named classes...")
            vp_model.set_classes(unique_labels, vp_model.predictor.vpe)

            # Step 3: Remove VP predictor — revert to standard detection mode
            vp_model.predictor = None
            print("  Step 3: VP predictor removed, switching to standard inference...")

            # Step 4: Run inference on the ALIGNED TARGET image
            print("  Step 4: Running inference on target image...")
            inference_results = vp_model.predict(
                aligned_target_pil,
                conf=0.05,
                iou=0.4,
                verbose=False,
                imgsz=(640, 640),
            )
            raw_yoloe_detections = sv.Detections.from_ultralytics(inference_results[0])
            print(f"  Raw YOLOE detections : {len(raw_yoloe_detections)}")

            # Apply per-class confidence thresholds
            yoloe_detections = filter_yoloe_by_threshold(raw_yoloe_detections, unique_labels)
            print(f"  After threshold filter: {len(yoloe_detections)} detections kept")

            if len(yoloe_detections) > 0:
                for i, (cls_id, conf, bbox) in enumerate(
                    zip(
                        yoloe_detections.class_id,
                        yoloe_detections.confidence,
                        yoloe_detections.xyxy,
                    )
                ):
                    label = (
                        unique_labels[cls_id]
                        if cls_id < len(unique_labels)
                        else f"cls{cls_id}"
                    )
                    print(
                        f"  [{i}] {label:25s} conf={conf:.3f}  "
                        f"bbox={np.array(bbox).astype(int)}"
                    )
            else:
                print("  Warning: YOLOE returned 0 detections after threshold filtering.")

            # =====================================================================
            # PHASE 3: CAPACITOR DETECTION via trained model (full aligned image)
            # =====================================================================
            print("\n── Phase 3: Capacitor Detection (Trained Model) ─────────────")
            trained_results = trained_model.predict(
                aligned_target_pil, conf=TRAINED_CONF_THRESHOLD, verbose=False
            )
            trained_detections_all = sv.Detections.from_ultralytics(trained_results[0])
            print(f"  Trained model detections (all classes): {len(trained_detections_all)}")

            # Keep only capacitor detections from the trained model
            capacitor_class_ids = [
                idx
                for idx, name in trained_model.names.items()
                if name.lower() == "capacitor"
            ]
            if capacitor_class_ids:
                cap_mask = np.isin(trained_detections_all.class_id, capacitor_class_ids)
                cap_indices = np.where(cap_mask)[0].tolist()
                if cap_indices:
                    capacitor_detections = sv.Detections(
                        xyxy=trained_detections_all.xyxy[cap_indices],
                        confidence=trained_detections_all.confidence[cap_indices],
                        class_id=trained_detections_all.class_id[cap_indices],
                    )
                else:
                    capacitor_detections = sv.Detections.empty()
            else:
                print(
                    "  Warning: 'capacitor' class not found in trained model — "
                    "check model class names"
                )
                capacitor_detections = sv.Detections.empty()

            print(f"  Capacitor detections kept: {len(capacitor_detections)}")
            for i, (cls_id, conf, bbox) in enumerate(
                zip(
                    capacitor_detections.class_id,
                    capacitor_detections.confidence,
                    capacitor_detections.xyxy,
                )
            ):
                label = trained_model.names[int(cls_id)].upper()
                print(
                    f"  [{i}] {label:25s} conf={conf:.3f}  "
                    f"bbox={np.array(bbox).astype(int)}"
                )

            # =====================================================================
            # PHASE 4: MERGE DETECTIONS
            # =====================================================================
            print("\n── Phase 4: Merge Detections ────────────────────────────────")

            final_boxes: list = []
            final_confs: list = []
            final_labels_text: list = []
            raw_detections: list = []

            # Add YOLOE VP detections (non-capacitor components)
            for cls_id, conf, bbox in zip(
                yoloe_detections.class_id,
                yoloe_detections.confidence,
                yoloe_detections.xyxy,
            ):
                label = (
                    unique_labels[cls_id]
                    if cls_id < len(unique_labels)
                    else f"cls{cls_id}"
                )
                final_boxes.append(bbox)
                final_confs.append(float(conf))
                final_labels_text.append(f"{label.upper()} ({conf:.2f})")
                raw_detections.append({
                    "label": label.upper(),
                    "conf": float(conf),
                    "bbox": bbox.tolist()
                })

            # Add capacitor detections from trained model
            for cls_id, conf, bbox in zip(
                capacitor_detections.class_id,
                capacitor_detections.confidence,
                capacitor_detections.xyxy,
            ):
                label = trained_model.names[int(cls_id)].upper()
                final_boxes.append(bbox)
                final_confs.append(float(conf))
                final_labels_text.append(f"{label} ({conf:.2f})")
                raw_detections.append({
                    "label": label,
                    "conf": float(conf),
                    "bbox": bbox.tolist()
                })

            final_detections_count = len(final_boxes)
            print(f"  Total final detections: {final_detections_count}")

            # =====================================================================
            # PHASE 5: ANNOTATE + SAVE
            # =====================================================================
            print("\n── Phase 5: Annotation ──────────────────────────────────────")
            annotated_image = np.array(aligned_target_pil.copy())

            if final_detections_count > 0:
                final_detections = sv.Detections(
                    xyxy=np.array(final_boxes, dtype=np.float32),
                    confidence=np.array(final_confs, dtype=np.float32),
                    class_id=np.zeros(final_detections_count, dtype=np.int32),
                )
                box_annotator = sv.BoxAnnotator()
                label_annotator = sv.LabelAnnotator(text_scale=0.4, text_padding=5)
                annotated_image = box_annotator.annotate(
                    scene=annotated_image, detections=final_detections
                )
                annotated_image = label_annotator.annotate(
                    scene=annotated_image,
                    detections=final_detections,
                    labels=final_labels_text,
                )

            result_filename = f"result_{project_id}_{unique_filename}"
            out_path = os.path.join("storage/samples", result_filename)
            cv2.imwrite(out_path, cv2.cvtColor(annotated_image, cv2.COLOR_RGB2BGR))
            print(f"  Saved → {out_path}")

            raw_aligned_filename = f"aligned_raw_{project_id}_{unique_filename}"
            raw_aligned_path = os.path.join("storage/samples", raw_aligned_filename)
            aligned_target_pil.save(raw_aligned_path)

            # Save to database
            db_sample = models.Sample(
                project_id=project_id,
                original_path=f"/storage/samples/{raw_aligned_filename}",
                annotated_path=f"/storage/samples/{result_filename}",
                results_data=json.dumps(raw_detections),
                status="completed"
            )
            db.add(db_sample)
            db.commit()
            db.refresh(db_sample)

        except Exception as e:
            import traceback
            traceback.print_exc()
            raise HTTPException(status_code=500, detail=str(e))

        return {
            "status": "success",
            "sample": {
                "id": db_sample.id,
                "project_id": db_sample.project_id,
                "original_path": db_sample.original_path,
                "annotated_path": db_sample.annotated_path,
                "results_data": db_sample.results_data,
                "timestamp": db_sample.timestamp.isoformat()
            }
        }