import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status
from fastapi.responses import FileResponse, JSONResponse
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.errors import AppError, NotFoundError
from app.core.storage import save_upload_file
from app.database import get_db
from app.models import (
    AssetResponse,
    CreateJobRequest,
    CreateJobResponse,
    Job,
    JobStatusResponse,
)
from app.repositories.asset_repo import AssetRepository
from app.repositories.job_repo import JobRepository
from app.services.job_service import JobService

router = APIRouter()


@router.post("/assets", response_model=AssetResponse, status_code=status.HTTP_201_CREATED)
async def upload_asset(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
):
    """Upload video asset."""
    # Validate file
    if not file.content_type or not file.content_type.startswith("video/"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error": "INVALID_INPUT", "message": "File must be a video"},
        )
    
    # Read file content
    try:
        content = await file.read()
        file_size = len(content)
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error": "INVALID_INPUT", "message": f"Failed to read file: {str(e)}"},
        )
    
    # Limit file size (500MB)
    max_size = 500 * 1024 * 1024
    if file_size > max_size:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error": "INVALID_INPUT", "message": f"File size exceeds {max_size} bytes"},
        )
    
    # Generate asset ID
    asset_id = str(uuid.uuid4())
    
    # Save file
    filename = f"{asset_id}_{file.filename or 'video'}"
    file_path = save_upload_file(content, filename)
    
    # Create asset record
    asset_repo = AssetRepository(db)
    asset = asset_repo.create(asset_id, str(file_path), file_size)
    
    return AssetResponse(assetId=asset.id)


@router.post("/jobs", response_model=CreateJobResponse, status_code=status.HTTP_201_CREATED)
async def create_job(
    request: CreateJobRequest,
    db: Session = Depends(get_db),
):
    """Create a new processing job."""
    # Validate asset exists
    asset_repo = AssetRepository(db)
    asset = asset_repo.get_by_id(request.assetId)
    if not asset:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error": "NOT_FOUND", "message": f"Asset '{request.assetId}' not found"},
        )
    
    # Create job
    job_id = str(uuid.uuid4())
    job = Job(id=job_id, asset_id=request.assetId, status="pending")
    job_repo = JobRepository(db)
    job = job_repo.create(job)
    
    # Start processing asynchronously
    job_service = JobService(job_repo, asset_repo)
    import asyncio
    asyncio.create_task(job_service.process_job(job_id, pipeline_type="dummy"))
    
    return CreateJobResponse(jobId=job.id)


@router.get("/jobs/{job_id}", response_model=JobStatusResponse)
async def get_job_status(
    job_id: str,
    db: Session = Depends(get_db),
):
    """Get job status."""
    job_repo = JobRepository(db)
    job = job_repo.get_by_id(job_id)
    
    if not job:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error": "NOT_FOUND", "message": f"Job '{job_id}' not found"},
        )
    
    return JobStatusResponse.from_orm_job(job)


@router.get("/jobs/{job_id}/artifact")
async def download_artifact(
    job_id: str,
    db: Session = Depends(get_db),
):
    """Download artifact file."""
    job_repo = JobRepository(db)
    job = job_repo.get_by_id(job_id)
    
    if not job:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error": "NOT_FOUND", "message": f"Job '{job_id}' not found"},
        )
    
    if not job.artifact_path:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error": "NOT_FOUND", "message": "Artifact not available"},
        )
    
    artifact_path = Path(job.artifact_path)
    if not artifact_path.exists():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error": "NOT_FOUND", "message": "Artifact file not found"},
        )
    
    # Return file with X-Artifact-Format header
    headers = {}
    if job.artifact_format:
        headers["X-Artifact-Format"] = job.artifact_format
    
    return FileResponse(
        path=artifact_path,
        filename=artifact_path.name,
        headers=headers,
    )

