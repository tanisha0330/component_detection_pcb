# Component Detection App — Project Description

A full-stack PCB (Printed Circuit Board) component detection system. Users create projects, annotate a **prototype** (reference) PCB image with bounding boxes, and then run AI-powered inference on new sample images to automatically detect and classify components.

---

## High-Level Architecture

```
component_detection_app/
├── backend/          ← FastAPI (Python) server — AI inference, REST API, SQLite DB
├── frontend_app/     ← Flutter mobile app — UI for users and admins
├── docker-compose.yml← Orchestrates backend container + Flutter APK builder
├── .gitignore        ← Root-level git ignore rules
└── description.md    ← This file
```

The **backend** exposes a REST API on port `8000`. The **frontend** (Flutter Android app) communicates with it over the local network via HTTP.

---

## Root-Level Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Defines two Docker services: `backend` (GPU-enabled FastAPI server) and `apk-build` (one-shot Flutter APK build container). Run `docker compose up backend` to start the server. |
| `.gitignore` | Excludes build artefacts, model weights, virtual environments, and Flutter generated files from version control. |
| `description.md` | This document — explains the project structure. |

---

## `backend/` — FastAPI AI Server

The Python backend handles all data persistence and AI inference. It uses **FastAPI** as the web framework, **SQLAlchemy** + **SQLite** for the database, and **PyTorch** models (YOLOE, YOLOv10, MobileCLIP) for component detection.

### `backend/app/` — Core Application Package

| File | Purpose |
|---|---|
| `main.py` | **Entry point** for the FastAPI application. Registers all REST API routes (projects, samples, prototype upload, login, user management), sets up CORS middleware, and mounts the `/storage` directory as a static file server so uploaded images are accessible via URL. |
| `models.py` | **SQLAlchemy ORM models** — defines the three database tables: `Project` (name, prototype path, status label), `BoundingBox` (annotated component regions per project), and `Sample` (each inference run's image paths and JSON detection results). |
| `schemas.py` | **Pydantic schemas** for request/response validation. Includes `ProjectCreate`, `ProjectResponse`, `BoxIn`, `LoginRequest`, `UserCreate`, and `SampleResponse`. |
| `database.py` | **Database connection setup**. Creates the SQLite engine (`visual_prompt.db`), the `SessionLocal` factory, and the `get_db()` dependency used by all route handlers. |
| `ml_pipeline.py` | **Core AI pipeline** (the largest file). Contains the FastAPI `router` with the `/projects/{id}/inference` endpoint. Loads three models — YOLOE (visual prompting / segmentation), YOLOv10 (PCB-specific 10-class detector), and MobileCLIP (image embedding for classification). Orchestrates the hybrid detection workflow: runs visual-prompt inference using prototype bounding boxes, saves the annotated result image, and stores detection data back to the `Sample` record in the database. Also handles coordinate rescaling to map between display-space and image-space pixels. |
| `__init__.py` | Marks the `app/` directory as a Python package (empty file). |

### `backend/` — Root-Level Utility Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the backend Docker image. Based on NVIDIA CUDA 11.8, installs Python dependencies, copies model weights, and starts Uvicorn on port `8000`. |
| `requirements.txt` | All Python dependencies: FastAPI, Uvicorn, SQLAlchemy, PyTorch, Ultralytics, MobileCLIP, Pillow, etc. |
| `visual_prompt.db` | **SQLite database file** (auto-created at runtime). Stores all projects, bounding boxes, and inference sample records. |
| `check_db.py` | **Debug utility** — prints the contents of all database tables to the terminal. Run with `python check_db.py` to inspect the current DB state. |
| `crop_boxes.py` | **Utility script** — reads all `BoundingBox` records from the database, crops those regions from the prototype image, and saves individual PNG files to `storage/cropped_components/`. Used to visually verify that bounding box coordinates are correctly aligned with the image. |
| `visualize_boxes.py` | **Utility script** — draws all stored bounding boxes directly onto the prototype image and saves the result. Useful for debugging annotation accuracy. |
| `test_classifier.py` | **Unit test** for the MobileCLIP-based component classifier in isolation. |
| `test_pipeline.py` | **Integration test** — runs the full inference pipeline end-to-end against a local image file without needing the Flutter app. |
| `yoloe-v8l-seg.pt` | Pre-trained **YOLOE** model weights (large segmentation variant). Used for visual-prompt-guided detection — given a prototype bounding box, it finds matching components in a new image. |
| `yolov10n_pcb_10classes_best.pt` | Fine-tuned **YOLOv10** model weights trained on a PCB dataset with 10 component classes (e.g., capacitor, resistor, IC). Used as the primary detector in the hybrid pipeline. |
| `mobileclip_blt.pt` | Pre-trained **MobileCLIP** model weights. Used for visual embedding and semantic classification of detected components. |

### `backend/storage/` — Runtime File Storage

All files here are created at runtime and are **not** committed to git.

| Path | Purpose |
|---|---|
| `admins.json` | Stores admin credentials (email + hashed password). Seeded with a default `admin@plant.com` account on first run. |
| `users.json` | Stores registered user credentials (email, mobile, password). Managed via the `/api/users` endpoint. |
| `manual_boxes.json` | Persisted manual bounding box annotations (legacy / backup format). |
| `project_<id>_proto.jpg` | The uploaded prototype image for a given project (e.g., `project_1_proto.jpg`). |
| `samples/` | Contains all uploaded sample images and their AI-annotated counterparts, organized by inference run. |
| `cropped_components/` | Output directory for `crop_boxes.py` — individual cropped images of each annotated component. |

---

## `frontend_app/` — Flutter Mobile Application

A Flutter project targeting **Android** (primary). Communicates with the backend over HTTP using the `dio` package.

### `frontend_app/lib/` — Dart Source Code

#### `lib/main.dart`
**App entry point**. Initialises the Flutter app, defines the `MaterialApp` with the root theme, and sets up the navigation routes mapping screen names to widget classes. The app starts at the `LoginScreen`.

---

#### `lib/screens/` — UI Screens

| File | Purpose |
|---|---|
| `login.dart` | **Login screen**. Provides email/mobile + password fields and an Admin / User role toggle. Calls `ApiService.login()` and navigates to either `AdminDashboard` or `ProjectHubScreen` on success. |
| `admin_dashboard.dart` | **Admin dashboard**. Lists all projects with their status labels (ongoing / completed / custom). Supports filtering by label via a scrollable chip row. Long-pressing a project card opens a modal to update its label. Allows navigating to any project's `PrototypeEditorScreen`. |
| `project_hub_screen.dart` | **User project hub**. Shows the user's available projects and lets them navigate to the `InferenceScreen` or `SampleDetailScreen` for a selected project. |
| `prototype_editor_screen.dart` | **Prototype annotation editor** (the largest screen). Displays the prototype PCB image on an aspect-ratio-locked canvas. Allows admins to draw, resize, move, and label bounding boxes over components. On save, uploads the image + all bounding boxes to the backend via `POST /projects/{id}/prototype`. |
| `inference_screen.dart` | **AI inference screen**. Lets the user pick or capture a new PCB image and submit it to `POST /projects/{id}/inference`. Shows a loading indicator during processing, then displays the annotated result image. Validates that a prototype exists before allowing inference; shows a modal prompt if it does not. |
| `sample_detail_screen.dart` | **Inference history detail view**. Displays a past inference result — shows the annotated image and a filterable list of detected component types. Tapping a component type highlights only those detections on the image using local coordinate rendering. |
| `create_user.dart` | **Admin-only user creation form**. Input fields for email, mobile number, and password. Calls `ApiService.createUser()` to register a new user account on the backend. |

---

#### `lib/models/` — Data Models

| File | Purpose |
|---|---|
| `project.dart` | **`Project` model**. Dart class with fields `id`, `name`, `createdAt`, `prototypePath`, and `label`. Includes `fromJson()` factory for deserializing API responses. |
| `sample.dart` | **`Sample` model**. Dart class representing a single inference run. Fields include `id`, `projectId`, `originalPath`, `annotatedPath`, `resultsData` (JSON string of detections), and `timestamp`. Includes `fromJson()`. |

---

#### `lib/services/` — API Communication

| File | Purpose |
|---|---|
| `api_service.dart` | **Central HTTP client**. Uses the `dio` package to communicate with the FastAPI backend. Exposes methods: `getProjects()`, `createProject()`, `updateProjectLabel()`, `runInference()` (with a 120-second timeout for AI processing), `getSamples()`, `login()`, and `createUser()`. The `baseUrl` constant points to the server's local network IP (`http://10.145.47.188:8000`) and must be updated to match the machine running the backend. |

---

### `frontend_app/` — Configuration & Build Files

| File | Purpose |
|---|---|
| `pubspec.yaml` | **Flutter project manifest**. Declares the app name, SDK constraints, and all Dart/Flutter package dependencies (e.g., `dio`, `image_picker`, `provider`). |
| `pubspec.lock` | Auto-generated lock file pinning exact dependency versions for reproducible builds. Do not edit manually. |
| `Dockerfile` | Builds the Flutter APK inside Docker. Installs the Flutter SDK and Android build tools, runs `flutter build apk --release`, and copies the output APK to `/output/`. |
| `analysis_options.yaml` | Dart static analysis configuration. Enables recommended lint rules for code quality. |
| `README.md` | Brief Flutter project readme (auto-generated by `flutter create`). |
| `.dockerignore` | Excludes `build/`, `.dart_tool/`, and other generated directories from the Docker build context. |

---

## Data Flow Summary

```
Admin (Flutter)
  │  draws bounding boxes on prototype image
  ▼
POST /projects/{id}/prototype
  │  stores image → storage/project_<id>_proto.jpg
  │  stores boxes → SQLite BoundingBox table
  ▼
Backend saves prototype + annotations

User (Flutter)
  │  captures / selects a new PCB sample image
  ▼
POST /projects/{id}/inference
  │  ml_pipeline.py loads prototype + boxes from DB
  │  runs YOLOE visual-prompt detection
  │  runs YOLOv10 classification
  │  saves annotated image → storage/samples/
  │  saves JSON results  → SQLite Sample table
  ▼
Flutter displays annotated result image + component list
  │
  ▼
SampleDetailScreen: filter by component type, highlight on image
```

---

## Running the Project

### Backend (local)
```bash
cd backend
python -m venv venv
venv\Scripts\activate       # Windows
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

### Backend (Docker / GPU)
```bash
docker compose up backend
```

### Flutter App
```bash
cd frontend_app
# Update baseUrl in lib/services/api_service.dart to your machine's IP
flutter run                 # USB-connected Android device
# or
flutter build apk --release
```
