from typing import Optional

from sqlalchemy.orm import Session

from app.models import Job


class JobRepository:
    def __init__(self, db: Session):
        self.db = db

    def create(self, job: Job) -> Job:
        """Create a new job."""
        self.db.add(job)
        self.db.commit()
        self.db.refresh(job)
        return job

    def get_by_id(self, job_id: str) -> Optional[Job]:
        """Get job by ID."""
        return (
            self.db.query(Job)
            .filter(Job.id == job_id)
            .first()
        )

    def update(self, job: Job) -> Job:
        """Update job."""
        self.db.add(job)
        self.db.commit()
        self.db.refresh(job)
        return job

