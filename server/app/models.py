from datetime import datetime, timedelta
from typing import Optional

from pydantic import BaseModel, Field
from sqlalchemy import Column, DateTime, Integer, String, Text, ForeignKey, Index
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func

from app.database import Base
from app.api.contract_constants import APIContractConstants


# ORM Models (snake_case for database)

class UploadSession(Base):
    """上传会话模型"""
    __tablename__ = "upload_sessions"
    
    id = Column(String, primary_key=True)
    user_id = Column(String, nullable=False, index=True)  # device_id (PATCH-1)
    capture_source = Column(String, nullable=False)  # 必须为"aether_camera"
    capture_session_id = Column(String, nullable=False, index=True)
    bundle_hash = Column(String, nullable=False, index=True)
    bundle_size = Column(Integer, nullable=False)
    chunk_count = Column(Integer, nullable=False)
    status = Column(String, nullable=False, default="in_progress")  # "in_progress" | "completed" | "expired"
    expires_at = Column(DateTime(timezone=True), nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    
    # 关系
    chunks = relationship("Chunk", back_populates="upload_session", cascade="all, delete-orphan")
    
    def __repr__(self):
        return f"<UploadSession(id={self.id}, status={self.status})>"


class Chunk(Base):
    """分片模型"""
    __tablename__ = "chunks"
    
    id = Column(String, primary_key=True)
    upload_id = Column(String, ForeignKey("upload_sessions.id"), nullable=False, index=True)
    chunk_index = Column(Integer, nullable=False)
    chunk_hash = Column(String, nullable=False)
    stored_at = Column(DateTime(timezone=True), server_default=func.now())
    
    # 关系
    upload_session = relationship("UploadSession", back_populates="chunks")
    
    # 唯一约束：同一upload_id的chunk_index唯一
    __table_args__ = (
        Index('uq_upload_chunk_index', 'upload_id', 'chunk_index', unique=True),
    )
    
    def __repr__(self):
        return f"<Chunk(upload_id={self.upload_id}, index={self.chunk_index})>"


class Job(Base):
    """任务模型（扩展）"""
    __tablename__ = "jobs"
    
    id = Column(String, primary_key=True)
    user_id = Column(String, nullable=False, index=True)  # device_id (PATCH-1)
    bundle_hash = Column(String, nullable=False, index=True)
    state = Column(String, nullable=False, default="queued")  # PR#2状态（PATCH-4：初始="queued"）
    failure_reason = Column(String, nullable=True)  # PR#2 FailureReason
    cancel_reason = Column(String, nullable=True)  # PR#2 CancelReason
    processing_started_at = Column(DateTime(timezone=True), nullable=True)
    artifact_id = Column(String, nullable=True, index=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())
    
    # 关系
    artifact = relationship("Artifact", back_populates="job", uselist=False)
    timeline_events = relationship("TimelineEvent", back_populates="job", cascade="all, delete-orphan")
    
    def __repr__(self):
        return f"<Job(id={self.id}, state={self.state})>"


class Artifact(Base):
    """产物模型"""
    __tablename__ = "artifacts"
    
    id = Column(String, primary_key=True)
    job_id = Column(String, ForeignKey("jobs.id"), nullable=False, index=True)
    format = Column(String, nullable=False)  # "splat"
    size = Column(Integer, nullable=False)
    hash = Column(String, nullable=False, index=True)
    file_path = Column(String, nullable=False)
    expires_at = Column(DateTime(timezone=True), nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    
    # 关系
    job = relationship("Job", back_populates="artifact")
    
    def __repr__(self):
        return f"<Artifact(id={self.id}, format={self.format})>"


class TimelineEvent(Base):
    """时间线事件模型"""
    __tablename__ = "timeline_events"
    
    id = Column(String, primary_key=True)
    job_id = Column(String, ForeignKey("jobs.id"), nullable=False, index=True)
    timestamp = Column(DateTime(timezone=True), nullable=False, index=True)
    from_state = Column(String, nullable=True)
    to_state = Column(String, nullable=False)
    trigger = Column(String, nullable=False)  # 闭集trigger值
    
    # 关系
    job = relationship("Job", back_populates="timeline_events")
    
    def __repr__(self):
        return f"<TimelineEvent(job_id={self.job_id}, trigger={self.trigger})>"


# 保留旧模型以兼容（待删除）
class Asset(Base):
    __tablename__ = "assets"
    
    id = Column(String, primary_key=True)
    file_path = Column(String, nullable=False)
    file_size = Column(Integer, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    
    def __repr__(self):
        return f"<Asset(id={self.id}, file_path={self.file_path})>"


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

