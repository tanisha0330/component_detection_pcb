# app/models.py
from sqlalchemy import Column, Integer, String, Float, ForeignKey, DateTime
from sqlalchemy.orm import relationship
from datetime import datetime
from .database import Base

class Project(Base):
    __tablename__ = "projects"
    
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, index=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    prototype_path = Column(String, nullable=True)

    boxes = relationship("BoundingBox", back_populates="project")
    samples = relationship("Sample", back_populates="project")

class BoundingBox(Base):
    __tablename__ = "bounding_boxes"
    
    id = Column(Integer, primary_key=True, index=True)
    project_id = Column(Integer, ForeignKey("projects.id"))
    label = Column(String)
    x1 = Column(Float)
    y1 = Column(Float)
    x2 = Column(Float)
    y2 = Column(Float)

    project = relationship("Project", back_populates="boxes")

class Sample(Base):
    __tablename__ = "samples"
    
    id = Column(Integer, primary_key=True, index=True)
    project_id = Column(Integer, ForeignKey("projects.id"))
    original_path = Column(String)
    annotated_path = Column(String, nullable=True)
    status = Column(String, default="pending") # pending, completed, failed
    timestamp = Column(DateTime, default=datetime.utcnow)

    project = relationship("Project", back_populates="samples")