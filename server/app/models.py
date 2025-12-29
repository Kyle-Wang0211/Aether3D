from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field
from sqlalchemy import Column, DateTime, Integer, String, Text
from sqlalchemy.sql import func

from app.database import Base


# ORM Models (snake_case for database)
class Asset(Base):
    __tablename__ = "assets"
    
    id = Column(String, primary_key=True)
    file_path = Column(String, nullable=False)
    file_size = Column(Integer, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    
    def __repr__(self):
        return f"<Asset(id={self.id}, file_path={self.file_path})>"


class Job(Base):
    __tablename__ = "jobs"
    
    id = Column(String, primary_key=True)
    asset_id = Column(String, nullable=False, index=True)
    status = Column(String, nullable=False, default="pending")
    progress = Column(String, nullable=True)
    artifact_path = Column(String, nullable=True)
    artifact_format = Column(String, nullable=True)
    error_message = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())
    
    def __repr__(self):
        return f"<Job(id={self.id}, status={self.status})>"


# Pydantic Models for API (camelCase)
class AssetResponse(BaseModel):
    assetId: str
    
    class Config:
        populate_by_name = True


class CreateJobRequest(BaseModel):
    assetId: str = Field(..., alias="assetId")
    
    class Config:
        populate_by_name = True


class CreateJobResponse(BaseModel):
    jobId: str
    
    class Config:
        populate_by_name = True


class JobStatusResponse(BaseModel):
    jobId: str
    status: str
    progress: Optional[float] = None
    artifactPath: Optional[str] = None
    artifactFormat: Optional[str] = None
    errorMessage: Optional[str] = None
    
    class Config:
        populate_by_name = True
    
    @classmethod
    def from_orm_job(cls, job: Job) -> "JobStatusResponse":
        """Convert ORM Job to camelCase response."""
        progress_float = None
        if job.progress:
            try:
                progress_float = float(job.progress)
            except (ValueError, TypeError):
                pass
        
        return cls(
            jobId=job.id,
            status=job.status,
            progress=progress_float,
            artifactPath=job.artifact_path,
            artifactFormat=job.artifact_format,
            errorMessage=job.error_message,
        )

