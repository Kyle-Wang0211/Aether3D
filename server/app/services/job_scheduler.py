import asyncio
import logging
from typing import Optional

from app.core.config import settings
from app.database import SessionLocal
from app.repositories.asset_repo import AssetRepository
from app.repositories.job_repo import JobRepository
from app.services.job_service import JobService

logger = logging.getLogger(__name__)


async def _run_job(job_id: str, pipeline_type: str) -> None:
    """Run a job with a dedicated DB session."""
    db = SessionLocal()
    try:
        service = JobService(
            job_repo=JobRepository(db),
            asset_repo=AssetRepository(db),
        )
        await service.process_job(job_id=job_id, pipeline_type=pipeline_type)
    except Exception:
        logger.exception("Background job processing failed (job_id=%s)", job_id)
    finally:
        db.close()


def schedule_job_processing(job_id: str, pipeline_type: Optional[str] = None) -> None:
    """Schedule asynchronous job processing without blocking API response."""
    selected_pipeline = pipeline_type or settings.default_pipeline_type
    asyncio.create_task(_run_job(job_id=job_id, pipeline_type=selected_pipeline))
