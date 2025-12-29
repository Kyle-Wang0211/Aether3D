import asyncio
from pathlib import Path

from app.core.errors import NotFoundError, ProcessingFailedError
from app.core.storage import get_artifact_file_path
from app.pipelines.factory import create_pipeline
from app.repositories.asset_repo import AssetRepository
from app.repositories.job_repo import JobRepository


class JobService:
    def __init__(self, job_repo: JobRepository, asset_repo: AssetRepository):
        self.job_repo = job_repo
        self.asset_repo = asset_repo
    
    async def process_job(self, job_id: str, pipeline_type: str = "dummy") -> None:
        """Process job asynchronously."""
        job = self.job_repo.get_by_id(job_id)
        if not job:
            raise NotFoundError("Job", job_id)
        
        asset = self.asset_repo.get_by_id(job.asset_id)
        if not asset:
            raise NotFoundError("Asset", job.asset_id)
        
        # Update status to processing
        job.status = "processing"
        job.progress = "0.0"
        self.job_repo.update(job)
        
        try:
            # Create pipeline
            pipeline = create_pipeline(pipeline_type)
            
            # Process
            input_path = Path(asset.file_path)
            output_dir = Path(asset.file_path).parent.parent / "artifacts"
            artifact_path, artifact_format = await pipeline.process(
                input_path, output_dir, job_id
            )
            
            # Update job with artifact
            job.artifact_path = artifact_path
            job.artifact_format = artifact_format
            job.status = "completed"
            self.job_repo.update(job)
        
        except Exception as e:
            error_msg = str(e)
            if isinstance(e, ProcessingFailedError):
                error_msg = e.message
            job.status = "failed"
            job.error_message = error_msg
            self.job_repo.update(job)
            raise

