import os
import uuid
import json
import cv2
import asyncio
import numpy as np
import torch
import torchvision.transforms as T
from PIL import Image, ImageOps
from skimage.metrics import structural_similarity as ssim_func
from fastapi import APIRouter, Depends, UploadFile, File, HTTPException
from sqlalchemy.orm import Session
from ultralytics import YOLO, FastSAM
from pydantic import BaseModel
from typing import List

from . import models, database

router = APIRouter()
inference_lock = asyncio.Lock()

# Relative to CWD: resolves to /app/storage in Docker (WORKDIR /app) and to
# backend/storage when run locally via `uvicorn app.main:app` from backend/.
STORAGE_DIR = "storage"
SAMPLES_DIR = os.path.join(STORAGE_DIR, "samples")
os.makedirs(SAMPLES_DIR, exist_ok=True)
# -------------------------

# ─────────────────────────────────────────────────────────────
# Pipeline tunables (ported from external_new_pipeline/final_testing_2.ipynb)
# ─────────────────────────────────────────────────────────────
PIPELINE_CONFIG = {
    # ---- FastSAM component detection ----
    "max_side": 1280,        # downscale longest side before FastSAM
    "sam_conf": 0.4,          # LOWER = more parts detected + more noise
    "sam_iou": 0.9,           # LOWER = fewer overlapping masks

    # ---- component filtering (FastSAM outputs) ----
    "min_area": 400,          # ignore detections smaller than this (px^2)
    "max_area_frac": 0.15,    # ignore region-blobs bigger than this fraction
    "max_aspect": 8.0,        # ignore long thin shapes (traces)

    # ---- anchor selection / alignment ----
    "anchor_yolo_conf": 0.7,  # min YOLO confidence to consider as anchor candidate
    "anchor_target_n": 5,     # aim for this many anchors
    "anchor_min_n": 3,        # absolute minimum for homography (fall back to ORB below this)

    # ---- prototype matching (transformed prototype -> FastSAM detection) ----
    "match_overlap": 0.3,     # min overlap fraction for FastSAM box == prototype box

    # ---- valid-content cropping (hide black/out-of-frame regions) ----
    "min_box_valid_frac": 0.5,  # a detection box must have at least this
                                 # fraction of its area on real (non-black)
                                 # content to be kept; drops boxes that fall
                                 # on the missing/out-of-frame part of the board

    # ---- ORB fallback (used only if anchor selection fails) ----
    "orb_features": 10000,  # more candidate keypoints -> more good matches
                             # -> more RANSAC inliers, meaningfully improves
                             # fit precision (verified: 22->52 inliers on a
                             # real test case). Note: a single global
                             # homography still can't correct for camera lens
                             # distortion, which is worst at the image edges —
                             # peripheral components can still have residual
                             # crop-position error no amount of feature/RANSAC
                             # tuning fixes; retaking the photo with the board
                             # centered helps more than any parameter here.
    "match_ratio": 0.75,

    # ---- absolute floor for the whole pipeline ----
    "min_usable_alignment_quality": 0.15,  # NCC score below this means the
                                    # warp doesn't correspond to the golden
                                    # image at all (content mismatch, not just
                                    # imprecision) — geometric sanity alone
                                    # can't catch this, so the request is
                                    # rejected rather than confidently
                                    # mislabeling components on a garbage warp

    # ---- DINOv2 missing-component detection ----
    "dino_sim_thresh": 0.65,  # cosine similarity between golden and test
                               # crop below which a component is flagged
                               # "missing" (empty/unpopulated pad).
                               # LOWER = more lenient, HIGHER = stricter.
                               # Used for any class not in
                               # dino_sim_thresh_by_class below.
    "dino_sim_thresh_by_class": {
        # Small passives show much less present/missing score separation
        # than large-marking classes like IC (present ~0.65-0.73 vs a
        # genuine miss ~0.40, with normal shot-to-shot lighting/pose noise
        # alone crossing the default 0.65 threshold). Lower cutoff for
        # these keeps real misses (score well under 0.5) flagged while
        # clearing that noise band.
        "resistor": 0.55,
        "capacitor": 0.55,
    },
    "dino_pad_px": 12,        # context margin around each crop for DINOv2

    # ---- EasyOCR component marking/rating identification ----
    "ocr_conf_thresh": 0.35,   # min EasyOCR confidence to keep a text token
    "ocr_pad_normal": 8,       # crop padding for small components
    "ocr_pad_large": 20,       # crop padding for large components (more context)
    "ocr_upscale": 4,          # upscale factor before OCR (small SMD markings)
    "ocr_max_dim": 700,        # cap the upscaled crop's longer side to this
                               # many px, regardless of "ocr_upscale" — large
                               # components (ic/connector/...) would otherwise
                               # blow up into huge images that make CPU text
                               # detection take 10s+ each. LOWER = faster but
                               # may hurt readability on large markings.
    "ocr_large_classes": {"ic", "connector", "crystal", "transistor"},
}


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
    if project.prototype_path:
        proto_filename = os.path.basename(project.prototype_path)
        actual_proto_path = os.path.join(STORAGE_DIR, proto_filename)

        if os.path.exists(actual_proto_path):
            try:
                source_image = Image.open(actual_proto_path).convert("RGB")
                source_image = ImageOps.exif_transpose(source_image)
                debug_proto = np.array(source_image)

                for b in payload.boxes:
                    x1, y1, x2, y2 = map(int, [b.x1, b.y1, b.x2, b.y2])
                    cv2.rectangle(debug_proto, (x1, y1), (x2, y2), (0, 0, 255), 3)
                    cv2.putText(debug_proto, b.label, (x1, y1 - 10),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)

                cv2.imwrite(os.path.join(SAMPLES_DIR, "debug_save_boxes.jpg"),
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
    print(f"  GPU : {torch.cuda.get_device_name(0)}")
    print(f"  VRAM: {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB")


# ─────────────────────────────────────────────────────────────
# Load models ONCE at startup
# ─────────────────────────────────────────────────────────────
print("Loading anchor/component YOLO model (anchor_model)...")
anchor_model = YOLO("pcb_anchor_yolo.pt")
if DEVICE == "cuda":
    anchor_model = anchor_model.cuda()
print(f"  anchor_model ready — classes: {anchor_model.names}")

print("Loading FastSAM model (fastsam_model)...")
fastsam_model = FastSAM("FastSAM-x.pt")
if DEVICE == "cuda":
    fastsam_model = fastsam_model.cuda()
print("  fastsam_model ready")

# DINOv2 compares golden vs. test crops by SEMANTIC appearance to flag
# components that are missing/unpopulated (an empty pad looks very
# different from a populated one, even under lighting/angle changes that
# would otherwise confuse pixel-level comparison). Downloaded via
# torch.hub on first run — if that fails (e.g. no internet in this
# environment), missing-component detection degrades gracefully to
# "present" for everything rather than crashing the pipeline.
print("Loading DINOv2 (missing-component detection)...")
try:
    dino_model = torch.hub.load("facebookresearch/dinov2", "dinov2_vits14", trust_repo=True)
    dino_model = dino_model.to(DEVICE).eval()
    dino_transform = T.Compose([
        T.ToPILImage(), T.Resize(224), T.CenterCrop(224),
        T.ToTensor(),
        T.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
    ])
    DINO_AVAILABLE = True
    print("  dino_model ready")
except Exception as e:
    dino_model = None
    dino_transform = None
    DINO_AVAILABLE = False
    print(f"  DINOv2 unavailable ({e}); missing-component detection disabled")

# EasyOCR reads text markings off each component (resistor values, IC part
# numbers, etc.) for identification/rating purposes. Always run on CPU —
# keeps it from fighting the anchor/FastSAM/DINOv2 models for GPU memory
# and avoids CUDA stream conflicts (ported from the notebook's approach).
print("Loading EasyOCR (component marking/rating reader)...")
try:
    import easyocr
    ocr_reader = easyocr.Reader(["en"], gpu=False, verbose=False)
    OCR_AVAILABLE = True
    print("  ocr_reader ready (CPU)")
except Exception as e:
    ocr_reader = None
    OCR_AVAILABLE = False
    print(f"  EasyOCR unavailable ({e}); marking/rating extraction disabled")


# ─────────────────────────────────────────────────────────────
# Helpers (ported from external_new_pipeline/final_testing_2.ipynb)
# ─────────────────────────────────────────────────────────────

def enhance(img, clip_limit=2.5, tile_grid=(8, 8)):
    """CLAHE contrast enhancement — helps FastSAM detect low-contrast parts."""
    lab = cv2.cvtColor(img, cv2.COLOR_RGB2LAB)
    l, a, b = cv2.split(lab)
    clahe = cv2.createCLAHE(clipLimit=clip_limit, tileGridSize=tile_grid)
    l_enh = clahe.apply(l)
    return cv2.cvtColor(cv2.merge((l_enh, a, b)), cv2.COLOR_LAB2RGB)


def box_overlap_fraction(a, b):
    """Fraction of box a covered by box b."""
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    if ix2 <= ix1 or iy2 <= iy1:
        return 0.0
    inter = (ix2 - ix1) * (iy2 - iy1)
    return inter / max(1, (ax2 - ax1) * (ay2 - ay1))


def crop_to_valid_content(warped, warped_enh, valid_mask):
    """Crop the warp output down to the bounding box of real (non-black)
    pixels, so the returned image is tightly framed on actual content
    instead of floating in a black canvas. Returns the cropped arrays
    plus the (x_off, y_off) offset to apply to any box already expressed
    in the pre-crop coordinate frame."""
    ys, xs = np.where(valid_mask > 0)
    if len(xs) == 0 or len(ys) == 0:
        return warped, warped_enh, valid_mask, 0, 0
    x1, x2 = int(xs.min()), int(xs.max()) + 1
    y1, y2 = int(ys.min()), int(ys.max()) + 1
    return (
        warped[y1:y2, x1:x2],
        warped_enh[y1:y2, x1:x2],
        valid_mask[y1:y2, x1:x2],
        x1, y1,
    )


def box_valid_fraction(bbox, valid_mask):
    """Fraction of a box's area that falls on real (non-black) content."""
    Hh, Ww = valid_mask.shape[:2]
    x1, y1, x2, y2 = [int(v) for v in bbox]
    x1 = max(0, min(x1, Ww)); x2 = max(0, min(x2, Ww))
    y1 = max(0, min(y1, Hh)); y2 = max(0, min(y2, Hh))
    if x2 <= x1 or y2 <= y1:
        return 0.0
    region = valid_mask[y1:y2, x1:x2]
    if region.size == 0:
        return 0.0
    return float((region > 0).mean())


def bbox_center(bbox):
    x1, y1, x2, y2 = bbox
    return ((x1 + x2) / 2, (y1 + y2) / 2)


def run_yolo_anchor(img, conf_threshold):
    """Run the anchor/component YOLO model. Returns a list of
    {"bbox", "label", "conf"} dicts."""
    with torch.no_grad():
        results = anchor_model.predict(
            img, device=DEVICE, imgsz=640, conf=conf_threshold,
            half=(DEVICE == "cuda"), verbose=False,
        )
    if DEVICE == "cuda":
        torch.cuda.empty_cache()
    if not results or results[0].boxes is None:
        return []
    dets = []
    for b in results[0].boxes:
        xyxy = b.xyxy[0].cpu().numpy().astype(int)
        cls_id = int(b.cls[0].item())
        conf = float(b.conf[0].item())
        label = anchor_model.names.get(cls_id, str(cls_id))
        dets.append({"bbox": tuple(int(v) for v in xyxy), "label": label, "conf": conf})
    return dets


def select_anchor_candidates(dets, conf_threshold, target_n):
    """Sort by confidence, prefer class diversity, return top-N anchors."""
    high_conf = [d for d in dets if d["conf"] >= conf_threshold]
    high_conf.sort(key=lambda d: -d["conf"])

    selected = []
    seen_classes = {}
    for d in high_conf:
        if seen_classes.get(d["label"], 0) < 1:
            selected.append(d)
            seen_classes[d["label"]] = seen_classes.get(d["label"], 0) + 1
            if len(selected) >= target_n:
                break
    for d in high_conf:
        if d in selected:
            continue
        if len(selected) >= target_n:
            break
        selected.append(d)
        seen_classes[d["label"]] = seen_classes.get(d["label"], 0) + 1

    return selected


def match_anchors_ransac(golden_anchors, test_anchors, min_matches):
    """Match golden anchors to test anchors using class + RANSAC.
    Returns (inlier_count, H) or (None, None) if matching fails."""
    if len(golden_anchors) < min_matches or len(test_anchors) < min_matches:
        return None, None

    candidate_pairs = []
    for ga in golden_anchors:
        for ta in test_anchors:
            if ga["label"] == ta["label"]:
                candidate_pairs.append((ga, ta))

    if len(candidate_pairs) < min_matches:
        print(f"  Only {len(candidate_pairs)} same-class candidate pairings - "
              f"need {min_matches}")
        return None, None

    golden_pts = np.array(
        [bbox_center(ga["bbox"]) for ga, _ in candidate_pairs], dtype=np.float32
    )
    test_pts = np.array(
        [bbox_center(ta["bbox"]) for _, ta in candidate_pairs], dtype=np.float32
    )

    H, mask = cv2.findHomography(
        test_pts.reshape(-1, 1, 2), golden_pts.reshape(-1, 1, 2),
        cv2.RANSAC, ransacReprojThreshold=15.0,
    )
    if H is None:
        return None, None
    inliers = int(mask.sum())
    if inliers < min_matches:
        print(f"  RANSAC found only {inliers} consistent pairs - need {min_matches}")
        return None, None

    return inliers, H


def align_with_orb(test_img, golden_img, config):
    """ORB fallback alignment. Returns homography H mapping test -> golden."""
    print("Falling back to ORB alignment...")
    g_gray = cv2.cvtColor(golden_img, cv2.COLOR_RGB2GRAY)
    t_gray = cv2.cvtColor(test_img, cv2.COLOR_RGB2GRAY)
    orb = cv2.ORB_create(nfeatures=config["orb_features"])
    kp_g, des_g = orb.detectAndCompute(g_gray, None)
    kp_t, des_t = orb.detectAndCompute(t_gray, None)
    if des_g is None or des_t is None:
        raise RuntimeError("ORB fallback also failed - no features found")
    bf = cv2.BFMatcher(cv2.NORM_HAMMING)
    matches = bf.knnMatch(des_t, des_g, k=2)
    good = [m for m, n in matches if len(matches) and m.distance < config["match_ratio"] * n.distance]
    if len(good) < 10:
        raise RuntimeError(f"Only {len(good)} ORB matches - alignment unreliable")
    src = np.float32([kp_t[m.queryIdx].pt for m in good]).reshape(-1, 1, 2)
    dst = np.float32([kp_g[m.trainIdx].pt for m in good]).reshape(-1, 1, 2)
    H, mask = cv2.findHomography(src, dst, cv2.RANSAC, 5.0)
    return H, len(good), int(mask.sum())


def is_homography_sane(H, img_w, img_h):
    """Reject a homography that would warp the test image into a wildly
    degenerate shape — extreme scale/shear, a self-intersecting quad, or a
    non-finite result. RANSAC can return a "successful" fit (enough inlier
    points) that is still geometrically nonsensical, especially on repetitive
    PCB textures (many near-identical components confuse point matching);
    this catches that before it silently wraps the image into a totally
    different perspective."""
    if H is None:
        return False
    corners = np.array(
        [[0, 0], [img_w, 0], [img_w, img_h], [0, img_h]], dtype=np.float32
    ).reshape(-1, 1, 2)
    try:
        warped = cv2.perspectiveTransform(corners, H).reshape(-1, 2)
    except cv2.error:
        return False
    if not np.all(np.isfinite(warped)):
        return False

    area = cv2.contourArea(warped.astype(np.float32))
    orig_area = img_w * img_h
    if orig_area <= 0 or area <= 0:
        return False
    area_ratio = area / orig_area
    if area_ratio < 0.03 or area_ratio > 30:
        return False  # wildly shrunk or blown-up warp

    hull = cv2.convexHull(warped.astype(np.float32))
    if len(hull) < 4:
        return False  # self-intersecting / degenerate quadrilateral

    return True


def alignment_quality_score(golden_img, warped_img, golden_boxes, warped_boxes):
    """Mean normalized cross-correlation between golden crops and their
    corresponding warped-test crops. ~1.0 = well aligned, <0.5 = the warp
    likely isn't lining the two images up correctly (bad homography)."""
    scores = []
    for gbox, wbox in zip(golden_boxes, warped_boxes):
        gx1, gy1, gx2, gy2 = [int(v) for v in gbox]
        wx1, wy1, wx2, wy2 = [int(v) for v in wbox]
        g = golden_img[gy1:gy2, gx1:gx2]
        w = warped_img[wy1:wy2, wx1:wx2]
        if g.size == 0 or w.size == 0:
            continue
        h = min(g.shape[0], w.shape[0])
        wd = min(g.shape[1], w.shape[1])
        if h < 4 or wd < 4:
            continue
        gg = cv2.cvtColor(g[:h, :wd], cv2.COLOR_RGB2GRAY).astype(np.float32)
        ww = cv2.cvtColor(w[:h, :wd], cv2.COLOR_RGB2GRAY).astype(np.float32)
        gn = (gg - gg.mean()) / (gg.std() + 1e-6)
        wn = (ww - ww.mean()) / (ww.std() + 1e-6)
        scores.append(float((gn * wn).mean()))
    return float(np.mean(scores)) if scores else 0.0


def quick_alignment_quality(H, test_img, golden_img, prototypes, Gw, Gh):
    """Cheap pre-crop alignment score for a candidate homography: warp the
    full test image and NCC-compare golden vs. warped-test at the largest
    prototype boxes (still in golden's own, uncropped frame at this point,
    so the same box list applies to both)."""
    warped = cv2.warpPerspective(test_img, H, (Gw, Gh))
    sample = sorted(
        prototypes,
        key=lambda p: -(p["bbox_golden"][2] - p["bbox_golden"][0])
        * (p["bbox_golden"][3] - p["bbox_golden"][1]),
    )[:10]
    boxes = [p["bbox_golden"] for p in sample]
    return alignment_quality_score(golden_img, warped, boxes, boxes)


def get_padded_crop(img, bbox, pad):
    """Crop a region out of img with `pad` extra pixels of context,
    clipped to image bounds."""
    Hh, Ww = img.shape[:2]
    x1, y1, x2, y2 = [int(v) for v in bbox]
    x1 = max(0, x1 - pad); y1 = max(0, y1 - pad)
    x2 = min(Ww, x2 + pad); y2 = min(Hh, y2 + pad)
    if x2 <= x1 or y2 <= y1:
        return None
    return img[y1:y2, x1:x2]


def embed_crop(crop):
    """Embed a single crop with DINOv2. Returns a 384-dim unit vector,
    or None if DINOv2 isn't available / the crop is empty."""
    if not DINO_AVAILABLE or crop is None or crop.size == 0:
        return None
    if crop.shape[0] < 14 or crop.shape[1] < 14:
        crop = cv2.resize(crop, (32, 32))
    c = np.clip(crop, 0, 255).astype(np.uint8)
    t = dino_transform(c).unsqueeze(0).to(DEVICE)
    with torch.no_grad():
        e = dino_model(t)
        e = torch.nn.functional.normalize(e, dim=1)
    return e.cpu().numpy()[0]


def cosine_sim(a, b):
    if a is None or b is None:
        return None
    return float(np.dot(a, b))


def compute_ssim(crop_a, crop_b):
    """Structural similarity (pixel-level) between a golden and test crop,
    as a second, independent signal alongside the DINOv2 semantic score —
    the two can diverge (e.g. DINO score swings between shots of the same
    defect due to lighting/alignment noise), so surfacing both lets a human
    judge a "missing" call instead of trusting one score blindly."""
    if crop_a is None or crop_a.size == 0 or crop_b is None or crop_b.size == 0:
        return None
    ga = cv2.cvtColor(crop_a, cv2.COLOR_RGB2GRAY) if crop_a.ndim == 3 else crop_a
    gb = cv2.cvtColor(crop_b, cv2.COLOR_RGB2GRAY) if crop_b.ndim == 3 else crop_b
    h, w = ga.shape[:2]
    if h < 7 or w < 7:
        return None
    gb = cv2.resize(gb, (w, h))
    win_size = min(7, h, w)
    if win_size % 2 == 0:
        win_size -= 1
    try:
        return float(ssim_func(ga, gb, win_size=win_size))
    except Exception:
        return None


def preprocess_for_ocr(crop, upscale, max_dim):
    """Upscale + sharpen a crop so EasyOCR can read small SMD markings.
    The upscale factor is capped so large-class crops (ic/connector/...)
    don't blow up into huge images that make CPU CRAFT text detection
    crawl — a 4x blind upscale on a big connector crop can take 10s+ per
    component and was the actual cause of inference timeouts, not DINOv2."""
    if crop is None or crop.size == 0:
        return None
    h, w = crop.shape[:2]
    if h < 8 or w < 8:
        return None
    effective_scale = min(upscale, max(1.0, max_dim / max(h, w)))
    big = cv2.resize(crop, (int(w * effective_scale), int(h * effective_scale)),
                      interpolation=cv2.INTER_CUBIC)
    gray = cv2.cvtColor(big, cv2.COLOR_RGB2GRAY)
    blur = cv2.GaussianBlur(gray, (0, 0), sigmaX=1)
    return cv2.addWeighted(gray, 1.5, blur, -0.5, 0)


def run_ocr(crop, config):
    """Read text markings off a component crop. Returns "" if OCR is
    unavailable, the crop is unreadable, or no confident text is found."""
    if not OCR_AVAILABLE:
        return ""
    proc = preprocess_for_ocr(crop, config["ocr_upscale"], config["ocr_max_dim"])
    if proc is None:
        return ""
    res = ocr_reader.readtext(proc, detail=1, paragraph=False)
    texts = [t.strip() for _, t, c in res
             if c >= config["ocr_conf_thresh"] and t.strip()]
    return " ".join(texts).upper().strip()


def best_reading(golden_text, test_text):
    """Pick the more complete text reading between golden and test crops."""
    if not golden_text and not test_text:
        return ""
    if not golden_text:
        return test_text
    if not test_text:
        return golden_text
    return golden_text if len(golden_text) >= len(test_text) else test_text


def detect_fastsam(img_enh, config):
    """Run FastSAM on a downscaled image, return list of (x1,y1,x2,y2) boxes
    in the ORIGINAL (img_enh) coordinate space."""
    H, W = img_enh.shape[:2]
    scale = min(1.0, config["max_side"] / max(H, W))
    small = cv2.resize(img_enh, (int(W * scale), int(H * scale)),
                        interpolation=cv2.INTER_AREA) if scale < 1.0 else img_enh
    with torch.no_grad():
        results = fastsam_model.predict(
            small, device=DEVICE, retina_masks=True, imgsz=1024,
            conf=config["sam_conf"], iou=config["sam_iou"],
            half=(DEVICE == "cuda"), verbose=False,
        )
    if DEVICE == "cuda":
        torch.cuda.empty_cache()
    r = results[0]
    if r.masks is None:
        return []
    boxes = r.boxes.xyxy.cpu().numpy().astype(int) if r.boxes is not None else None
    n_raw = len(boxes) if boxes is not None else 0
    dets = []
    for i in range(n_raw):
        x1s, y1s, x2s, y2s = boxes[i]
        x1 = max(0, int(x1s / scale)); y1 = max(0, int(y1s / scale))
        x2 = min(W, int(x2s / scale)); y2 = min(H, int(y2s / scale))
        if x2 - x1 < 4 or y2 - y1 < 4:
            continue
        area = (x2 - x1) * (y2 - y1)
        w, h = x2 - x1, y2 - y1
        ar = max(w, h) / max(1, min(w, h))
        if area < config["min_area"] or area > config["max_area_frac"] * H * W or ar > config["max_aspect"]:
            continue
        dets.append((x1, y1, x2, y2))
    return dets


# ─────────────────────────────────────────────────────────────
# Inference endpoint
# ─────────────────────────────────────────────────────────────

@router.post("/projects/{project_id}/inference")
async def run_inference(
    project_id: int,
    file: UploadFile = File(...),
    db: Session = Depends(database.get_db),
):
    async with inference_lock:
        # ── Validate project ──────────────────────────────────────
        print("Step: Validating project...")
        project = db.query(models.Project).filter(models.Project.id == project_id).first()
        if not project or not project.prototype_path:
            raise HTTPException(status_code=400, detail="Prototype missing.")

        proto_filename = os.path.basename(project.prototype_path)
        actual_proto_path = os.path.join(STORAGE_DIR, proto_filename)

        if not os.path.exists(actual_proto_path):
            raise HTTPException(status_code=400, detail=f"Prototype file physically missing at {actual_proto_path}")

        # ── Resolve bounding boxes directly from Database ─────────
        print("\n── Bounding Box Source ──────────────────────────────────────")
        boxes_db = db.query(models.BoundingBox).filter(
            models.BoundingBox.project_id == project_id
        ).all()
        if not boxes_db:
            raise HTTPException(status_code=400, detail="No prompt boxes found.")

        prototypes = [
            {"label": b.label, "bbox": (b.x1, b.y1, b.x2, b.y2)}
            for b in boxes_db
        ]
        print(f"  Source: database ({len(prototypes)} prototype boxes)")

        # ── Save uploaded target image ────────────────────────────
        run_id = uuid.uuid4().hex[:8]
        unique_filename = f"{run_id}_{file.filename}"
        target_path = os.path.join(SAMPLES_DIR, f"raw_{project_id}_{unique_filename}")
        print(f"Step: Saving uploaded target image to {target_path}...")
        with open(target_path, "wb") as buffer:
            buffer.write(await file.read())

        try:
            # ── Load golden (prototype) image ───────────────────────
            print(f"Step: Loading golden image from {actual_proto_path}...")
            golden_pil = Image.open(actual_proto_path).convert("RGB")
            golden_pil = ImageOps.exif_transpose(golden_pil)
            golden_img = np.array(golden_pil)
            Gh, Gw = golden_img.shape[:2]
            print(f"  Golden size: {Gw}x{Gh}")

            # clip prototype boxes to golden image bounds. bbox_golden stays
            # fixed to the golden image's own frame (used for alignment-
            # quality scoring); bbox is shifted into the warped/cropped test
            # frame in Phase 2.
            for p in prototypes:
                x1, y1, x2, y2 = p["bbox"]
                x1, x2 = sorted([x1, x2])
                y1, y2 = sorted([y1, y2])
                clipped = (
                    max(0, min(x1, Gw)), max(0, min(y1, Gh)),
                    max(0, min(x2, Gw)), max(0, min(y2, Gh)),
                )
                p["bbox"] = clipped
                p["bbox_golden"] = clipped

            # ── Load target image ────────────────────────────────────
            print(f"Step: Loading target image from {target_path}...")
            test_pil = Image.open(target_path).convert("RGB")
            test_pil = ImageOps.exif_transpose(test_pil)
            test_img = np.array(test_pil)
            Th, Tw = test_img.shape[:2]
            print(f"  Target size: {Tw}x{Th}")

            test_enh = enhance(test_img)

            # =====================================================================
            # PHASE 1: ANCHOR DETECTION + ALIGNMENT
            # =====================================================================
            print("\n── Phase 1: Anchor Detection + Alignment ────────────────────")
            yolo_golden = run_yolo_anchor(golden_img, PIPELINE_CONFIG["anchor_yolo_conf"])
            yolo_test = run_yolo_anchor(test_img, PIPELINE_CONFIG["anchor_yolo_conf"])
            print(f"  Golden high-conf detections: {len(yolo_golden)}")
            print(f"  Test high-conf detections:   {len(yolo_test)}")

            golden_anchors = select_anchor_candidates(
                yolo_golden, PIPELINE_CONFIG["anchor_yolo_conf"], PIPELINE_CONFIG["anchor_target_n"])
            test_anchors = select_anchor_candidates(
                yolo_test, PIPELINE_CONFIG["anchor_yolo_conf"], PIPELINE_CONFIG["anchor_target_n"])
            print(f"  Golden anchor candidates: {len(golden_anchors)}")
            print(f"  Test anchor candidates:   {len(test_anchors)}")

            inliers, H_anchor = match_anchors_ransac(
                golden_anchors, test_anchors, PIPELINE_CONFIG["anchor_min_n"])

            # Score every geometrically-sane candidate by how well it actually
            # lines up real content (NCC), not just whether RANSAC found
            # "enough" inlier points — a homography can look geometrically
            # fine (a plausible quad, reasonable scale) while still mapping
            # the wrong content onto the golden frame entirely, which the
            # sanity check alone can't detect on repetitive PCB textures.
            candidates = []  # (H, label, quality)

            if H_anchor is not None and is_homography_sane(H_anchor, Tw, Th):
                q = quick_alignment_quality(H_anchor, test_img, golden_img, prototypes, Gw, Gh)
                print(f"  Anchor candidate: {inliers} pairs, quality={q:.3f}")
                candidates.append((H_anchor, f"ANCHOR ({inliers} pairs)", q))
            elif H_anchor is not None:
                print("  Anchor homography failed sanity check (degenerate warp)")

            H_orb, n_orb_good, n_orb_inliers = align_with_orb(
                test_img, golden_img, PIPELINE_CONFIG)
            if is_homography_sane(H_orb, Tw, Th):
                q = quick_alignment_quality(H_orb, test_img, golden_img, prototypes, Gw, Gh)
                print(f"  ORB candidate: {n_orb_inliers}/{n_orb_good} inliers, quality={q:.3f}")
                candidates.append((H_orb, f"ORB ({n_orb_inliers}/{n_orb_good} inliers)", q))
            else:
                print("  ORB homography failed sanity check (degenerate warp)")

            if not candidates:
                # Neither passed geometric sanity — use ORB anyway as a last
                # resort (its quality score below will very likely fail the
                # usable-alignment floor and produce a clear error).
                q = quick_alignment_quality(H_orb, test_img, golden_img, prototypes, Gw, Gh)
                candidates.append((H_orb, f"ORB ({n_orb_inliers}/{n_orb_good} inliers) [unstable]", q))

            candidates.sort(key=lambda c: -c[2])
            H_test2golden, alignment_source, best_quality = candidates[0]
            print(f"  Alignment source: {alignment_source}  quality={best_quality:.3f}")

            if best_quality < PIPELINE_CONFIG["min_usable_alignment_quality"]:
                # Not just imprecise — the warped test image doesn't actually
                # correspond to the golden reference's content at all. This
                # is the "wraps into a totally different perspective" failure:
                # confidently mislabeling components on a garbage image is
                # worse than a clear, actionable error.
                raise HTTPException(
                    status_code=422,
                    detail=(
                        "This photo doesn't match the reference prototype "
                        "closely enough for reliable alignment (quality="
                        f"{best_quality:.2f}). Make sure you're photographing "
                        "the same board as the prototype, from a similar "
                        "angle and distance, with good lighting."
                    ),
                )

            # =====================================================================
            # PHASE 2: WARP TEST IMAGE TO GOLDEN FRAME
            # =====================================================================
            print("\n── Phase 2: Warp to Golden Frame ────────────────────────────")
            test_warped = cv2.warpPerspective(test_img, H_test2golden, (Gw, Gh))
            test_enh_warped = cv2.warpPerspective(test_enh, H_test2golden, (Gw, Gh))
            valid_mask = cv2.warpPerspective(
                np.full((Th, Tw), 255, dtype=np.uint8),
                H_test2golden, (Gw, Gh), flags=cv2.INTER_NEAREST,
            )
            print(f"  Warped test image to golden frame: {Gw}x{Gh}")

            # Crop away the black borders the warp introduces when the test
            # photo doesn't cover the full golden frame (e.g. part of the
            # board missing/out of shot), so the result is tightly framed
            # on real content instead of off-centre in a black canvas.
            test_warped, test_enh_warped, valid_mask, crop_x, crop_y = crop_to_valid_content(
                test_warped, test_enh_warped, valid_mask)
            Ch, Cw = test_warped.shape[:2]
            print(f"  Cropped to valid content: {Cw}x{Ch} (offset {crop_x},{crop_y})")

            # shift prototype boxes into the cropped coordinate frame
            for p in prototypes:
                x1, y1, x2, y2 = p["bbox"]
                p["bbox"] = (
                    max(0, min(x1 - crop_x, Cw)), max(0, min(y1 - crop_y, Ch)),
                    max(0, min(x2 - crop_x, Cw)), max(0, min(y2 - crop_y, Ch)),
                )

            # =====================================================================
            # PHASE 3: FASTSAM COMPONENT DETECTION + PROTOTYPE MATCHING
            # =====================================================================
            print("\n── Phase 3: FastSAM Component Detection ─────────────────────")
            fastsam_boxes = detect_fastsam(test_enh_warped, PIPELINE_CONFIG)
            print(f"  FastSAM detections after filtering: {len(fastsam_boxes)}")

            print("\nMatching FastSAM detections to prototypes by spatial overlap...")
            final_dets = []
            used_fastsam = set()

            for proto in prototypes:
                best_i, best_ov = None, 0.0
                for i, fb in enumerate(fastsam_boxes):
                    if i in used_fastsam:
                        continue
                    ov = box_overlap_fraction(proto["bbox"], fb)
                    if ov > best_ov:
                        best_ov, best_i = ov, i

                if best_i is not None and best_ov >= PIPELINE_CONFIG["match_overlap"]:
                    # matched: use FastSAM's box (more precise), keep prototype's label
                    final_dets.append({
                        "label": proto["label"], "bbox": fastsam_boxes[best_i],
                        "bbox_golden": proto["bbox_golden"],
                        "conf": 1.0, "status": "matched",
                    })
                    used_fastsam.add(best_i)
                else:
                    # FastSAM missed - use the prototype box as-is
                    final_dets.append({
                        "label": proto["label"], "bbox": proto["bbox"],
                        "bbox_golden": proto["bbox_golden"],
                        "conf": 1.0, "status": "matched",
                    })

            # FastSAM detections not matched to any prototype -> extras
            for i, fb in enumerate(fastsam_boxes):
                if i not in used_fastsam:
                    final_dets.append({
                        "label": "UNKNOWN", "bbox": fb,
                        "conf": 0.0, "status": "extra",
                    })

            # Drop boxes that mostly fall on the missing/out-of-frame part
            # of the board (black region left by the warp/crop) — nothing
            # real was captured there, so there's nothing to draw.
            before_ct = len(final_dets)
            final_dets = [
                d for d in final_dets
                if box_valid_fraction(d["bbox"], valid_mask) >= PIPELINE_CONFIG["min_box_valid_frac"]
            ]
            dropped_ct = before_ct - len(final_dets)
            if dropped_ct:
                print(f"  Dropped {dropped_ct} box(es) on missing/out-of-frame content")

            matched_ct = sum(1 for d in final_dets if d["status"] == "matched")
            extra_ct = sum(1 for d in final_dets if d["status"] == "extra")
            print(f"  Matched (prototype found): {matched_ct}")
            print(f"  Extras (unexpected)      : {extra_ct} (hidden from result)")

            # Extras are unlabeled FastSAM detections with no matching
            # prototype ("UNKNOWN") — noisy and not meaningful to the user,
            # so only matched (labeled) components are returned.
            final_dets = [d for d in final_dets if d["status"] == "matched"]

            # =====================================================================
            # PHASE 3.5: MISSING-COMPONENT DETECTION (DINOv2) + MARKING/RATING OCR
            # =====================================================================
            print("\n── Phase 3.5: DINOv2 Presence + EasyOCR Marking ──────────────")
            import time as _time
            missing_ct = 0
            for _i, d in enumerate(final_dets):
                _t0 = _time.monotonic()
                pad = (PIPELINE_CONFIG["ocr_pad_large"]
                       if str(d["label"]).lower() in PIPELINE_CONFIG["ocr_large_classes"]
                       else PIPELINE_CONFIG["ocr_pad_normal"])
                g_crop_ocr = get_padded_crop(golden_img, d["bbox_golden"], pad)
                t_crop_ocr = get_padded_crop(test_warped, d["bbox"], pad)

                # ---- presence: DINOv2 similarity between golden and test crop ----
                g_crop_dino = get_padded_crop(golden_img, d["bbox_golden"], PIPELINE_CONFIG["dino_pad_px"])
                t_crop_dino = get_padded_crop(test_warped, d["bbox"], PIPELINE_CONFIG["dino_pad_px"])
                if DINO_AVAILABLE:
                    sim = cosine_sim(embed_crop(g_crop_dino), embed_crop(t_crop_dino))
                    d["similarity"] = sim
                    sim_thresh = PIPELINE_CONFIG["dino_sim_thresh_by_class"].get(
                        str(d["label"]).lower(), PIPELINE_CONFIG["dino_sim_thresh"])
                    d["presence"] = (
                        "present" if (sim is not None and sim >= sim_thresh)
                        else "missing"
                    )
                    if d["presence"] == "missing":
                        missing_ct += 1
                else:
                    d["similarity"] = None
                    d["presence"] = "present"

                d["ssim"] = compute_ssim(g_crop_dino, t_crop_dino)

                # ---- marking/rating: EasyOCR on golden + test crops ----
                golden_text = run_ocr(g_crop_ocr, PIPELINE_CONFIG)
                test_text = run_ocr(t_crop_ocr, PIPELINE_CONFIG)
                d["marking"] = best_reading(golden_text, test_text)

                sim_str = f"{d['similarity']:.3f}" if d['similarity'] is not None else "-"
                ssim_str = f"{d['ssim']:.3f}" if d['ssim'] is not None else "-"
                print(f"  [{_i+1}/{len(final_dets)}] {d['label']:<16} "
                      f"{_time.monotonic() - _t0:.2f}s  presence={d['presence']}"
                      f"  sim={sim_str}  ssim={ssim_str}"
                      f"  marking={d['marking'] or '-'}")

            print(f"  Present: {len(final_dets) - missing_ct}  Missing: {missing_ct}"
                  f"  (DINOv2 {'enabled' if DINO_AVAILABLE else 'unavailable'})")
            readable_ct = sum(1 for d in final_dets if d["marking"])
            print(f"  Markings read: {readable_ct}/{len(final_dets)}"
                  f"  (EasyOCR {'enabled' if OCR_AVAILABLE else 'unavailable'})")

            # =====================================================================
            # PHASE 4: ANNOTATE + SAVE
            # =====================================================================
            print("\n── Phase 4: Annotation ──────────────────────────────────────")
            annotated_image = test_warped.copy()
            raw_detections = []
            for d in final_dets:
                x1, y1, x2, y2 = map(int, d["bbox"])
                is_missing = d["presence"] == "missing"
                color = (255, 60, 60) if is_missing else (0, 255, 0)  # RGB
                label_text = str(d["label"]).upper()
                if is_missing:
                    label_text = f"MISSING {label_text}"
                elif d["marking"]:
                    label_text = f"{label_text} ({d['marking']})"
                cv2.rectangle(annotated_image, (x1, y1), (x2, y2), color, 2)
                cv2.putText(annotated_image, label_text, (x1, max(0, y1 - 8)),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 2)
                raw_detections.append({
                    "label": str(d["label"]).upper(),
                    "conf": float(d["conf"]),
                    "bbox": [float(v) for v in d["bbox"]],
                    "marking": d["marking"],
                    "presence": d["presence"],
                    "similarity": d["similarity"],
                    "ssim": d["ssim"],
                })

            final_detections_count = len(raw_detections)
            print(f"  Total final detections: {final_detections_count}")

            result_filename = f"result_{project_id}_{unique_filename}"
            out_path = os.path.join(SAMPLES_DIR, result_filename)
            cv2.imwrite(out_path, cv2.cvtColor(annotated_image, cv2.COLOR_RGB2BGR))
            print(f"  Saved → {out_path}")

            raw_aligned_filename = f"aligned_raw_{project_id}_{unique_filename}"
            raw_aligned_path = os.path.join(SAMPLES_DIR, raw_aligned_filename)
            Image.fromarray(test_warped).save(raw_aligned_path)

            # DB paths frontend ke liye wahi (relative URL) rahenge
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

        except HTTPException:
            raise
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
