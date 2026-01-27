# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""任务处理器（5个端点）"""

import uuid
from datetime import datetime
from typing import List, Optional

from fastapi import Depends, Query, Request, status
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from app.api.contract import (
    APIError, APIErrorCode, APIResponse, CancelJobRequest,
    CancelJobResponse, CreateJobRequest, CreateJobResponse,
    GetJobResponse, GetTimelineResponse, JobListItem, JobProgress,
    ListJobsResponse, TimelineEvent, format_rfc3339_utc
)
from app.api.contract_constants import APIContractConstants
from app.database import get_db
from app.models import Job, TimelineEvent


async def create_job(
    request_body: CreateJobRequest,
    request: Request,
    db: Session = Depends(get_db)
) -> JSONResponse:
    """
    POST /v1/jobs - 创建任务（特殊场景）
    
    PATCH-4: 初始状态="queued"
    """
    user_id = request.state.user_id
    
    # 白盒阶段：parent_job_id必须为null
    if request_body.parent_job_id is not None:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Rerun not supported in whitebox"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # 并发限制
    active_states = ["pending", "uploading", "queued", "processing", "packaging"]
    active_count = db.query(Job).filter(
        Job.user_id == user_id,
        Job.state.in_(active_states)
    ).count()
    
    if active_count >= APIContractConstants.MAX_ACTIVE_JOBS_PER_USER:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.STATE_CONFLICT,
                message="Please wait for current job to complete"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_409_CONFLICT,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # PATCH-4: 创建Job，初始状态="queued"
    job_id = str(uuid.uuid4())
    job = Job(
        id=job_id,
        user_id=user_id,
        bundle_hash=request_body.bundle_hash,
        state="queued"  # PATCH-4
    )
    db.add(job)
    
    # 创建时间线事件
    timeline_event = TimelineEvent(
        id=str(uuid.uuid4()),
        job_id=job_id,
        timestamp=datetime.utcnow(),
        from_state=None,
        to_state="queued",
        trigger="job_created"
    )
    db.add(timeline_event)
    
    db.commit()
    
    response_data = CreateJobResponse(
        job_id=job_id,
        state="queued",
        created_at=format_rfc3339_utc(job.created_at)
    )
    
    api_response = APIResponse(success=True, data=response_data.model_dump())
    
    return JSONResponse(
        status_code=status.HTTP_201_CREATED,
        content=api_response.model_dump(exclude_none=True)
    )


async def get_job(
    job_id: str,
    request: Request,
    db: Session = Depends(get_db)
) -> JSONResponse:
    """
    GET /v1/jobs/{id} - 查询任务状态
    """
    user_id = request.state.user_id
    
    job = db.query(Job).filter(
        Job.id == job_id,
        Job.user_id == user_id
    ).first()
    
    if not job:
        from app.core.ownership import create_ownership_error_response
        return create_ownership_error_response("Job")
    
    # 构建progress（根据state）
    progress: Optional[JobProgress] = None
    if job.state == "queued":
        progress = JobProgress(stage="queued", percentage=0, message="Waiting in queue")
    elif job.state == "processing":
        progress = JobProgress(stage="sfm", percentage=50, message="Running structure from motion")
    elif job.state == "packaging":
        progress = JobProgress(stage="packaging", percentage=90, message="Packaging output")
    
    response_data = GetJobResponse(
        job_id=job.id,
        state=job.state,
        progress=progress.model_dump() if progress else None,
        failure_reason=job.failure_reason,
        cancel_reason=job.cancel_reason,
        created_at=format_rfc3339_utc(job.created_at),
        updated_at=format_rfc3339_utc(job.updated_at),
        processing_started_at=format_rfc3339_utc(job.processing_started_at) if job.processing_started_at else None,
        artifact_id=job.artifact_id
    )
    
    api_response = APIResponse(success=True, data=response_data.model_dump(exclude_none=True))
    
    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content=api_response.model_dump(exclude_none=True)
    )


async def list_jobs(
    request: Request,
    state: Optional[str] = Query(None, description="State filter (comma-separated)"),
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db)
) -> JSONResponse:
    """
    GET /v1/jobs - 查询任务列表
    """
    user_id = request.state.user_id
    
    query = db.query(Job).filter(Job.user_id == user_id)
    
    # State过滤
    if state:
        state_list = [s.strip() for s in state.split(",") if s.strip()]
        if state_list:
            query = query.filter(Job.state.in_(state_list))
    
    # 总数
    total = query.count()
    
    # 排序和分页
    jobs = query.order_by(Job.created_at.desc()).offset(offset).limit(limit).all()
    
    job_items = [
        JobListItem(
            job_id=j.id,
            state=j.state,
            created_at=format_rfc3339_utc(j.created_at),
            artifact_id=j.artifact_id
        ).model_dump()
        for j in jobs
    ]
    
    response_data = ListJobsResponse(
        jobs=job_items,
        total=total,
        limit=limit,
        offset=offset
    )
    
    api_response = APIResponse(success=True, data=response_data.model_dump())
    
    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content=api_response.model_dump(exclude_none=True)
    )


async def cancel_job(
    job_id: str,
    request_body: CancelJobRequest,
    request: Request,
    db: Session = Depends(get_db)
) -> JSONResponse:
    """
    POST /v1/jobs/{id}/cancel - 取消任务
    """
    user_id = request.state.user_id
    
    job = db.query(Job).filter(
        Job.id == job_id,
        Job.user_id == user_id
    ).first()
    
    if not job:
        from app.core.ownership import create_ownership_error_response
        return create_ownership_error_response("Job")
    
    # 检查可取消状态
    terminal_states = ["completed", "failed", "cancelled"]
    if job.state in terminal_states:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.STATE_CONFLICT,
                message="Job already in terminal state"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_409_CONFLICT,
            content=error_response.model_dump(exclude_none=True)
        )
    
    if job.state == "packaging":
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.STATE_CONFLICT,
                message="Cannot cancel during packaging"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_409_CONFLICT,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # PROCESSING状态30秒窗口检查
    if job.state == "processing" and job.processing_started_at:
        elapsed = (datetime.utcnow() - job.processing_started_at).total_seconds()
        if elapsed > APIContractConstants.CANCEL_WINDOW_SECONDS:
            error_response = APIResponse(
                success=False,
                error=APIError(
                    code=APIErrorCode.STATE_CONFLICT,
                    message="Cancel window expired (30s)"
                )
            )
            return JSONResponse(
                status_code=status.HTTP_409_CONFLICT,
                content=error_response.model_dump(exclude_none=True)
            )
    
    # 取消任务
    job.state = "cancelled"
    job.cancel_reason = request_body.reason
    db.commit()
    
    response_data = CancelJobResponse(
        job_id=job.id,
        state="cancelled",
        cancel_reason=request_body.reason,
        cancelled_at=format_rfc3339_utc(datetime.utcnow())
    )
    
    api_response = APIResponse(success=True, data=response_data.model_dump())
    
    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content=api_response.model_dump(exclude_none=True)
    )


async def get_timeline(
    job_id: str,
    request: Request,
    db: Session = Depends(get_db)
) -> JSONResponse:
    """
    GET /v1/jobs/{id}/timeline - 查询任务时间线
    """
    user_id = request.state.user_id
    
    job = db.query(Job).filter(
        Job.id == job_id,
        Job.user_id == user_id
    ).first()
    
    if not job:
        from app.core.ownership import create_ownership_error_response
        return create_ownership_error_response("Job")
    
    events = db.query(TimelineEvent).filter(
        TimelineEvent.job_id == job_id
    ).order_by(TimelineEvent.timestamp.asc()).all()
    
    event_items = [
        TimelineEvent(
            timestamp=format_rfc3339_utc(e.timestamp),
            from_state=e.from_state,
            to_state=e.to_state,
            trigger=e.trigger
        ).model_dump()
        for e in events
    ]
    
    response_data = GetTimelineResponse(
        job_id=job_id,
        events=event_items
    )
    
    api_response = APIResponse(success=True, data=response_data.model_dump())
    
    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content=api_response.model_dump(exclude_none=True)
    )

