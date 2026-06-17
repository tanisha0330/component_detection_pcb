# app/schemas.py
from pydantic import BaseModel
from datetime import datetime
from typing import Optional

class ProjectCreate(BaseModel):
    name: str

class ProjectResponse(BaseModel):
    id: int
    name: str
    created_at: datetime
    prototype_path: Optional[str] = None

class BoxIn(BaseModel):
    label: str
    x1: float
    y1: float
    x2: float
    y2: float

    class Config:
        from_attributes = True

class UserCreate(BaseModel):
    email: str
    mobile: str
    password: str

class LoginRequest(BaseModel):
    email_or_mobile: str
    password: str
    role: str

class SampleResponse(BaseModel):
    id: int
    project_id: int
    original_path: str
    annotated_path: Optional[str] = None
    results_data: Optional[str] = None
    timestamp: datetime

    class Config:
        from_attributes = True