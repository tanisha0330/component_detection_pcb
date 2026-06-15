# app/ml_pipeline.py
import os
import cv2
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

@router.get("/projects/{project_id}/boxes", response_model=List[BoundingBoxOut])
def get_boxes(project_id: int, db: Session = Depends(database.get_db)):
    project = db.query(models.Project).filter(models.Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")
    boxes = db.query(models.BoundingBox).filter(
        models.BoundingBox.project_id == project_id
    ).all()
    return boxes

@router.put("/projects/{project_id}/boxes", response_model=List[BoundingBoxOut])
def save_boxes(
    project_id: int,
    payload: BoundingBoxListIn,
    db: Session = Depends(database.get_db)
):
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
    return new_boxes

# ─────────────────────────────────────────────────────────────
# Device detection
# ─────────────────────────────────────────────────────────────
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
print(f"🖥️  ML Pipeline running on: {DEVICE.upper()}")
if DEVICE == "cuda":
    print(f"   GPU : {torch.cuda.get_device_name(0)}")
    print(f"   VRAM: {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB")

def load_to_device(model):
    return model.cuda() if DEVICE == "cuda" else model

# ─────────────────────────────────────────────────────────────
# Load models ONCE at startup
# ─────────────────────────────────────────────────────────────
print("Loading Phase 1 Alignment Model (align_model)...")
align_model = load_to_device(YOLOE("yoloe-v8l-seg.pt"))
align_model.set_classes(["ARDUINO"], align_model.get_text_pe(["ARDUINO"]))
print("  ✅ align_model ready")

print("Loading Phase 2 VP Inference Model (vp_model)...")
vp_model = load_to_device(YOLOE("yoloe-v8l-seg.pt"))
print("  ✅ vp_model ready")

print("Loading Phase 3 Classification Model (trained_model)...")
trained_model = load_to_device(YOLO("yolov10n_pcb_10classes_best.pt"))
print(f"  ✅ trained_model ready — classes: {trained_model.names}")


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

def calculate_iou(boxA, boxB):
    xA = max(boxA[0], boxB[0])
    yA = max(boxA[1], boxB[1])
    xB = min(boxA[2], boxB[2])
    yB = min(boxA[3], boxB[3])

    interArea = max(0, xB - xA) * max(0, yB - yA)
    boxAArea = (boxA[2] - boxA[0]) * (boxA[3] - boxA[1])
    boxBArea = (boxB[2] - boxB[0]) * (boxB[3] - boxB[1])

    if float(boxAArea + boxBArea - interArea) == 0:
        return 0.0
        
    return interArea / float(boxAArea + boxBArea - interArea)


def normalize_bboxes_to_image(bboxes: np.ndarray, img_w: int, img_h: int) -> np.ndarray:
    """
    Since the Flutter frontend is now sending true image pixel coordinates,
    we only need to fix any inverted coordinates and clip them to the image bounds.
    """
    bboxes = bboxes.copy()
    
    # 1. Fix inverted boxes (ensure xmin < xmax and ymin < ymax)
    x_coords = np.sort(bboxes[:, [0, 2]], axis=1)
    y_coords = np.sort(bboxes[:, [1, 3]], axis=1)
    bboxes[:, [0, 2]] = x_coords
    bboxes[:, [1, 3]] = y_coords
    
    # 2. Clip to bounds
    bboxes[:, [0, 2]] = np.clip(bboxes[:, [0, 2]], 0, img_w)
    bboxes[:, [1, 3]] = np.clip(bboxes[:, [1, 3]], 0, img_h)
    return bboxes


def log_bboxes(bboxes: np.ndarray, labels: list, img_w: int, img_h: int):
    """Print bbox positions with area % so coordinate issues are immediately visible."""
    print(f"\n  Proto image : {img_w} × {img_h} px")
    for i, (box, label) in enumerate(zip(bboxes, labels)):
        w = box[2] - box[0]
        h = box[3] - box[1]
        area_pct = (w * h) / (img_w * img_h) * 100
        flag = ""
        if area_pct < 0.1:
            flag = "  ⚠️  <0.1% area — likely coordinate mismatch!"
        elif area_pct > 50:
            flag = "  ⚠️  >50% area — box may be too large!"
        print(
            f"  Box [{i}] {label:15s}: ({box[0]:.0f},{box[1]:.0f}) → "
            f"({box[2]:.0f},{box[3]:.0f})  "
            f"{w:.0f}×{h:.0f}px  area={area_pct:.2f}%{flag}"
        )


def classify_crop(crop_bgr: np.ndarray) -> tuple[str, float]:
    """
    Classify a single BGR crop.
    Converts to PIL (matching Colab behaviour) and uses conf=0.01.
    Since YOLOE already localized the object, we just want the most likely class.
    """
    if crop_bgr.size == 0:
        return "NONE", 0.0
        
    crop_pil = Image.fromarray(cv2.cvtColor(crop_bgr, cv2.COLOR_BGR2RGB))
    
    preds  = trained_model.predict(source=crop_pil, conf=0.01, verbose=False)
    result = preds[0]

    if len(result.boxes) == 0:
        return "NONE", 0.0

    t_confs   = result.boxes.conf.cpu().numpy()
    t_cls_ids = result.boxes.cls.cpu().numpy()
    best_idx  = int(np.argmax(t_confs))
    label     = trained_model.names[int(t_cls_ids[best_idx])].upper()
    conf      = float(t_confs[best_idx])
    return label, conf


# ─────────────────────────────────────────────────────────────
# Endpoint
# ─────────────────────────────────────────────────────────────
@router.post("/projects/{project_id}/inference")
async def run_inference(
    project_id: int,
    file: UploadFile = File(...),
    db: Session = Depends(database.get_db)
):
    final_detections_count = 0
    result_filename        = None

    # ── Validate project & boxes ──────────────────────────────────────────────
    project = db.query(models.Project).filter(models.Project.id == project_id).first()
    if not project or not project.prototype_path:
        raise HTTPException(status_code=400, detail="Prototype missing.")

    boxes_db = db.query(models.BoundingBox).filter(
        models.BoundingBox.project_id == project_id
    ).all()
    if not boxes_db:
        raise HTTPException(status_code=400, detail="No prompt boxes found.")

    # ── Save uploaded target image ────────────────────────────────────────────
    target_path = os.path.join("storage/samples", f"raw_{project_id}_{file.filename}")
    with open(target_path, "wb") as buffer:
        buffer.write(await file.read())

    try:
        # ── Load prototype (reference) image ──────────────────────────────────
        source_image = Image.open(project.prototype_path).convert("RGB")
        source_image = ImageOps.exif_transpose(source_image)
        proto_w, proto_h = source_image.size

        # ── Build + normalize prompt bounding boxes ───────────────────────────
        # sorted() guarantees stable label→index mapping across calls
        unique_labels = sorted(set([box.label for box in boxes_db]))

        raw_bboxes = np.array(
            [[box.x1, box.y1, box.x2, box.y2] for box in boxes_db],
            dtype=np.float64
        )
        bboxes = normalize_bboxes_to_image(raw_bboxes, proto_w, proto_h)
        log_bboxes(bboxes, [b.label for b in boxes_db], proto_w, proto_h)

        cls_arr = np.array(
            [unique_labels.index(box.label) for box in boxes_db],
            dtype=np.int32
        )
        prompts = dict(bboxes=bboxes, cls=cls_arr)

        # ── Load target image ─────────────────────────────────────────────────
        target_image_pil = Image.open(target_path).convert("RGB")
        target_image_pil = ImageOps.exif_transpose(target_image_pil)
        raw_target_cv    = cv2.cvtColor(np.array(target_image_pil), cv2.COLOR_RGB2BGR)

        # =====================================================================
        # PHASE 1: ALIGNMENT
        # =====================================================================
        print("\n── Phase 1: Alignment ───────────────────────────────────────")
        align_results    = align_model.predict(target_image_pil, conf=0.1, verbose=False)
        align_detections = sv.Detections.from_ultralytics(align_results[0])

        aligned_target_pil = target_image_pil
        aligned_target_cv  = raw_target_cv

        if align_detections.mask is not None and len(align_detections.mask) > 0:
            conf_val = align_detections.confidence[0] if align_detections.confidence is not None else 0
            print(f"  Board detected (conf={conf_val:.3f}) — applying perspective warp")
            mask     = (align_detections.mask[0] * 255).astype(np.uint8)
            y_idx, x_idx = np.where(mask > 0)
            if len(y_idx) > 0:
                pts     = np.column_stack((x_idx, y_idx))
                rect    = cv2.minAreaRect(pts)
                box     = np.intp(cv2.boxPoints(rect))
                corners = order_points(box)

                (tl, tr, br, bl) = corners
                maxWidth  = max(int(np.linalg.norm(br - bl)), int(np.linalg.norm(tr - tl)))
                maxHeight = max(int(np.linalg.norm(tr - br)), int(np.linalg.norm(tl - bl)))

                dst = np.array(
                    [[0, 0], [maxWidth-1, 0], [maxWidth-1, maxHeight-1], [0, maxHeight-1]],
                    dtype="float32"
                )
                M = cv2.getPerspectiveTransform(corners, dst)
                aligned_target_cv  = cv2.warpPerspective(raw_target_cv, M, (maxWidth, maxHeight))
                aligned_target_pil = Image.fromarray(
                    cv2.cvtColor(aligned_target_cv, cv2.COLOR_BGR2RGB)
                )
                print(f"  Aligned size: {aligned_target_pil.size}")

                # Save debug aligned image
                aligned_target_pil.save("storage/samples/debug_aligned.jpg")
                print("  debug_aligned.jpg saved")
        else:
            print("  No board detected — using original image (no warp applied)")

        # =====================================================================
        # PHASE 2: YOLOE PROMPT INFERENCE
        # Mirrors Colab exactly:
        #   1. predict on source to build VPE — do NOT call set_classes() after
        #   2. predict on target WITH prompts= passed again
        # =====================================================================
        print("\n── Phase 2: YOLOE VP Inference ──────────────────────────────")
        print(f"  unique_labels : {unique_labels}")
        print(f"  num prompts   : {len(bboxes)}")

        vp_model.predict(
            source_image,
            prompts=prompts,
            predictor=YOLOEVPSegPredictor,
            return_vpe=True
        )

        inference_results = vp_model.predict(
            aligned_target_pil,
            prompts=prompts,   # ← must be passed again; do NOT call set_classes/reset predictor
            conf=0.1,
            iou=0.4,
            verbose=False
        )
        yoloe_detections = sv.Detections.from_ultralytics(inference_results[0])
        print(f"  YOLOE detections: {len(yoloe_detections)}")

        if len(yoloe_detections) == 0:
            print("  ⚠️  YOLOE returned 0 detections.")
            print("      Possible causes:")
            print("      • Bounding boxes are in the wrong coordinate space (check log above)")
            print("      • Prototype and target images are too visually different")
            print("      • Perspective warp in Phase 1 produced a bad crop (check debug_aligned.jpg)")
        else:
            for i, (cls_id, conf, bbox) in enumerate(zip(
                yoloe_detections.class_id,
                yoloe_detections.confidence,
                yoloe_detections.xyxy
            )):
                label = unique_labels[cls_id] if cls_id < len(unique_labels) else f"cls{cls_id}"
                print(f"  [{i}] {label:15s} conf={conf:.3f}  bbox={np.array(bbox).astype(int)}")

        # =====================================================================
        # PHASE 3: RUN TRAINED MODEL ON FULL IMAGE
        # =====================================================================
        print("\n── Phase 3: Trained Model (Full Image) ──────────────────────")
        trained_results = trained_model.predict(aligned_target_pil, conf=0.2, verbose=False)
        trained_detections = sv.Detections.from_ultralytics(trained_results[0])
        print(f"  Trained model detections: {len(trained_detections)}")

        final_boxes       = []
        final_class_ids   = []
        final_confs       = []
        final_labels_text = []

        # Add all trained model detections to final output
        for bbox, conf, cls_id in zip(trained_detections.xyxy, trained_detections.confidence, trained_detections.class_id):
            label = trained_model.names[int(cls_id)].upper()
            final_boxes.append(bbox)
            final_class_ids.append(int(cls_id)) 
            final_confs.append(float(conf))
            final_labels_text.append(f"T: {label} ({conf:.2f})")
            print(f"  [Trained] {label:15s} conf={conf:.3f}  bbox={np.array(bbox).astype(int)}")

        # =====================================================================
        # PHASE 4: COMBINE WITH YOLOE VP DETECTIONS
        # =====================================================================
        print("\n── Phase 4: Combine + Crop Supplemental ─────────────────────")
        img_h, img_w = aligned_target_cv.shape[:2]

        for i, (cls_id, yoloe_conf, vp_bbox) in enumerate(zip(
            yoloe_detections.class_id,
            yoloe_detections.confidence,
            yoloe_detections.xyxy
        )):
            # Check overlap with existing trained detections
            is_covered = False
            for t_bbox in trained_detections.xyxy:
                if calculate_iou(vp_bbox, t_bbox) > 0.3: # 30% overlap threshold
                    is_covered = True
                    break
            
            if is_covered:
                print(f"  VP Crop [{i}] skipped — already detected by trained model")
                continue

            x1, y1, x2, y2 = map(int, vp_bbox)
            
            # Expand the crop by 50px to provide visual context to the YOLO detection model
            pad = 50
            x1c = max(0, x1 - pad);      y1c = max(0, y1 - pad)
            x2c = min(img_w, x2 + pad);  y2c = min(img_h, y2 + pad)

            if x2c <= x1c or y2c <= y1c:
                print(f"  VP Crop [{i}] skipped — degenerate bbox after clamping")
                continue

            crop_bgr    = aligned_target_cv[y1c:y2c, x1c:x2c]
            yoloe_label = unique_labels[cls_id].upper() if cls_id < len(unique_labels) else f"CLS{cls_id}"
            yoloe_conf  = float(yoloe_conf)

            trained_label, trained_conf_crop = classify_crop(crop_bgr)

            label_text = (
                f"VP: {yoloe_label} | "
                f"T: {trained_label} ({trained_conf_crop:.2f})"
            )
            print(f"  VP Crop [{i}] {crop_bgr.shape[1]}×{crop_bgr.shape[0]}px  →  {label_text}")

            final_boxes.append(vp_bbox)
            final_class_ids.append(0)
            final_confs.append(yoloe_conf)
            final_labels_text.append(label_text)

        # =====================================================================
        # PHASE 5: ANNOTATE + SAVE
        # =====================================================================
        print("\n── Phase 5: Annotation ──────────────────────────────────────")
        annotated_image        = np.array(aligned_target_pil.copy())
        final_detections_count = len(final_boxes)
        print(f"  Final detections: {final_detections_count}")

        if final_detections_count > 0:
            final_detections = sv.Detections(
                xyxy=np.array(final_boxes,         dtype=np.float32),
                confidence=np.array(final_confs,   dtype=np.float32),
                class_id=np.array(final_class_ids, dtype=np.int32)
            )
            box_annotator   = sv.BoxAnnotator()
            label_annotator = sv.LabelAnnotator(text_scale=0.4, text_padding=5)
            annotated_image = box_annotator.annotate(
                scene=annotated_image, detections=final_detections
            )
            annotated_image = label_annotator.annotate(
                scene=annotated_image,
                detections=final_detections,
                labels=final_labels_text
            )

        result_filename = f"result_{project_id}_{file.filename}"
        out_path = os.path.join("storage/samples", result_filename)
        cv2.imwrite(out_path, cv2.cvtColor(annotated_image, cv2.COLOR_RGB2BGR))
        print(f"  Saved → {out_path}")

    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

    return {
        "status": "success",
        "detections_count": final_detections_count,
        "annotated_output_url": f"/storage/samples/{result_filename}"
    }