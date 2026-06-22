# PCB Component Detection App — Presentation

---

## SLIDE 1 — Title Slide

# PCB Component Detection System
### AI-Powered Printed Circuit Board Analysis
**Using Visual Prompting + Hybrid Deep Learning**

> Developed as a full-stack mobile + backend system  
> Flutter (Android) · FastAPI · YOLOE · YOLOv10 · Docker

---

## SLIDE 2 — Problem Statement

# The Problem

- PCB (Printed Circuit Board) manufacturing and quality inspection is **manual and time-consuming**
- Human inspectors must verify **presence, placement, and type** of dozens of components on each board
- Errors like **missing components, wrong placement, or wrong parts** lead to costly failures
- Traditional machine vision tools require **expensive setup per board variant**
- No flexible, mobile-friendly solution exists for **on-floor inspection**

### What We Solve
> A technician or QA engineer should be able to **photograph a PCB with their phone**, and instantly know what components are present — without expensive dedicated hardware.

---

## SLIDE 3 — Solution Overview

# Our Solution

A **mobile-first AI inspection system** that works in 3 steps:

```
STEP 1 — SETUP (Admin)
  Upload a reference prototype PCB image
  Draw bounding boxes around each component type
  Label them (resistor, capacitor, IC, LED...)

STEP 2 — INSPECT (User/Technician)
  Photograph a new PCB board with their phone
  App sends image to backend AI engine

STEP 3 — RESULTS
  AI detects all components on the new board
  Annotated image returned to the phone
  Component list shown with confidence scores
```

**No retraining required for new board types** — visual prompting adapts automatically.

---

## SLIDE 4 — Application Architecture

# System Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Flutter Android App                  │
│   Login │ Dashboard │ Prototype Editor │ Inference   │
└──────────────────┬──────────────────────────────────┘
                   │  HTTP REST API (port 8000)
                   │  multipart/form-data uploads
                   ▼
┌─────────────────────────────────────────────────────┐
│              FastAPI Backend (Python)                │
│   REST API │ Auth │ File Storage │ DB Management     │
├─────────────────────────────────────────────────────┤
│                  AI / ML Pipeline                    │
│   YOLOE Alignment → YOLOE VP → YOLOv10 → Merge      │
├─────────────────────────────────────────────────────┤
│         SQLite Database (SQLAlchemy ORM)             │
│   Projects │ BoundingBoxes │ Samples                 │
└─────────────────────────────────────────────────────┘
                   │
                   ▼
         Docker Container (NVIDIA GPU)
         CUDA 11.8 · Ubuntu · Uvicorn
```

---

## SLIDE 5 — Tech Stack

# Technology Stack

### Frontend
| Technology | Version | Purpose |
|---|---|---|
| Flutter | 3.x | Cross-platform mobile framework |
| Dart | 3.x | Programming language |
| Dio | Latest | HTTP client for API calls |
| Image Picker | Latest | Camera & gallery image selection |
| SharedPreferences | Latest | Local session storage |

### Backend
| Technology | Version | Purpose |
|---|---|---|
| Python | 3.10+ | Programming language |
| FastAPI | 0.136.3 | REST API framework |
| Uvicorn | 0.49.0 | ASGI server |
| SQLAlchemy | 2.0.50 | ORM / database layer |
| SQLite | Built-in | Lightweight database |
| Pydantic | 2.13.4 | Data validation & schemas |

### AI / ML
| Technology | Version | Purpose |
|---|---|---|
| PyTorch | 2.7.1+cu118 | Deep learning framework |
| Ultralytics YOLOE | Custom fork | Visual prompt detection |
| YOLOv10n | Fine-tuned | PCB-specific 10-class detector |
| OpenCV | 4.13 | Image processing |
| Supervision | 0.28.0 | Detection post-processing |
| Pillow | 12.2.0 | Image I/O |
| NumPy | 2.4.6 | Numerical operations |

### Infrastructure
| Technology | Purpose |
|---|---|
| Docker | Containerisation |
| NVIDIA CUDA 11.8 | GPU acceleration |
| docker-compose | Service orchestration |

---

## SLIDE 6 — User Roles & Authentication

# User Roles & Authentication

### Two Roles in the System

```
┌─────────────┐          ┌─────────────┐
│    ADMIN    │          │    USER     │
│             │          │             │
│ • Create    │          │ • View      │
│   projects  │          │   projects  │
│ • Upload    │          │ • Run AI    │
│   prototype │          │   inference │
│ • Draw      │          │ • View      │
│   bounding  │          │   results   │
│   boxes     │          │ • Browse    │
│ • Manage    │          │   history   │
│   users     │          │             │
│ • Set status│          │             │
└─────────────┘          └─────────────┘
```

### Authentication Features
- Email **or** mobile number login
- Role-based access control (Admin / User)
- Session persistence via `SharedPreferences`
- Admin can create new user accounts
- Default admin: `admin@plant.com`
- Credentials stored in JSON files (`admins.json`, `users.json`)

---

## SLIDE 7 — Project Management

# Project Management Dashboard

### Features
- **Create projects** with a custom name (e.g., "Arduino Uno Board", "ESP32 PCB")
- **View all projects** in a scrollable card list
- **Status labelling** — each project is tagged as:
  - 🟢 `ongoing` — work in progress
  - ✅ `completed` — fully annotated and tested
  - 🏷️ Custom label — any user-defined text
- **Filter projects** by status using a horizontal scrollable chip row
- **Long press** a project card to update its status label
- Navigate into a project to access:
  - Prototype Editor (admin)
  - AI Inference (user)
  - Inference History

### Database Schema — Project
```
Project
├── id            (primary key)
├── name          (project name)
├── created_at    (timestamp)
├── prototype_path (path to uploaded reference image)
└── label         (ongoing / completed / custom)
```

---

## SLIDE 8 — Prototype Editor (Admin Feature)

# Prototype Annotation Editor

### What It Does
The admin uploads a **reference PCB image** and manually draws bounding boxes over each component type. This becomes the "visual prompt" for the AI.

### Key Capabilities

| Feature | Description |
|---|---|
| **Image Upload** | Pick from gallery (JPEG/PNG) |
| **Aspect-ratio locked canvas** | Image always fits screen correctly |
| **Pinch-to-zoom** | InteractiveViewer for precision annotation |
| **Draw bounding boxes** | Finger-drag to create a box |
| **Resize handles** | 4-corner drag handles to adjust any box |
| **Label selection** | Choose from 18 component types |
| **Box counter** | Live count of annotations |
| **Undo** | Remove last-drawn box |
| **Delete** | Remove selected box |
| **Navigate mode** | Switch between draw and pan modes |
| **Debug panel** | Real-time log of coordinates, API calls |
| **Sync to server** | Uploads image + all boxes via multipart POST |

### Supported Component Labels
```
capacitor · resistor · LED · IC · transistor · switch
headers · microcontroller · icsp · ATmega328 microcontroller
crystal oscillator · voltage regulator · r105 · comp1
comp2 · comp3 · usb · dc
```

### Coordinate System
- Boxes stored as **normalized [0,1]** coordinates in the app
- Denormalized back to **pixel coordinates** before sending to backend
- Backend stores absolute pixel coordinates in SQLite

---

## SLIDE 9 — AI Inference Screen (User Feature)

# AI Inference Screen

### User Workflow
```
1. Open project → "Run AI Inference Test"
2. App checks: has prototype been uploaded?
   └─ NO  → Modal: "Please upload a prototype first"
   └─ YES → Continue
3. User captures photo via camera
4. Image sent to backend → 120 second timeout (AI processing)
5. Annotated result displayed on screen
6. Detection list shown below image
```

### Safety Checks
- **Prototype guard** — cannot run inference without a reference image
- **No-prototype modal** — friendly dialog with direct link to Prototype Editor
- **Error handling** — network failures shown as SnackBar alerts
- **Loading state** — spinner with "AI is analyzing..." message during processing

### Results Display
- Full annotated image with coloured bounding boxes
- Component labels with confidence scores
- Tap any component type to **filter and highlight** only those detections
- Each detection rendered with local coordinate mapping (instant, no re-fetch)

---

## SLIDE 10 — Inference History

# Inference History & Sample Detail

### Inference History Screen
- Lists all past AI runs for a project in **reverse chronological order**
- Each history card shows:
  - Run number (`Run #1`, `Run #2`...)
  - Number of detections found
  - Date and time of the run
- Tap any entry to open the detail view

### Sample Detail Screen
- Shows the **annotated image** from that inference run
- Lists all detected components with:
  - Component type / label
  - Confidence score
- **Interactive filtering** — tap a component chip to highlight only those boxes on the image
- Coordinate rendering is **fully local** — no API call needed for filtering
- Supports multi-component filtering

### Database Schema — Sample
```
Sample
├── id               (primary key)
├── project_id       (foreign key → Project)
├── original_path    (unannotated aligned image path)
├── annotated_path   (AI-annotated result image path)
├── results_data     (JSON string of all detections)
├── status           (pending / completed / failed)
└── timestamp        (inference datetime)
```

---

## SLIDE 11 — AI Pipeline (Deep Dive)

# The 5-Phase AI Detection Pipeline

```
INPUT: New PCB photo + Prototype image + Bounding boxes from DB
                         │
            ─────────────▼─────────────
            PHASE 1: BOARD ALIGNMENT
            ─────────────────────────
            YOLOE detects PCB board outline
            Extracts contour → minAreaRect
            Applies perspective warp transform
            Output: aligned, top-down PCB image
                         │
            ─────────────▼─────────────
            PHASE 2: YOLOE VISUAL PROMPTING
            ─────────────────────────────
            (All components EXCEPT capacitor)
            Uses prototype boxes as visual prompts
            Encodes Visual Prompt Embeddings (VPE)
            from the prototype image
            Runs inference on aligned target image
            Applies per-class confidence thresholds
                         │
            ─────────────▼─────────────
            PHASE 3: YOLOv10n (Capacitors)
            ─────────────────────────────
            Fine-tuned PCB 10-class detector
            Handles capacitor detection separately
            Confidence threshold: 0.20
            Filtered to capacitor class only
                         │
            ─────────────▼─────────────
            PHASE 4: MERGE DETECTIONS
            ─────────────────────────
            Combine YOLOE + YOLOv10 results
            Build unified detection list
            Assign labels and confidence scores
                         │
            ─────────────▼─────────────
            PHASE 5: ANNOTATE + SAVE
            ─────────────────────────
            Draw boxes + labels on aligned image
            Save annotated image → storage/samples/
            Save raw unannotated image → storage/samples/
            Persist detection JSON → SQLite Sample table
                         │
OUTPUT: Annotated image URL + Detection JSON returned to Flutter
```

---

## SLIDE 12 — YOLOE Visual Prompting (Technical Detail)

# YOLOE Visual Prompting — How It Works

### What is Visual Prompting?
Instead of retraining a model for each new board, YOLOE uses **bounding box prompts drawn on a reference image** to learn what to look for.

### Step-by-Step VPE Encoding
```python
# Step 0: Resize model to match number of prompt classes
vp_model.set_classes(unique_labels, vp_model.get_text_pe(unique_labels))

# Step 1: Encode Visual Prompt Embeddings from PROTOTYPE
vp_model.predict(
    source_image,          # prototype PCB image
    prompts=prompts,       # bounding boxes + class IDs
    predictor=YOLOEVPSegPredictor,
    return_vpe=True,
)

# Step 2: Save learned embeddings as named classes
vp_model.set_classes(unique_labels, vp_model.predictor.vpe)

# Step 3: Switch to standard inference mode
vp_model.predictor = None

# Step 4: Detect on NEW target image using learned embeddings
results = vp_model.predict(aligned_target_image, conf=0.05, iou=0.4)
```

### Per-Class Confidence Thresholds
Each component class has a tuned minimum confidence:
```
LED:                  0.116    Headers:        0.110
Resistor:             0.114    Microcontroller: 0.120
IC:                   0.160    Crystal Osc.:   0.165
Transistor:           0.140    Voltage Reg.:   0.160
Switch:               0.120    USB:            0.170
```

### Why Separate Capacitor Detection?
Capacitors have **very similar visual appearance** across boards but vary in size. YOLOE VP struggles with this. A purpose-trained **YOLOv10n** model fine-tuned on PCB data handles capacitors with better precision.

---

## SLIDE 13 — Data Flow (End to End)

# Complete Data Flow

### Admin Setup Flow
```
Admin opens Prototype Editor
  → Picks image from gallery
  → Draws bounding boxes + labels
  → Taps "Sync to server"
  → POST /projects/{id}/prototype
      multipart body:
        file: image binary
        boxes: JSON string of [{label, x1, y1, x2, y2}, ...]
  → Backend saves image → storage/project_{id}_proto.jpg
  → Backend saves boxes → SQLite BoundingBox table
  → Success SnackBar shown
```

### User Inference Flow
```
User taps "Run AI Inference"
  → Camera opens, photo captured
  → POST /projects/{id}/inference
      multipart body: file: image binary
  → Backend:
      1. Loads prototype image + boxes from DB
      2. Runs 5-phase AI pipeline
      3. Saves annotated image to storage/samples/
      4. Saves Sample record to DB (JSON results)
  → Returns: {sample: {id, paths, results_data, timestamp}}
  → Flutter displays annotated image
  → User can filter detections by component type
```

---

## SLIDE 14 — Database Design

# Database Schema

```
┌──────────────────┐       ┌──────────────────────┐
│    projects      │       │    bounding_boxes     │
├──────────────────┤       ├──────────────────────┤
│ id (PK)          │◄──┐   │ id (PK)               │
│ name             │   │   │ project_id (FK)  ──►──┘
│ created_at       │   │   │ label                 │
│ prototype_path   │   │   │ x1 (float)            │
│ label            │   │   │ y1 (float)            │
└──────────────────┘   │   │ x2 (float)            │
                       │   │ y2 (float)            │
┌──────────────────┐   │   └──────────────────────┘
│    samples       │   │
├──────────────────┤   │
│ id (PK)          │   │
│ project_id (FK) ─┘   │
│ original_path    │   │
│ annotated_path   │   │
│ results_data     │   │
│ status           │   │
│ timestamp        │   │
└──────────────────┘   │
```

### REST API Endpoints
| Method | Endpoint | Purpose |
|---|---|---|
| `POST` | `/projects/` | Create new project |
| `GET` | `/projects/` | List all projects |
| `PUT` | `/projects/{id}/label` | Update project status |
| `POST` | `/projects/{id}/prototype` | Upload prototype image + boxes |
| `GET` | `/projects/{id}/boxes` | Fetch stored bounding boxes |
| `PUT` | `/projects/{id}/boxes` | Update boxes (image already uploaded) |
| `POST` | `/projects/{id}/inference` | Run AI detection |
| `GET` | `/projects/{id}/samples` | Get inference history |
| `POST` | `/api/login` | Authenticate user |
| `POST` | `/api/users` | Create new user (admin only) |
| `GET` | `/health` | Health check |

---

## SLIDE 15 — Deployment & Infrastructure

# Deployment Architecture

### Docker Setup
```yaml
# docker-compose.yml
services:
  backend:
    build: ./backend
    runtime: nvidia          # GPU passthrough
    ports: ["8000:8000"]
    volumes:
      - ./backend/storage:/app/storage
      - ./backend/visual_prompt.db:/app/visual_prompt.db
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
```

### Dockerfile (Backend)
```
Base Image:  nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04
Runtime:     Python 3.10
Server:      Uvicorn (ASGI) on port 8000
Models:      yoloe-v8l-seg.pt (107 MB)
             yolov10n_pcb_10classes_best.pt (5 MB)
```

### Current Setup (Local/On-Prem)
```
Developer machine with NVIDIA GPU
└── Docker + CUDA 11.8
    └── FastAPI backend
        └── Flutter Android app (USB / WiFi)
```

### Production (Azure — Recommended)
```
Azure VM: Standard_NC4as_T4_v3
├── GPU: NVIDIA Tesla T4 (16 GB VRAM)
├── vCPU: 4 cores
├── RAM: 28 GB
├── OS: Ubuntu 22.04 LTS
├── CUDA: 11.8 compatible
└── Cost: ~$0.52/hour
    └── docker-compose up  ← zero code changes
```

---

## SLIDE 16 — Key Features Summary

# Feature Summary

| Feature | Admin | User |
|---|---|---|
| Login (email/mobile + password) | ✅ | ✅ |
| View all projects | ✅ | ✅ |
| Filter projects by status | ✅ | ✅ |
| Create new project | ✅ | ❌ |
| Upload prototype image | ✅ | ❌ |
| Draw & label bounding boxes | ✅ | ❌ |
| Pinch-to-zoom annotation canvas | ✅ | ❌ |
| Resize / delete boxes | ✅ | ❌ |
| Set project status (ongoing/completed) | ✅ | ❌ |
| Create new user accounts | ✅ | ❌ |
| Run AI inference on new PCB image | ✅ | ✅ |
| View annotated results | ✅ | ✅ |
| Browse inference history | ✅ | ✅ |
| Filter detections by component type | ✅ | ✅ |
| Interactive highlight on image | ✅ | ✅ |

---

## SLIDE 17 — Performance & Design Decisions

# Design Decisions & Performance

### Why YOLOE Visual Prompting?
- **No retraining** needed when introducing a new PCB design
- Admin simply draws boxes on a reference image → AI learns immediately
- Generalises across board variants with same component types

### Why Hybrid Pipeline (YOLOE + YOLOv10)?
- YOLOE VP is strong for **unique, visually distinct** components (ICs, headers, switches)
- Capacitors are **visually similar across boards** → purpose-trained YOLOv10 handles them better
- Combining both gives **higher overall accuracy**

### Why Perspective Alignment First?
- Mobile phone photos are taken at **angles**
- Warping to a top-down view ensures bounding box coordinates from the prototype match the target
- Improves detection accuracy significantly

### Coordinate Normalisation
- Frontend stores boxes as **normalized [0,1]** ratios
- Backend stores as **absolute pixel values**
- Conversion happens at upload (denormalize) and fetch (re-normalize)
- Ensures boxes always render correctly regardless of display resolution

### 120-Second Inference Timeout
- YOLOE large-seg model is computationally heavy
- VPE encoding + inference can take 30–90 seconds on a GPU
- Extended timeout prevents false "network error" failures

---

## SLIDE 18 — Next Phase: Missing Component Detection

# 🔮 Next Phase — Missing Component Detection

### The Problem to Solve
Currently the system detects **what components are present**.
The next phase will answer: **"What components are MISSING?"**

### Planned Feature: Missing Component Detection

```
REFERENCE (Prototype)              NEW PCB PHOTO
─────────────────────              ─────────────
Annotated boxes:                   AI Detections:
  ✅ 4x Capacitor                    ✅ 3x Capacitor   ← MISSING 1
  ✅ 2x Resistor                     ✅ 2x Resistor
  ✅ 1x IC                           ❌ IC not found   ← MISSING
  ✅ 1x LED                          ✅ 1x LED
  ✅ 1x USB                          ✅ 1x USB
                                   
                                   ALERT: 2 components missing!
```

### Implementation Plan

**Step 1 — Component Counting**
- Count expected components per type from prototype bounding boxes
- Count detected components per type from inference results
- Compute diff: `missing = expected_count - detected_count`

**Step 2 — Spatial Matching (Advanced)**
- Map prototype bounding box locations to target image coordinates
- Use homography (from alignment phase) to transform prototype boxes to target space
- Check if each expected component region has a corresponding detection

**Step 3 — Alert System**
- UI overlay: highlight **missing regions** in red on the annotated image
- Summary report: "Component X expected at position Y — NOT FOUND"
- Push notification / alert for QA engineers

**Step 4 — Count-Based Report Card**
```
Expected:  Capacitor ×4 | Resistor ×2 | IC ×1 | LED ×3
Detected:  Capacitor ×3 | Resistor ×2 | IC ×0 | LED ×3
Missing:   Capacitor ×1 | IC ×1
Status:    ❌ FAIL — 2 components missing
```

### New Backend Endpoint (Planned)
```
GET /projects/{id}/missing-report?sample_id={sample_id}
→ Returns: { expected, detected, missing, pass_fail_status }
```

### New Flutter Screen (Planned)
- `missing_report_screen.dart`
- Side-by-side: prototype boxes vs detected boxes
- Red overlay for unmatched expected positions
- Green checkmark for all matched components
- Final PASS / FAIL badge

---

## SLIDE 19 — Project Roadmap

# Project Roadmap

```
Phase 1 ✅ COMPLETE
─────────────────────────────────────────
✅ User authentication (Admin / User)
✅ Project management with status labels
✅ Prototype image upload & annotation
✅ Bounding box draw / resize / label
✅ 5-phase AI detection pipeline
✅ YOLOE visual prompting
✅ YOLOv10 capacitor detection
✅ Board alignment via perspective warp
✅ Inference history & detail view
✅ Interactive component filtering
✅ Docker + GPU deployment

Phase 2 🔄 IN PROGRESS / PLANNED
─────────────────────────────────────────
🔲 Missing component detection
🔲 Component count validation
🔲 Spatial mismatch detection (homography)
🔲 PASS/FAIL report card per inspection
🔲 Alert system for missing parts
🔲 Azure cloud deployment

Phase 3 🔮 FUTURE
─────────────────────────────────────────
🔲 Wrong component detection (e.g., wrong resistor value)
🔲 Solder joint quality analysis
🔲 Multi-board batch processing
🔲 Export inspection reports (PDF)
🔲 Integration with manufacturing MES systems
```

---

## SLIDE 20 — Thank You

# Thank You

## PCB Component Detection System

> **A zero-retraining, mobile-first AI inspection system  
> for Printed Circuit Board quality assurance**

---

### Built With
`Flutter` · `FastAPI` · `YOLOE` · `YOLOv10` · `PyTorch` · `Docker` · `SQLite`

### Core Innovation
- **Visual Prompting** — No retraining for new board designs
- **Hybrid AI Pipeline** — Best model for each component class
- **Mobile-first** — Works on any Android device, on the factory floor

### Next Up
🔮 **Missing Component Detection** — Automatically detect what's absent from a PCB board vs. the reference prototype

---
*Presentation generated from source code analysis of `component_detection_app`*
