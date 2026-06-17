"""
crop_boxes.py
─────────────
Crop each bounding box from the database (or manual_boxes.json fallback)
and save as individual labeled images for verification.

Data source priority:
  1. Database (BoundingBox table for the given project_id)
  2. Fallback: storage/manual_boxes.json

Usage:
    cd backend
    python crop_boxes.py                    # project_id=1, uses DB
    python crop_boxes.py --project 3        # project_id=3
    python crop_boxes.py --manual           # force manual_boxes.json
"""

import argparse
import json
import os
import sys
import cv2

# Add app to path so we can import database models
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "app")))

MANUAL_BOXES_PATH = os.path.join("storage", "manual_boxes.json")
OUTPUT_DIR = os.path.join("storage", "cropped_components")


def get_boxes_from_db(project_id: int):
    """Fetch bounding boxes and prototype path from the database."""
    try:
        from app.database import SessionLocal
        from app.models import Project, BoundingBox

        db = SessionLocal()
        project = db.query(Project).filter(Project.id == project_id).first()
        if not project:
            print(f"[WARN] Project {project_id} not found in DB")
            db.close()
            return None, None

        proto_path = project.prototype_path
        db_boxes = (
            db.query(BoundingBox)
            .filter(BoundingBox.project_id == project_id)
            .all()
        )
        boxes = [
            {
                "label": b.label,
                "x1": float(b.x1),
                "y1": float(b.y1),
                "x2": float(b.x2),
                "y2": float(b.y2),
            }
            for b in db_boxes
        ]
        db.close()
        return proto_path, boxes
    except Exception as e:
        print(f"[WARN] Could not read from DB: {e}")
        return None, None


def get_boxes_from_json():
    """Fallback: read from manual_boxes.json."""
    if not os.path.isfile(MANUAL_BOXES_PATH):
        return None
    with open(MANUAL_BOXES_PATH, "r") as f:
        return json.load(f).get("boxes", [])


def main():
    parser = argparse.ArgumentParser(description="Crop bounding boxes from prototype image")
    parser.add_argument("--project", type=int, default=1, help="Project ID to fetch boxes from DB")
    parser.add_argument("--manual", action="store_true", help="Force read from manual_boxes.json instead of DB")
    parser.add_argument("--image", type=str, default=None, help="Override prototype image path")
    args = parser.parse_args()

    boxes = None
    proto_path = None
    source = ""

    # ── Determine data source ─────────────────────────────────
    if args.manual:
        boxes = get_boxes_from_json()
        proto_path = os.path.join("storage", f"project_{args.project}_proto.jpg")
        source = f"manual_boxes.json"
    else:
        proto_path, boxes = get_boxes_from_db(args.project)
        source = f"database (project_id={args.project})"

    if not boxes:
        print(f"[WARN] No boxes found from {source}. Trying manual_boxes.json fallback...")
        boxes = get_boxes_from_json()
        source = "manual_boxes.json (fallback)"

    if not boxes:
        print("[ERROR] No boxes found from any source.")
        sys.exit(1)

    # ── Resolve image path ────────────────────────────────────
    if args.image:
        image_path = args.image
    elif proto_path:
        # proto_path from DB might be relative like "storage/project_1_proto.jpg"
        image_path = proto_path if os.path.isfile(proto_path) else os.path.join("storage", os.path.basename(proto_path))
    else:
        image_path = os.path.join("storage", f"project_{args.project}_proto.jpg")

    if not os.path.isfile(image_path):
        print(f"[ERROR] Image not found: {image_path}")
        sys.exit(1)

    image = cv2.imread(image_path)
    if image is None:
        print(f"[ERROR] Failed to read image: {image_path}")
        sys.exit(1)

    img_h, img_w = image.shape[:2]
    print(f"[INFO] Source: {source}")
    print(f"[INFO] Image:  {image_path} ({img_w} x {img_h} px)")
    print(f"[INFO] Boxes:  {len(boxes)}")

    # ── Check if coordinates need clamping (display-space coords) ──
    max_x = max(float(b["x2"]) for b in boxes)
    max_y = max(float(b["y2"]) for b in boxes)
    scale_x, scale_y = 1.0, 1.0

    if max_x > img_w * 1.05 or max_y > img_h * 1.05:
        # Coords are in display-pixel space, need to scale to image space
        scale_x = img_w / max_x if max_x > img_w else 1.0
        scale_y = img_h / max_y if max_y > img_h else 1.0
        # Use uniform scaling to preserve aspect ratio
        scale = min(scale_x, scale_y)
        scale_x = scale_y = scale
        print(f"[INFO] Coords exceed image bounds (max_x={max_x:.1f}, max_y={max_y:.1f})")
        print(f"[INFO] Auto-scaling by {scale:.4f} to fit {img_w}x{img_h}")

    # ── Clean output folder ───────────────────────────────────
    # Remove old crops to avoid stale files
    if os.path.isdir(OUTPUT_DIR):
        for f in os.listdir(OUTPUT_DIR):
            if f.endswith(".jpg"):
                os.remove(os.path.join(OUTPUT_DIR, f))
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    label_counter: dict[str, int] = {}

    print(f"\n{'Idx':>4} {'Label':30s}  {'Size':>10}  {'File'}")
    print("-" * 80)

    for i, box in enumerate(boxes):
        label = box["label"]
        x1 = int(float(box["x1"]) * scale_x)
        y1 = int(float(box["y1"]) * scale_y)
        x2 = int(float(box["x2"]) * scale_x)
        y2 = int(float(box["y2"]) * scale_y)

        # Clamp to image bounds
        x1 = max(0, min(x1, img_w))
        y1 = max(0, min(y1, img_h))
        x2 = max(0, min(x2, img_w))
        y2 = max(0, min(y2, img_h))

        if x2 <= x1 or y2 <= y1:
            print(f"[{i:2d}] SKIP {label} - invalid box ({x1},{y1})->({x2},{y2})")
            continue

        crop = image[y1:y2, x1:x2]

        count = label_counter.get(label, 0)
        label_counter[label] = count + 1
        safe_label = label.replace(" ", "_").replace("/", "_")
        filename = f"{i:02d}_{safe_label}_{count}.jpg"
        out_path = os.path.join(OUTPUT_DIR, filename)

        cv2.imwrite(out_path, crop)
        w, h = x2 - x1, y2 - y1
        print(f"[{i:2d}] {label:30s}  {w:4d}x{h:<4d}px  {filename}")

    print(f"\n[DONE] {sum(label_counter.values())} crops saved to {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
