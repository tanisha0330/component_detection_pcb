# app/ml_pipeline.py
import os
import json
import cv2
import numpy as np
import supervision as sv
from PIL import Image, ImageOps
from fastapi import APIRouter, Depends, UploadFile, File, HTTPException
from sqlalchemy.orm import Session
from ultralytics import YOLOE
from ultralytics.models.yolo.yoloe.predict_vp import YOLOEVPSegPredictor

from . import models, database

router = APIRouter()

# 1. Load the Phase 1 Alignment Model Globally
print("Loading Base YOLOE Alignment Model...")
try:
    align_model = YOLOE("yoloe-v8l-seg.pt").cuda()
except Exception as e:
    print(f"CUDA initialization failed, falling back to CPU: {e}")
    align_model = YOLOE("yoloe-v8l-seg.pt")

align_model.set_classes(["ARDUINO"], align_model.get_text_pe(["ARDUINO"]))

def order_points(pts):
    rect = np.zeros((4, 2), dtype="float32")
    s = pts.sum(axis=1)
    rect[0] = pts[np.argmin(s)]
    rect[2] = pts[np.argmax(s)]
    diff = np.diff(pts, axis=1)
    rect[1] = pts[np.argmin(diff)]
    rect[3] = pts[np.argmax(diff)]
    return rect

@router.post("/projects/{project_id}/inference")
async def run_inference(
    project_id: int,
    file: UploadFile = File(...),
    db: Session = Depends(database.get_db)
):
    detections = []
    unique_labels = []

    project = db.query(models.Project).filter(models.Project.id == project_id).first()
    if not project or not project.prototype_path:
        raise HTTPException(status_code=400, detail="Prototype missing.")

    boxes_db = db.query(models.BoundingBox).filter(models.BoundingBox.project_id == project_id).all()
    if not boxes_db:
        raise HTTPException(status_code=400, detail="No prompt boxes found.")

    target_path = os.path.join("storage/samples", f"raw_{project_id}_{file.filename}")
    with open(target_path, "wb") as buffer:
        buffer.write(await file.read())

    try:
        source_image = Image.open(project.prototype_path).convert("RGB")
        source_image = ImageOps.exif_transpose(source_image)
        
        unique_labels = list(set([box.label for box in boxes_db]))
        bboxes = np.array([[box.x1, box.y1, box.x2, box.y2] for box in boxes_db], dtype=np.float64)
        
        proto_w, proto_h = source_image.size
        if np.any(bboxes[:, [0, 2]] > proto_w) or np.any(bboxes[:, [1, 3]] > proto_h):
            scale_x = proto_w / np.max(bboxes[:, 2])
            scale_y = proto_h / np.max(bboxes[:, 3])
            bboxes[:, [0, 2]] *= scale_x
            bboxes[:, [1, 3]] *= scale_y
            print(f"Rescaled bboxes: scale_x={scale_x:.4f}, scale_y={scale_y:.4f}")
            
        bboxes[:, [0, 2]] = np.clip(bboxes[:, [0, 2]], 0, proto_w)
        bboxes[:, [1, 3]] = np.clip(bboxes[:, [1, 3]], 0, proto_h)
        
        cls = np.array([unique_labels.index(box.label) for box in boxes_db], dtype=np.int32)
        prompts = dict(bboxes=bboxes, cls=cls)
        
        target_image_pil = Image.open(target_path).convert("RGB")
        target_image_pil = ImageOps.exif_transpose(target_image_pil)
        
        raw_target_cv = cv2.cvtColor(np.array(target_image_pil), cv2.COLOR_RGB2BGR)

        # =================================================================
        # PHASE 1: ALIGNMENT (WITH FALLBACK)
        # =================================================================
        align_results = align_model.predict(target_image_pil, conf=0.1, verbose=False)
        align_detections = sv.Detections.from_ultralytics(align_results[0])
        aligned_target_pil = target_image_pil 

        if align_detections.mask is not None and len(align_detections.mask) > 0:
            mask = (align_detections.mask[0] * 255).astype(np.uint8)
            y_idx, x_idx = np.where(mask > 0)
            if len(y_idx) > 0:
                pts = np.column_stack((x_idx, y_idx))
                rect = cv2.minAreaRect(pts)
                box = np.intp(cv2.boxPoints(rect))
                corners = order_points(box)
                
                (tl, tr, br, bl) = corners
                maxWidth = max(int(np.linalg.norm(br-bl)), int(np.linalg.norm(tr-tl)))
                maxHeight = max(int(np.linalg.norm(tr-br)), int(np.linalg.norm(tl-bl)))
                
                dst = np.array([[0,0], [maxWidth-1,0], [maxWidth-1,maxHeight-1], [0,maxHeight-1]], dtype="float32")
                M = cv2.getPerspectiveTransform(corners, dst)
                aligned_target_cv = cv2.warpPerspective(raw_target_cv, M, (maxWidth, maxHeight))
                aligned_target_pil = Image.fromarray(cv2.cvtColor(aligned_target_cv, cv2.COLOR_BGR2RGB))

        # =================================================================
        # PHASE 2: INFERENCE
        # =================================================================
        try:
            vp_model = YOLOE("yoloe-v8l-seg.pt").cuda()
        except:
            vp_model = YOLOE("yoloe-v8l-seg.pt")

        vp_model.predict(source_image, prompts=prompts, predictor=YOLOEVPSegPredictor, return_vpe=True)
        vp_model.set_classes(unique_labels, vp_model.predictor.vpe)
        vp_model.predictor = None  

        inference_results = vp_model.predict(aligned_target_pil, conf=0.15, iou=0.4, verbose=False)
        detections = sv.Detections.from_ultralytics(inference_results[0])

        annotated_image = np.array(aligned_target_pil.copy())
        if len(detections) > 0:
            annotated_image = sv.BoxAnnotator().annotate(scene=annotated_image, detections=detections)
            annotated_image = sv.LabelAnnotator().annotate(scene=annotated_image, detections=detections)

        result_filename = f"result_{project_id}_{file.filename}"
        cv2.imwrite(os.path.join("storage/samples", result_filename), cv2.cvtColor(annotated_image, cv2.COLOR_RGB2BGR))

        del vp_model
        import torch
        torch.cuda.empty_cache()

    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

    return {
        "status": "success",
        "detections_count": len(detections),
        "annotated_output_url": f"/storage/samples/{result_filename}"
    }