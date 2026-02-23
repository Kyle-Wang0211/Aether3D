# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""API路由注册（12个端点）"""

from fastapi import APIRouter

from app.api.handlers import artifact_handlers, health_handlers, job_handlers, upload_handlers

router = APIRouter()

# Health (1)
router.add_api_route("/health", health_handlers.health_check, methods=["GET"])

# Uploads (4)
router.add_api_route("/uploads", upload_handlers.create_upload, methods=["POST"])
router.add_api_route("/uploads/{upload_id}/chunks", upload_handlers.upload_chunk, methods=["PATCH"])
router.add_api_route("/uploads/{upload_id}/chunks", upload_handlers.get_chunks, methods=["GET"])
router.add_api_route("/uploads/{upload_id}/complete", upload_handlers.complete_upload, methods=["POST"])

# Jobs (5)
router.add_api_route("/jobs", job_handlers.create_job, methods=["POST"])
router.add_api_route("/jobs/{job_id}", job_handlers.get_job, methods=["GET"])
router.add_api_route("/jobs", job_handlers.list_jobs, methods=["GET"])
router.add_api_route("/jobs/{job_id}/cancel", job_handlers.cancel_job, methods=["POST"])
router.add_api_route("/jobs/{job_id}/timeline", job_handlers.get_timeline, methods=["GET"])

# Artifacts (2)
router.add_api_route("/artifacts/{artifact_id}", artifact_handlers.get_artifact, methods=["GET"])
router.add_api_route("/artifacts/{artifact_id}/download", artifact_handlers.download_artifact, methods=["GET"])
