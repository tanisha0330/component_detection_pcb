"""
visualize_boxes.py
──────────────────
Draw all bounding boxes onto the prototype image and save the annotated
result for visual verification.

Data source priority:
  1. Database (BoundingBox table for the given project_id)
  2. Fallback: storage/manual_boxes.json

Usage:
    cd backend
    python visualize_boxes.py                    # project_id=1, uses DB
    python visualize_boxes.py --project 3        # project_id=3
    python visualize_boxes.py --manual           # force manual_boxes.json
"""

import argparse
import json
import os
import sys
import cv2
import numpy as np

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "app")))

MANUAL_BOXES_PATH = os.path.join("storage", "manual_boxes.json")
OUTPUT_PATH = os.path.join("storage", "samples", "debug_bbox_overlay.jpg")

LABEL_COLORS = {
    "capacitor":                  (0,   165, 255),
    "resistor":                   (0,   255,   0),
    "LED":                        (0,   255, 255),
    "IC":                         (255,   0,   0),
    "transistor":                 (255,   0, 255),
    "switch":                     (0,   128, 255),
    "headers":                    (255, 255,   0),
    "microcontroller":            (128,   0, 128),
    "icsp":                       (0,   200, 200),
    "ATmega328 microcontroller":  (255, 128,   0),
    "crystal oscillator":         (180, 105, 255),
    "voltage regulator":          (0,   128,   0),
    "r105":                       (128, 128,   0),
    "comp1":                      (200,  50, 150),
    "comp2":                      (100, 200,  50),
    "comp3":                      (50,  100, 200),
    "usb":                        (230, 216, 173),
    "dc":                         (60,  20,  220),
}

def get_color(label: str) -> tuple:
    return LABEL_COLORS.get(label, (255, 255, 255))


def get_boxes_from_db(project_id: int):
    try:
        from app.database import SessionLocal
        from app.models import Project, BoundingBox
        db = SessionLocal()
        project = db.query(Project).filter(Project.id == project_id).first()
        if not project:
            db.close()
            return None, None
        proto_path = project.prototype_path
        db_boxes = db.query(BoundingBox).filter(BoundingBox.project_id == project_id).all()
        boxes = [
            {"label": b.label, "x1": float(b.x1), "y1": float(b.y1),
             "x2": float(b.x2), "y2": float(b.y2)}
            for b in db_boxes
        ]
        db.close()
        return proto_path, boxes
    except Exception as e:
        print(f"[WARN] DB read failed: {e}")
        return None, None


def get_boxes_from_json():
    if not os.path.isfile(MANUAL_BOXES_PATH):
        return None
    with open(MANUAL_BOXES_PATH, "r") as f:
        return json.load(f).get("boxes", [])


def main():
    parser = argparse.ArgumentParser(description="Visualize bounding boxes on prototype image")
    parser.add_argument("--project", type=int, default=1, help="Project ID")
    parser.add_argument("--manual", action="store_true", help="Force manual_boxes.json")
    parser.add_argument("--image", type=str, default=None, help="Override image path")
    args = parser.parse_args()

    boxes = None
    proto_path = None
    source = ""

    if args.manual:
        boxes = get_boxes_from_json()
        proto_path = os.path.join("storage", f"project_{args.project}_proto.jpg")
        source = "manual_boxes.json"
    else:
        proto_path, boxes = get_boxes_from_db(args.project)
        source = f"database (project_id={args.project})"

    if not boxes:
        print(f"[WARN] No boxes from {source}, trying manual_boxes.json...")
        boxes = get_boxes_from_json()
        source = "manual_boxes.json (fallback)"

    if not boxes:
        print("[ERROR] No boxes found.")
        sys.exit(1)

    if args.image:
        image_path = args.image
    elif proto_path:
        image_path = proto_path if os.path.isfile(proto_path) else os.path.join("storage", os.path.basename(proto_path))
    else:
        image_path = os.path.join("storage", f"project_{args.project}_proto.jpg")

    if not os.path.isfile(image_path):
        print(f"[ERROR] Image not found: {image_path}")
        sys.exit(1)

    image = cv2.imread(image_path)
    if image is None:
        print(f"[ERROR] Failed to read: {image_path}")
        sys.exit(1)

    img_h, img_w = image.shape[:2]
    print(f"[INFO] Source: {source}")
    print(f"[INFO] Image:  {image_path} ({img_w} x {img_h} px)")
    print(f"[INFO] Boxes:  {len(boxes)}")

    # Auto-scale if coords exceed image dimensions
    max_x = max(float(b["x2"]) for b in boxes)
    max_y = max(float(b["y2"]) for b in boxes)
    scale_x, scale_y = 1.0, 1.0

    if max_x > img_w * 1.05 or max_y > img_h * 1.05:
        scale = min(img_w / max_x, img_h / max_y)
        scale_x = scale_y = scale
        print(f"[INFO] Auto-scaling coords by {scale:.4f} (max_x={max_x:.0f}, max_y={max_y:.0f})")

    label_counts: dict[str, int] = {}

    print(f"\n{'Idx':>4} {'Label':30s}  {'x1':>6} {'y1':>6} {'x2':>6} {'y2':>6}  {'WxH'}")
    print("-" * 90)

    for i, box in enumerate(boxes):
        label = box["label"]
        x1 = max(0, min(int(float(box["x1"]) * scale_x), img_w))
        y1 = max(0, min(int(float(box["y1"]) * scale_y), img_h))
        x2 = max(0, min(int(float(box["x2"]) * scale_x), img_w))
        y2 = max(0, min(int(float(box["y2"]) * scale_y), img_h))

        if x2 <= x1 or y2 <= y1:
            print(f"[{i:2d}] SKIP {label}")
            continue

        label_counts[label] = label_counts.get(label, 0) + 1
        w, h = x2 - x1, y2 - y1
        print(f"[{i:2d}] {label:30s}  {x1:6d} {y1:6d} {x2:6d} {y2:6d}  {w}x{h}px")

        color = get_color(label)
        thickness = max(2, int(min(img_w, img_h) / 500))
        cv2.rectangle(image, (x1, y1), (x2, y2), color, thickness)

        text = f"[{i}] {label}"
        font_scale = max(0.4, min(img_w, img_h) / 2500)
        font_thickness = max(1, int(font_scale * 2))
        (tw, th_text), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, font_scale, font_thickness)
        label_y = y1 - 6 if y1 - th_text - 6 > 0 else y1 + th_text + 6
        cv2.rectangle(image, (x1, label_y - th_text - 4), (x1 + tw + 4, label_y + 4), color, -1)
        cv2.putText(image, text, (x1 + 2, label_y), cv2.FONT_HERSHEY_SIMPLEX, font_scale, (0, 0, 0), font_thickness, cv2.LINE_AA)

    print(f"\n[SUMMARY]")
    for label, count in sorted(label_counts.items()):
        print(f"     {label:30s} : {count}")
    print(f"     {'TOTAL':30s} : {sum(label_counts.values())}")

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    cv2.imwrite(OUTPUT_PATH, image)
    print(f"\n[DONE] Saved -> {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
