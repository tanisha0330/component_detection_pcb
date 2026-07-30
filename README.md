# Component Detection App

A full-stack PCB (Printed Circuit Board) component inspection system. An admin
uploads a reference ("prototype") photo of a board design and draws a
bounding box + label around every component that should be on it. A user can
then photograph any board of that same design and the backend AI pipeline
will:

- align the new photo to the reference photo (homography),
- locate every expected component,
- flag any component that appears to be **missing** (DINOv2 visual
  similarity vs. the reference),
- read each component's printed **marking/value** off the board (EasyOCR),
  e.g. a resistor's `322` value code.

The Flutter app then lets you filter results by component type or by
present/missing status, and tap a single detected component to isolate its
box in the image.

---

## 1. Architecture

```
Flutter app (Android)  <--HTTP/REST-->  FastAPI backend (Python, GPU)
                                            |
                                            ├─ SQLite (projects/boxes/samples)
                                            ├─ pcb_anchor_yolo.pt   (anchor + component YOLO)
                                            ├─ FastSAM-x.pt         (component segmentation)
                                            ├─ DINOv2 (torch.hub)   (missing-component check)
                                            └─ EasyOCR              (marking/rating OCR)
```

- **Backend**: `backend/app/` — FastAPI + SQLAlchemy + PyTorch. Entry point
  is `app/main.py`; the AI pipeline lives in `app/ml_pipeline.py`.
- **Frontend**: `frontend_app/` — Flutter/Dart, targets Android.

See `CONTEXT.md` for a deep dive into the API and data model (note: parts of
it describe an older pipeline revision — `ml_pipeline.py` is the source of
truth for current behavior).

---

## 2. Prerequisites

| For | You need |
|---|---|
| Getting the code | Git |
| Backend (Docker path — recommended) | Docker Desktop + [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) (for GPU acceleration) |
| Backend (local/no-Docker path) | Python 3.11, `pip`, `git` (some deps install from GitHub), ideally an NVIDIA GPU + CUDA 11.8 driver |
| Frontend | Flutter SDK `^3.10.4`, Android Studio/SDK, a physical Android device (USB debugging) or emulator |
| Both | Same local network/Wi-Fi for the phone and the machine running the backend |

A GPU is **not strictly required** — PyTorch falls back to CPU automatically
— but the anchor/FastSAM/DINOv2 models are slow enough on CPU that a real
board photo can take minutes instead of seconds per inference.

---

## 3. Get the code

```bash
git clone <this-repo-url>
cd component_detection_app
```

---

## 4. Get the model weight files

The `.pt` model weight files are **not stored in git** (`backend/.gitignore`
excludes `*.pt` — they're large binaries). Before starting the backend you
must place these two files directly inside `backend/`:

- `pcb_anchor_yolo.pt` — trained YOLO model (anchor detection + component classes)
- `FastSAM-x.pt` — FastSAM segmentation model

Get them from whoever is handing off the project (shared drive / previous
teammate). `mobileclip_blt.pt`, `yoloe-v8l-seg.pt`, and
`yolov10n_pcb_10classes_best.pt` are leftovers from an earlier pipeline
revision and are **not** used by the current `ml_pipeline.py` — you don't
need them to run the app.

DINOv2 and EasyOCR's own model weights are downloaded automatically on first
run (`torch.hub` / EasyOCR's own downloader) — no manual step needed for
those, just an internet connection the first time the backend starts.

---

## 5. Backend setup

### Option A — Docker (recommended)

```bash
docker compose up backend
```

This builds a CUDA 11.8 image, installs all Python deps, and — during the
build — pre-downloads and bakes in the DINOv2 and EasyOCR weights so the
running container doesn't need internet access later. Requires
`nvidia-container-toolkit` on the host for GPU access (edit the `deploy:`
block out of `docker-compose.yml` if you don't have an NVIDIA GPU, though the
image is still CUDA-based).

The API will be reachable at `http://localhost:8000` on the host machine,
and at `http://<host-LAN-IP>:8000` from your phone.

### Option B — Local Python (no Docker)

```bash
cd backend
python -m venv venv
venv\Scripts\activate          # Windows
# source venv/bin/activate     # macOS/Linux

pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

Notes:
- Run these commands **from `backend/`** — the app resolves `storage/` and
  the `.pt` weight files relative to the current working directory.
- `requirements.txt` pins CUDA 11.8 PyTorch builds and includes
  `--extra-index-url https://download.pytorch.org/whl/cu118` at the top so a
  single `pip install -r requirements.txt` resolves them; if you're on a
  machine with no NVIDIA GPU at all, you can instead install plain CPU
  wheels of `torch`/`torchvision`/`torchaudio` first, then run
  `pip install -r requirements.txt` (pip will skip re-installing them).
- `ultralytics` installs from a pinned GitHub commit — needs `git` on PATH
  and internet access during install.
- First backend startup downloads the DINOv2 (~85MB) and EasyOCR model
  weights — needs internet once. If that download fails (offline / blocked),
  the backend still starts; it just logs a warning and disables
  missing-component detection / marking OCR gracefully rather than crashing.

### Verify it's running

```
curl http://localhost:8000/health
# {"status":"healthy"}
```

A default admin login is auto-created on first run:
`admin@plant.com` / `admin` (stored in `backend/storage/admins.json`).

---

## 6. Frontend setup (Flutter)

```bash
cd frontend_app
flutter pub get
```

### Point the app at your backend

Edit `lib/services/api_service.dart`:

```dart
static const String baseUrl = 'http://<your-machine-LAN-IP>:8000';
```

This must be the **LAN IP of the machine running the backend** (not
`localhost` — the phone is a separate device on the network). Find it with:

- Windows: `ipconfig` → look for the `IPv4 Address` under your active
  Wi-Fi/Ethernet adapter
- macOS/Linux: `ifconfig` or `ip addr`

This IP can change when you reconnect to Wi-Fi or switch networks — if the
app suddenly can't reach the backend, re-check it here first.

### Run

```bash
flutter run                    # deploy to a connected/emulated Android device
# or
flutter build apk --release    # produce an installable APK
```

---

## 7. First-time walkthrough

1. Log in (default admin: `admin@plant.com` / `admin`), or create a user
   from the admin dashboard.
2. **Admin**: create a project, upload a prototype photo of the board, and
   draw + label a bounding box around every component that should be on it
   (resistor, capacitor, ic, led, ...). Save.
3. **User**: open the project, tap "Run New Inference", and
   capture/upload a photo of a real board of that same design.
4. Review the result:
   - **Filter** dropdown narrows by component label.
   - **Rating** filter narrows by Present / Missing (from the DINOv2 check).
   - Tap a component in the bottom list to isolate just that box in the
     image above; tap it again to go back to the full view.

---

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `DioException [receive timeout]` on inference | Backend is CPU-bound or the board has many components — check backend logs (Phase 3.5 now prints per-component timing). The inference `Dio` timeout is 5 minutes; a GPU makes this a non-issue. |
| App can't reach the backend at all | `baseUrl` in `api_service.dart` doesn't match the backend machine's current LAN IP (see §6), or the two devices aren't on the same network. |
| `pip install -r requirements.txt` fails to find `torch==...+cu118` | Missing the PyTorch extra index — it's included at the top of `requirements.txt`; make sure you're installing from that file, not copy-pasting individual lines. |
| Backend logs "DINOv2 unavailable" / "EasyOCR unavailable" | No internet on first run to fetch those model weights. The app still works — missing-component detection defaults to "present" and markings are left blank. Restart with internet access once to fix permanently (Docker path bakes these in at build time so this shouldn't happen there). |
| `422` error: "This photo doesn't match the reference prototype..." | The uploaded photo doesn't align well enough with the prototype — retake it at a similar angle/distance/lighting, same board design. |
| "No prototype uploaded" | An admin needs to upload a prototype + boxes for that project before a user can run inference. |

---

## 9. Repo layout (quick reference)

```
component_detection_app/
├── backend/
│   ├── app/
│   │   ├── main.py           # FastAPI app, routes, auth
│   │   ├── ml_pipeline.py    # AI inference pipeline (source of truth)
│   │   ├── models.py         # SQLAlchemy tables
│   │   ├── schemas.py        # Pydantic schemas
│   │   └── database.py       # SQLite engine/session
│   ├── requirements.txt      # Local (non-Docker) Python deps
│   ├── Dockerfile
│   ├── pcb_anchor_yolo.pt    # (you provide — see §4)
│   ├── FastSAM-x.pt          # (you provide — see §4)
│   └── storage/              # runtime images, admins.json/users.json, DB
├── frontend_app/
│   ├── lib/
│   │   ├── models/            # Project, Sample, Detection
│   │   ├── screens/           # login, dashboards, inference, editor, etc.
│   │   └── services/api_service.dart  # backend base URL + HTTP calls
│   └── pubspec.yaml
├── docker-compose.yml
├── CONTEXT.md                 # deeper architecture/API reference
└── README.md                  # this file
```
