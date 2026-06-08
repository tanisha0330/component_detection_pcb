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