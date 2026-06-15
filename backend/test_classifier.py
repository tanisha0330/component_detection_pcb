import cv2
from PIL import Image
from ultralytics import YOLO

# Load model
model = YOLO("yolov10n_pcb_10classes_best.pt")

# Load the aligned image
img = cv2.imread("storage/samples/debug_aligned.jpg")

# The bbox from logs: TRANSISTOR bbox=[ 268 2029  343 2429] (x1, y1, x2, y2)
x1, y1, x2, y2 = 268, 2029, 343, 2429

# Crop
crop_bgr = img[y1:y2, x1:x2]

print("Crop shape:", crop_bgr.shape)

# Try different ways of predicting
print("--- 1. As BGR numpy ---")
res1 = model.predict(source=crop_bgr, conf=0.01, verbose=False)[0]
print(f"Detections: {len(res1.boxes)}")
if len(res1.boxes) > 0:
    print(res1.boxes.conf)
    print(res1.boxes.cls)

print("--- 2. As RGB PIL ---")
crop_pil = Image.fromarray(cv2.cvtColor(crop_bgr, cv2.COLOR_BGR2RGB))
res2 = model.predict(source=crop_pil, conf=0.01, verbose=False)[0]
print(f"Detections: {len(res2.boxes)}")
if len(res2.boxes) > 0:
    print(res2.boxes.conf)
    print(res2.boxes.cls)

print("--- 3. Expanded Crop (context) ---")
pad = 50
crop_expanded = img[max(0, y1-pad):min(img.shape[0], y2+pad), max(0, x1-pad):min(img.shape[1], x2+pad)]
res3 = model.predict(source=crop_expanded, conf=0.01, verbose=False)[0]
print(f"Detections: {len(res3.boxes)}")
if len(res3.boxes) > 0:
    print(res3.boxes.conf)
    print(res3.boxes.cls)
