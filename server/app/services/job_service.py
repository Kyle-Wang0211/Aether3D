import asyncio
from datetime import datetime, timezone
from pathlib import Path

from app.core.errors import NotFoundError, ProcessingFailedError
from app.core.storage import get_artifact_file_path
from app.pipelines.base import ProgressUpdate
from app.pipelines.factory import create_pipeline
from app.repositories.asset_repo import AssetRepository
from app.repositories.job_repo import JobRepository


class JobService:
    def __init__(self, job_repo: JobRepository, asset_repo: AssetRepository):
        self.job_repo = job_repo
        self.asset_repo = asset_repo
    
    async def process_job(self, job_id: str, pipeline_type: str = "dummy") -> None:
        """Process job asynchronously with real-time progress updates."""
        job = self.job_repo.get_by_id(job_id)
        if not job:
            raise NotFoundError("Job", job_id)
        
        asset = self.asset_repo.get_by_id(job.asset_id)
        if not asset:
            raise NotFoundError("Asset", job.asset_id)
        
        # Update status to processing
        job.state = "processing"
        job.status = "processing"  # Legacy field
        job.progress = "0.0"
        job.progress_percent = "0.0"
        job.progress_stage = None
        job.progress_message = None
        job.processing_started_at = datetime.now(timezone.utc)
        self.job_repo.update(job)
        
        # Throttle DB writes: minPercentDelta = 1.0%, minIntervalSeconds = 2.0s
        MIN_PERCENT_DELTA = 1.0
        MIN_INTERVAL_SECONDS = 2.0
        
        # Track last written values for throttling and monotonicity
        _last_written_pct = [None]  # mutable container for closure
        _last_written_stage = [None]
        _last_write_time = [None]
        
        def on_progress(update: ProgressUpdate) -> None:
            """Write progress to database (throttled, monotonic)."""
            # Reload job with lock to prevent races
            # Note: In a production system, use SELECT ... FOR UPDATE
            # For now, we rely on the fact that only one worker processes a job
            job = self.job_repo.get_by_id(job_id)
            if not job:
                return  # Job deleted, ignore
            
            should_write = False
            current_time = datetime.now(timezone.utc)
            
            # Always write on stage change
            if update.stage != _last_written_stage[0]:
                should_write = True
                _last_written_stage[0] = update.stage
            
            # Check percent delta threshold
            if update.percent is not None:
                if _last_written_pct[0] is None:
                    # First write: always write
                    should_write = True
                    _last_written_pct[0] = update.percent
                else:
                    # Enforce monotonicity: never decrease
                    if update.percent < _last_written_pct[0]:
                        # Percent regression: ignore
                        return
                    
                    delta = update.percent - _last_written_pct[0]
                    if delta >= MIN_PERCENT_DELTA:
                        should_write = True
                        _last_written_pct[0] = update.percent
            
            # Check time interval threshold
            if _last_write_time[0] is not None:
                time_delta = (current_time - _last_write_time[0]).total_seconds()
                if time_delta < MIN_INTERVAL_SECONDS and not should_write:
                    # Too soon and no stage change: skip
                    return
            
            if should_write:
                # Update job with progress (monotonicity already enforced)
                job.progress_stage = update.stage
                job.progress_message = update.message[:512]  # Enforce max length
                if update.percent is not None:
                    job.progress = str(round(update.percent, 1))
                    job.progress_percent = str(round(update.percent, 1))
                else:
                    # Keep last percent if new update doesn't have it
                    pass
                
                _last_write_time[0] = current_time
                self.job_repo.update(job)
        
        try:
            # Create pipeline
            pipeline = create_pipeline(pipeline_type)
            
            # Process with progress callback
            input_path = Path(asset.file_path)
            output_dir = Path(asset.file_path).parent.parent / "artifacts"
            artifact_path, artifact_format = await pipeline.process(
                input_path, output_dir, job_id, on_progress=on_progress
            )
            
            # Update job with artifact
            job = self.job_repo.get_by_id(job_id)
            if job:
                job.artifact_path = artifact_path
                job.artifact_format = artifact_format
                job.status = "completed"
                job.state = "completed"
                job.progress = "100.0"
                job.progress_percent = "100.0"
                job.progress_stage = "export"
                job.progress_message = "Complete"
                self.job_repo.update(job)
        
        except Exception as e:
            error_msg = str(e)
            if isinstance(e, ProcessingFailedError):
                error_msg = e.message
            
            # Always write failure state (no throttle)
            job = self.job_repo.get_by_id(job_id)
            if job:
                job.status = "failed"
                job.state = "failed"
                job.failure_reason = error_msg
                job.error_message = error_msg
                # Preserve last known progress
                if job.progress_stage:
                    job.progress_message = f"Failed: {error_msg}"
                self.job_repo.update(job)
            raise

