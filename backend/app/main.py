# app/main.py
from fastapi import FastAPI, Depends, UploadFile, File, Form, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session
import os
import json
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from . import models, schemas, database, ml_pipeline

models.Base.metadata.create_all(bind=database.engine)

app = FastAPI(title="Visual Prompting API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request, exc):
    try:
        body = await request.body()
        print("--- 422 ERROR DEBUG ---")
        print(f"RAW BODY: {body}")
        print(f"ERRORS: {exc.errors()}")
        print("-----------------------")
    except:
        pass
    return JSONResponse(status_code=422, content={"detail": exc.errors()})

os.makedirs("storage", exist_ok=True)
os.makedirs("storage/samples", exist_ok=True)

# Initialize JSON auth files
ADMINS_FILE = "storage/admins.json"
USERS_FILE = "storage/users.json"

if not os.path.exists(ADMINS_FILE):
    with open(ADMINS_FILE, "w") as f:
        json.dump([{"email": "admin@plant.com", "password": "admin"}], f)

if not os.path.exists(USERS_FILE):
    with open(USERS_FILE, "w") as f:
        json.dump([], f)
app.mount("/storage", StaticFiles(directory="storage"), name="storage")

# Include the ml_pipeline router rules cleanly
app.include_router(ml_pipeline.router)

@app.post("/projects/", response_model=schemas.ProjectResponse)
def create_project(project: schemas.ProjectCreate, db: Session = Depends(database.get_db)):
    db_project = models.Project(name=project.name)
    db.add(db_project)
    db.commit()
    db.refresh(db_project)
    return db_project

@app.get("/projects/", response_model=list[schemas.ProjectResponse])
def read_projects(skip: int = 0, limit: int = 100, db: Session = Depends(database.get_db)):
    projects = db.query(models.Project).offset(skip).limit(limit).all()
    return projects

@app.get("/projects/{project_id}/samples", response_model=list[schemas.SampleResponse])
def read_samples(project_id: int, db: Session = Depends(database.get_db)):
    samples = db.query(models.Sample).filter(models.Sample.project_id == project_id).order_by(models.Sample.timestamp.desc()).all()
    return samples

@app.post("/projects/{project_id}/prototype")
async def upload_prototype(
    project_id: int,
    file: UploadFile = File(...),
    boxes: str = Form(...), 
    db: Session = Depends(database.get_db)
):
    project = db.query(models.Project).filter(models.Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    file_extension = os.path.splitext(file.filename)[1]
    filename = f"project_{project_id}_proto{file_extension}"
    file_path = os.path.join("storage", filename)
    
    with open(file_path, "wb") as buffer:
        buffer.write(await file.read())

    project.prototype_path = file_path
    db.query(models.BoundingBox).filter(models.BoundingBox.project_id == project_id).delete()

    try:
        parsed_boxes = json.loads(boxes)
        for box_data in parsed_boxes:
            db_box = models.BoundingBox(
                project_id=project_id,
                label=box_data.get("label", "target_component"),
                x1=float(box_data["x1"]),
                y1=float(box_data["y1"]),
                x2=float(box_data["x2"]),
                y2=float(box_data["y2"])
            )
            db.add(db_box)
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=400, detail=f"Invalid boxes JSON data format: {e}")

    db.commit()
    return {"status": "success", "prototype_path": file_path, "boxes_saved": len(parsed_boxes)}

@app.get("/health")
def health_check():
    return {"status": "healthy"}

@app.post("/api/login")
def login(req: schemas.LoginRequest):
    if req.role.lower() == "admin":
        with open(ADMINS_FILE, "r") as f:
            admins = json.load(f)
        for admin in admins:
            if admin["email"] == req.email_or_mobile and admin["password"] == req.password:
                return {"status": "success", "role": "admin"}
        raise HTTPException(status_code=401, detail="Invalid admin credentials")
    
    elif req.role.lower() == "user":
        with open(USERS_FILE, "r") as f:
            users = json.load(f)
        for user in users:
            if (user["email"] == req.email_or_mobile or user["mobile"] == req.email_or_mobile) and user["password"] == req.password:
                return {"status": "success", "role": "user"}
        raise HTTPException(status_code=401, detail="Invalid user credentials")
    
    raise HTTPException(status_code=400, detail="Invalid role specified")

@app.post("/api/users")
def create_user(user: schemas.UserCreate):
    with open(USERS_FILE, "r") as f:
        users = json.load(f)
    
    # Check if user already exists
    if any(u["email"] == user.email for u in users):
        raise HTTPException(status_code=400, detail="User with this email already exists")
    
    users.append({
        "email": user.email,
        "mobile": user.mobile,
        "password": user.password
    })
    
    with open(USERS_FILE, "w") as f:
        json.dump(users, f, indent=4)
        
    return {"status": "success", "message": "User created successfully"}