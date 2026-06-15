# test_pipeline.py  — run with: python test_pipeline.py
import torch, cv2, numpy as np
from PIL import Image, ImageOps
import supervision as sv
from ultralytics import YOLOE
from ultralytics.models.yolo.yoloe.predict_vp import YOLOEVPSegPredictor

PROTO_PATH  = "storage/project_1_proto.jpg"   # adjust
TARGET_PATH = "storage/samples/raw_1_sample.jpg"  # adjust

# Hardcode 2-3 boxes you drew manually — copy exact pixel coords from your Flutter UI
TEST_BOXES = np.array([
    [100, 150, 250, 280],   # replace with your actual box coords
    [300, 200, 420, 310],
], dtype=np.float64)
TEST_LABELS = ["capacitor", "resistor"]   # replace with your actual labels
TEST_CLS    = np.array([0, 1], dtype=np.int32)

source = Image.open(PROTO_PATH).convert("RGB")
target = Image.open(TARGET_PATH).convert("RGB")

print(f"Source size: {source.size}")
print(f"Target size: {target.size}")
print(f"Boxes: {TEST_BOXES}")

model = YOLOE("yoloe-v8l-seg.pt").cuda()
prompts = dict(bboxes=TEST_BOXES, cls=TEST_CLS)

model.predict(source, prompts=prompts, predictor=YOLOEVPSegPredictor, return_vpe=True)
results = model.predict(target, prompts=prompts, conf=0.1, iou=0.4, verbose=True)
dets = sv.Detections.from_ultralytics(results[0])

print(f"\nDetections: {len(dets)}")
for cls_id, conf, bbox in zip(dets.class_id, dets.confidence, dets.xyxy):
    print(f"  cls={TEST_LABELS[cls_id]}  conf={conf:.3f}  bbox={bbox}")