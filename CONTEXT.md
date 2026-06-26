# PCB Component Detection App — Full Context for AI Models

> **Purpose of this document:** Provide complete context about this application so that any AI model can understand the architecture, tech stack, data flow, codebase structure, and how everything connects — without needing to read every source file.

---

## 1. What This Application Does

This is a **full-stack PCB (Printed Circuit Board) component detection system**. It allows electronics engineers / quality inspectors to:

1. **Create a project** for a specific PCB design.
2. **Upload a prototype (reference) image** of the PCB and **draw bounding boxes** around each component (resistor, capacitor, LED, IC, etc.) using a visual annotation editor.
3. **Run AI-powered inference** on new sample images of the same PCB — the system automatically detects and classifies all components using a hybrid AI pipeline.
4. **Review results** — view annotated images with bounding boxes, filter by component type, and browse inference history.

There are two user roles:
- **Admin**: Creates projects, uploads prototypes, draws annotations, manages users, assigns project status labels.
- **User**: Selects a project, captures/uploads a new PCB sample image, runs inference, and reviews detection results.

---

## 2. High-Level Architecture

```
┌─────────────────────────────────┐       HTTP (REST API)       ┌──────────────────────────────────┐
│                                 │  ◄──────────────────────►   │                                  │
│   Flutter Mobile App (Android)  │        port 8000            │   FastAPI Backend (Python)        │
│   ─────────────────────────     │                             │   ────────────────────────        │
│   • Dart / Flutter SDK          │                             │   • FastAPI + Uvicorn             │
│   • dio (HTTP client)           │                             │   • SQLAlchemy + SQLite           │
│   • image_picker (camera/gallery)│                            │   • PyTorch (CUDA GPU)            │
│   • shared_preferences          │                             │   • YOLOE, YOLOv10, MobileCLIP    │
│   • Material Design 3 UI        │                             │   • OpenCV, Pillow, Supervision   │
│                                 │                             │   • Static file serving (/storage)│
└─────────────────────────────────┘                             └──────────────────────────────────┘
```

The Flutter app communicates with the backend over the **local network** via HTTP. The backend base URL is hardcoded in `api_service.dart` (e.g., `http://10.145.7.54:8000`) and must match the machine running the server.

---

## 3. Technology Stack

### 3.1 Backend (Python)

| Technology | Version | Purpose |
|---|---|---|
| **FastAPI** | 0.136.3 | Web framework — REST API endpoints |
| **Uvicorn** | 0.49.0 | ASGI server to run FastAPI |
| **SQLAlchemy** | 2.0.50 | ORM for database access |
| **SQLite** | (built-in) | Lightweight file-based database (`visual_prompt.db`) |
| **PyTorch** | 2.7.1+cu118 | Deep learning framework (CUDA 11.8 GPU build) |
| **Ultralytics (YOLOE fork)** | THU-MIG fork | YOLOE visual-prompt detection model |
| **YOLOv10** | via ultralytics | Fine-tuned PCB component detector (10 classes) |
| **MobileCLIP** | — | Image embedding model for semantic classification |
| **OpenCV** | 4.13.0 | Image processing (perspective warp, drawing, I/O) |
| **Pillow** | 12.2.0 | Image loading, EXIF handling, format conversion |
| **Supervision** | 0.28.0 | Bounding box annotation utilities |
| **NumPy** | 2.4.6 | Numerical array operations |
| **python-multipart** | 0.0.32 | Multipart form data parsing (file uploads) |

### 3.2 Frontend (Flutter/Dart)

| Technology | Version | Purpose |
|---|---|---|
| **Flutter SDK** | ^3.10.4 | Cross-platform UI framework (targeting Android) |
| **Dart** | ^3.10.4 | Programming language |
| **dio** | ^5.4.0 | HTTP client for API requests and multipart uploads |
| **image_picker** | ^1.0.7 | Camera and gallery access for capturing PCB images |
| **path_provider** | ^2.1.2 | Local file system path resolution |
| **shared_preferences** | ^2.5.5 | Persistent key-value storage (login state, role) |
| **Material Design 3** | built-in | UI component library with custom warm color scheme |

### 3.3 Infrastructure

| Technology | Purpose |
|---|---|
| **Docker Compose** | Orchestrates backend container (GPU-enabled) + optional APK builder |
| **NVIDIA CUDA 11.8** | GPU acceleration for model inference |
| **nvidia-container-toolkit** | Exposes host GPU to Docker container |

---

## 4. Project Directory Structure

```
component_detection_app/
├── backend/                          ← Python FastAPI server
│   ├── app/                          ← Core application package
│   │   ├── __init__.py               ← Package marker (empty)
│   │   ├── main.py                   ← FastAPI app entry point, all routes
│   │   ├── models.py                 ← SQLAlchemy ORM table definitions
│   │   ├── schemas.py                ← Pydantic request/response schemas
│   │   ├── database.py               ← SQLite engine + session factory
│   │   └── ml_pipeline.py            ← AI inference pipeline + box CRUD endpoints
│   ├── storage/                      ← Runtime file storage (images, auth JSON)
│   │   ├── admins.json               ← Admin credentials
│   │   ├── users.json                ← User credentials
│   │   ├── project_<id>_proto.jpg    ← Uploaded prototype images
│   │   ├── samples/                  ← Uploaded + annotated inference images
│   │   └── cropped_components/       ← Debug output from crop_boxes.py
│   ├── Dockerfile                    ← Backend Docker image (CUDA 11.8 base)
│   ├── requirements.txt              ← All Python dependencies (pinned)
│   ├── visual_prompt.db              ← SQLite database file (auto-created)
│   ├── yoloe-v8l-seg.pt             ← YOLOE model weights (~107 MB)
│   ├── yolov10n_pcb_10classes_best.pt← YOLOv10 PCB model weights (~6 MB)
│   ├── mobileclip_blt.pt            ← MobileCLIP model weights (~599 MB)
│   ├── check_db.py                   ← Debug: dump all DB tables to terminal
│   ├── crop_boxes.py                 ← Debug: crop bounding box regions from prototype
│   ├── visualize_boxes.py            ← Debug: draw all boxes on prototype image
│   ├── test_classifier.py            ← Unit test for MobileCLIP classifier
│   └── test_pipeline.py              ← Integration test for full inference pipeline
│
├── frontend_app/                     ← Flutter Android application
│   ├── lib/
│   │   ├── main.dart                 ← App entry point, MaterialApp, DashboardScreen
│   │   ├── models/
│   │   │   ├── project.dart          ← Project data class + fromJson()
│   │   │   └── sample.dart           ← Sample + Detection data classes + fromJson()
│   │   ├── screens/
│   │   │   ├── login.dart            ← Login screen (admin/user role toggle)
│   │   │   ├── admin_dashboard.dart  ← Admin project list with label filtering
│   │   │   ├── project_hub_screen.dart← User project hub (inference + history nav)
│   │   │   ├── prototype_editor_screen.dart ← Bounding box annotation editor (~50KB)
│   │   │   ├── inference_screen.dart ← AI inference trigger + result display
│   │   │   ├── sample_detail_screen.dart ← Past inference result detail + filtering
│   │   │   └── create_user.dart      ← Admin user creation form
│   │   └── services/
│   │       └── api_service.dart      ← Centralized HTTP client (dio-based)
│   ├── android/                      ← Android platform configuration
│   ├── pubspec.yaml                  ← Flutter dependencies manifest
│   └── Dockerfile                    ← APK builder Docker image
│
├── docker-compose.yml                ← Orchestrates backend + APK builder
├── description.md                    ← Structural description of files/folders
└── CONTEXT.md                        ← This file
```

---

## 5. Database Schema

The backend uses **SQLite** via SQLAlchemy ORM. The database file is `backend/visual_prompt.db`.

### 5.1 `projects` Table

| Column | Type | Description |
|---|---|---|
| `id` | Integer (PK) | Auto-increment project ID |
| `name` | String | Project name |
| `created_at` | DateTime | Creation timestamp (UTC) |
| `prototype_path` | String (nullable) | File path to uploaded prototype image |
| `label` | String | Status label — `"ongoing"`, `"completed"`, or custom |

### 5.2 `bounding_boxes` Table

| Column | Type | Description |
|---|---|---|
| `id` | Integer (PK) | Auto-increment box ID |
| `project_id` | Integer (FK → projects.id) | Parent project |
| `label` | String | Component class name (e.g., `"resistor"`, `"capacitor"`, `"led"`) |
| `x1`, `y1` | Float | Top-left corner coordinates (in prototype image pixel space) |
| `x2`, `y2` | Float | Bottom-right corner coordinates (in prototype image pixel space) |

### 5.3 `samples` Table

| Column | Type | Description |
|---|---|---|
| `id` | Integer (PK) | Auto-increment sample ID |
| `project_id` | Integer (FK → projects.id) | Parent project |
| `original_path` | String | Path to the raw/aligned uploaded sample image |
| `annotated_path` | String (nullable) | Path to the AI-annotated result image |
| `results_data` | String (nullable) | JSON string of detection results (array of `{label, conf, bbox}`) |
| `status` | String | `"pending"`, `"completed"`, or `"failed"` |
| `timestamp` | DateTime | Inference run timestamp (UTC) |

**Relationships:**
- `Project` → has many `BoundingBox` (one-to-many, cascade)
- `Project` → has many `Sample` (one-to-many, cascade)

---

## 6. REST API Endpoints

All endpoints are served by FastAPI on port `8000`.

### 6.1 Project Management

| Method | Path | Description |
|---|---|---|
| `POST` | `/projects/` | Create a new project. Body: `{"name": "..."}` |
| `GET` | `/projects/` | List all projects (paginated with `skip`/`limit` query params) |
| `PUT` | `/projects/{id}/label` | Update project status label. Body: `{"label": "..."}` |

### 6.2 Prototype & Bounding Boxes

| Method | Path | Description |
|---|---|---|
| `POST` | `/projects/{id}/prototype` | Upload prototype image + bounding boxes. Multipart form: `file` (image) + `boxes` (JSON string of box array) |
| `GET` | `/projects/{id}/boxes` | Get all bounding boxes for a project |
| `PUT` | `/projects/{id}/boxes` | Replace all bounding boxes for a project. Body: `{"boxes": [...]}` |

### 6.3 AI Inference

| Method | Path | Description |
|---|---|---|
| `POST` | `/projects/{id}/inference` | Run AI detection on uploaded sample image. Multipart form: `file` (image). Returns annotated image path + JSON detections. **Long-running** (~10-60 seconds). |
| `GET` | `/projects/{id}/samples` | List all past inference runs for a project (ordered by timestamp descending) |

### 6.4 Authentication

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/login` | Login. Body: `{"email_or_mobile": "...", "password": "...", "role": "admin"|"user"}` |
| `POST` | `/api/users` | Create new user (admin only). Body: `{"email": "...", "mobile": "...", "password": "..."}` |

### 6.5 Utility

| Method | Path | Description |
|---|---|---|
| `GET` | `/health` | Health check endpoint |
| `GET` | `/storage/...` | Static file serving for all uploaded/generated images |

> **Note:** Authentication is simple JSON-file-based (no JWT/tokens). Credentials are stored in `storage/admins.json` and `storage/users.json`. Default admin: `admin@plant.com` / `admin`.

---

## 7. AI Inference Pipeline — How It Works

The inference pipeline (`ml_pipeline.py`) is the core of the application. It uses a **hybrid 5-phase approach** combining visual prompting with a trained detector.

### 7.1 Three AI Models Loaded at Startup

| Model | File | Architecture | Purpose |
|---|---|---|---|
| **align_model** | `yoloe-v8l-seg.pt` | YOLOE-v8 Large (segmentation) | Phase 1: Detect the PCB board outline in the sample image for perspective alignment |
| **vp_model** | `yoloe-v8l-seg.pt` | YOLOE-v8 Large (segmentation) | Phase 2: Visual-prompt inference — learns component appearance from prototype boxes, detects them in new images |
| **trained_model** | `yolov10n_pcb_10classes_best.pt` | YOLOv10 Nano | Phase 3: Pre-trained PCB detector specifically for capacitor detection (10 classes) |

### 7.2 The 5-Phase Pipeline

When a user submits a sample image via `POST /projects/{id}/inference`:

#### Phase 1: Board Alignment
- Uses `align_model` to detect the PCB board region in the sample image via segmentation.
- If found, extracts a mask → finds the minimum-area rotated rectangle → applies a **perspective warp** (homography) to straighten and crop the board.
- If no board detected, the original image is used as-is.

#### Phase 2: YOLOE Visual Prompting (all classes except capacitor)
- Filters out any "capacitor" bounding boxes from the prototype annotations (capacitors are handled by the trained model in Phase 3).
- **Reloads a fresh YOLOE model** to clear old visual prompt embeddings from memory.
- Sets the model's class names to the unique labels from the prototype boxes (e.g., `["ic", "led", "resistor"]`).
- **Step 1 — VPE Encoding:** Runs the prototype image through YOLOE with the annotated bounding boxes as "visual prompts" using `YOLOEVPSegPredictor`. This teaches the model what each component looks like.
- **Step 2 — Save VPE:** Stores the learned visual prompt embeddings (VPE) as named class embeddings inside the model.
- **Step 3 — Switch to Standard Mode:** Removes the VP predictor to revert to standard detection mode.
- **Step 4 — Inference:** Runs standard YOLOE inference on the aligned sample image. The model now recognizes the components it learned from the prototype.
- Applies **per-class confidence thresholds** (defined in `YOLOE_CLASS_THRESHOLDS` dict) to filter weak detections.

#### Phase 3: Capacitor Detection (Trained Model)
- Runs the pre-trained `YOLOv10` model on the aligned sample image.
- Filters results to keep **only capacitor detections** (the trained model handles capacitors better than visual prompting).

#### Phase 4: Merge Detections
- Combines YOLOE visual-prompt detections (non-capacitor components) + YOLOv10 capacitor detections into a single unified detection list.
- Each detection has: `label` (string), `conf` (confidence float), `bbox` ([x1, y1, x2, y2] in pixel coordinates).

#### Phase 5: Annotate & Save
- Draws bounding boxes and labels on the aligned sample image using the `supervision` library.
- Saves the annotated image to `storage/samples/result_<project_id>_<uuid>_<filename>`.
- Also saves the raw aligned (unannotated) image for the frontend detail view.
- Creates a `Sample` record in the database with `original_path`, `annotated_path`, `results_data` (JSON string of detections), and `status = "completed"`.

### 7.3 Key Technical Details

- **Concurrency:** An `asyncio.Lock()` (`inference_lock`) ensures only one inference runs at a time (GPU memory constraint).
- **EXIF Handling:** Both prototype and sample images are EXIF-transposed before processing to handle mobile camera rotation metadata.
- **Coordinate System:** Bounding box coordinates are stored in **prototype image pixel space** (not display/screen space). The frontend performs coordinate mapping between display pixels and image pixels using aspect-ratio-locked rendering.
- **Per-Class Thresholds:** Different component types have different minimum confidence thresholds (e.g., LED: 0.116, IC: 0.160, crystal oscillator: 0.165) to balance precision/recall per class.

---

## 8. Frontend — Screen Flow & Navigation

```
LoginScreen
  ├── (admin) → AdminDashboardScreen
  │                ├── PrototypeEditorScreen (draw/edit bounding boxes)
  │                └── CreateUserScreen
  │
  └── (user)  → DashboardScreen (main.dart)
                   └── ProjectHubScreen
                        ├── InferenceScreen (capture + run AI)
                        │      └── SampleDetailScreen (view result)
                        └── SampleDetailScreen (view past results)
```

### 8.1 Key Screens

**LoginScreen** (`login.dart`): Email/mobile + password fields with admin/user role toggle. Persists login state via `SharedPreferences`.

**AdminDashboardScreen** (`admin_dashboard.dart`): Lists all projects with status label chips (ongoing/completed/custom). Supports filtering. Long-press to change labels. Navigate to prototype editor.

**DashboardScreen** (`main.dart`): User-facing project list with the same filter chips. Navigate to `ProjectHubScreen`.

**PrototypeEditorScreen** (`prototype_editor_screen.dart`, ~50KB — largest file): Full annotation editor. Displays the prototype image on an **aspect-ratio-locked canvas**. Supports:
- Drawing new bounding boxes via touch/drag
- Moving and resizing existing boxes via drag handles
- Labeling boxes with component names
- Saving all boxes + image to backend via multipart POST
- Loading existing boxes from backend on screen open

**InferenceScreen** (`inference_screen.dart`): Pick image from camera/gallery → upload to `/projects/{id}/inference` → show loading spinner → display annotated result. Validates prototype exists before allowing inference.

**SampleDetailScreen** (`sample_detail_screen.dart`): Shows a past inference result. Displays the annotated image + a filterable list of detected component types. Tapping a component type highlights only those detections on the image using **local coordinate rendering** (no server round-trip).

### 8.2 API Communication

All HTTP calls go through `ApiService` (`api_service.dart`) which wraps the `dio` package:
- Base URL: `http://<server-ip>:8000` (hardcoded, must be updated per deployment)
- Standard timeout: 60 seconds
- Inference timeout: 120 seconds (separate `Dio` instance)
- Image URLs are constructed by concatenating `baseUrl + path` (e.g., `http://10.145.7.54:8000/storage/samples/result_1_abc.jpg`)

---

## 9. Data Flow — End to End

### 9.1 Prototype Annotation Flow (Admin)

```
Admin opens PrototypeEditorScreen
  → Loads prototype image from: GET /storage/project_<id>_proto.jpg
  → Loads existing boxes from: GET /projects/{id}/boxes
  → Admin draws/edits bounding boxes on canvas
  → Admin taps "Save"
  → Flutter sends: POST /projects/{id}/prototype
      Body: multipart form {
        file: prototype image (JPEG),
        boxes: JSON string [{"label":"resistor","x1":100,"y1":200,"x2":300,"y2":400}, ...]
      }
  → Backend saves image to storage/project_<id>_proto.jpg
  → Backend deletes old boxes, inserts new ones into bounding_boxes table
  → Returns: {"status": "success", "boxes_saved": N}
```

### 9.2 AI Inference Flow (User)

```
User opens InferenceScreen
  → Checks if prototype exists for the project
  → User picks/captures a PCB sample image
  → Flutter sends: POST /projects/{id}/inference
      Body: multipart form { file: sample image (JPEG) }
  → Backend runs 5-phase pipeline (10-60 seconds):
      Phase 1: Board alignment (perspective warp)
      Phase 2: YOLOE visual prompting (non-capacitor components)
      Phase 3: YOLOv10 capacitor detection
      Phase 4: Merge all detections
      Phase 5: Annotate image + save to DB
  → Returns: {
      "status": "success",
      "sample": {
        "id": 1,
        "project_id": 1,
        "original_path": "/storage/samples/aligned_raw_1_abc.jpg",
        "annotated_path": "/storage/samples/result_1_abc.jpg",
        "results_data": "[{\"label\":\"RESISTOR\",\"conf\":0.85,\"bbox\":[100,200,300,400]}, ...]",
        "timestamp": "2026-06-23T12:00:00"
      }
    }
  → Flutter displays annotated image from: GET {baseUrl}{annotated_path}
```

### 9.3 Results Data Format

The `results_data` field in the `samples` table is a JSON string containing an array of detection objects:

```json
[
  {
    "label": "RESISTOR",
    "conf": 0.856,
    "bbox": [120.5, 200.3, 310.8, 400.1]
  },
  {
    "label": "CAPACITOR",
    "conf": 0.923,
    "bbox": [500.0, 100.0, 620.0, 250.0]
  }
]
```

- `label`: Uppercase component class name
- `conf`: Confidence score (0.0–1.0)
- `bbox`: `[x1, y1, x2, y2]` in aligned image pixel coordinates

---

## 10. Running the Application

### Backend (Local — requires NVIDIA GPU)

```bash
cd backend
python -m venv venv
venv\Scripts\activate          # Windows
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

### Backend (Docker — requires nvidia-container-toolkit)

```bash
docker compose up backend
```

### Frontend (Flutter)

```bash
cd frontend_app
# First: update baseUrl in lib/services/api_service.dart to your server's IP
flutter run                    # USB-connected Android device
# or
flutter build apk --release   # Build APK
```

---

## 11. Important Caveats & Gotchas

1. **Base URL is hardcoded** in `api_service.dart`. It must be the server machine's local network IP. If the machine's IP changes, the app won't connect.

2. **Bounding box coordinates are in image pixel space**, not display/screen space. The frontend maps between screen coordinates and image coordinates using aspect-ratio-locked rendering. Any coordinate mismatch will cause detection drift.

3. **The YOLOE VP model is reloaded fresh for every inference** to clear old visual prompt embeddings from GPU memory. This adds ~5 seconds per inference but prevents cross-contamination between different prompt sets.

4. **Capacitors are excluded from YOLOE visual prompting** and handled exclusively by the pre-trained YOLOv10 model, because the trained model performs better for this specific class.

5. **Authentication is basic** — plaintext passwords in JSON files, no tokens/JWT. This is a prototype/internal tool, not production-grade auth.

6. **Only one inference can run at a time** due to the `asyncio.Lock()`. Concurrent inference requests will queue.

7. **The `/storage` directory is mounted as a static file server**, so all uploaded and generated images are directly accessible via URL (e.g., `http://server:8000/storage/samples/result_1.jpg`).

8. **EXIF transpose is critical** — mobile camera images often have rotation metadata. Both the backend pipeline and the frontend must handle this to prevent coordinate misalignment.

---

## 12. File-by-File Quick Reference

### Backend Core Files

| File | Lines | What It Does |
|---|---|---|
| `app/main.py` | 166 | FastAPI app, CORS, routes for projects/prototype/auth, static file mount |
| `app/ml_pipeline.py` | 654 | AI pipeline (5 phases), box CRUD endpoints, model loading, inference lock |
| `app/models.py` | 43 | SQLAlchemy ORM: Project, BoundingBox, Sample tables |
| `app/schemas.py` | 48 | Pydantic schemas: ProjectCreate/Response, BoxIn, LoginRequest, SampleResponse |
| `app/database.py` | 20 | SQLite engine, SessionLocal factory, get_db() dependency |

### Frontend Core Files

| File | Lines | What It Does |
|---|---|---|
| `lib/main.dart` | 292 | App entry point, theme, DashboardScreen with project list + label filters |
| `lib/services/api_service.dart` | 117 | Dio HTTP client wrapping all backend API calls |
| `lib/models/project.dart` | 27 | Project data class (id, name, createdAt, prototypePath, label) |
| `lib/models/sample.dart` | 62 | Sample + Detection data classes with JSON parsing |
| `lib/screens/login.dart` | ~400 | Login UI with role toggle, SharedPreferences persistence |
| `lib/screens/admin_dashboard.dart` | ~100 | Admin project list with label management |
| `lib/screens/project_hub_screen.dart` | ~120 | User project hub (inference + history navigation) |
| `lib/screens/prototype_editor_screen.dart` | ~1400 | Full bounding box annotation editor (largest file) |
| `lib/screens/inference_screen.dart` | ~350 | Image capture → AI inference → result display |
| `lib/screens/sample_detail_screen.dart` | ~250 | Past inference detail with component type filtering |
| `lib/screens/create_user.dart` | ~150 | Admin user creation form |
