import os
import sys

# Ensure we're in the right directory or add backend to path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), 'app')))

try:
    from app.database import SessionLocal
    from app.models import Project, BoundingBox
except ImportError:
    print("Could not import app.database or app.models. Ensure you run this from the backend directory.")
    sys.exit(1)

def check_db():
    db = SessionLocal()
    try:
        projects = db.query(Project).all()
        print(f"--- Found {len(projects)} Projects ---")
        for p in projects:
            print(f"Project ID: {p.id}, Name: {p.name}")
            
        boxes = db.query(BoundingBox).all()
        print(f"\n--- Found {len(boxes)} Bounding Boxes ---")
        for b in boxes:
            print(f"Box ID: {b.id}, Project ID: {b.project_id}, Label: {b.label}, Coords: ({b.x1}, {b.y1}, {b.x2}, {b.y2})")
            
    finally:
        db.close()

if __name__ == "__main__":
    check_db()
