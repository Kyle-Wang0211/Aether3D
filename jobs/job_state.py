# =============================================================================
# CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
# Contract Version: PR2-JSM-2.5
# States: 8 | Transitions: 13 | FailureReasons: 14 | CancelReasons: 2
# =============================================================================

"""Job state machine implementation (pure function)."""

from datetime import datetime
from enum import Enum
from typing import Callable, Optional

from jobs.contract_constants import ContractConstants


class JobState(str, Enum):
    """Job state enumeration (8 states)."""
    
    PENDING = "pending"
    UPLOADING = "uploading"
    QUEUED = "queued"
    PROCESSING = "processing"
    PACKAGING = "packaging"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"
    
    @property
    def is_terminal(self) -> bool:
        """Whether this state is a terminal state (no further transitions allowed)."""
        return self in {JobState.COMPLETED, JobState.FAILED, JobState.CANCELLED}
    
    @property
    def is_cancellable(self) -> bool:
        """Whether this state is always cancellable.
        
        Note: PROCESSING has conditional cancellability (30-second window).
        """
        return self in {JobState.PENDING, JobState.UPLOADING, JobState.QUEUED}


class FailureReason(str, Enum):
    """Failure reason enumeration (14 reasons)."""
    
    NETWORK_ERROR = "network_error"
    UPLOAD_INTERRUPTED = "upload_interrupted"
    SERVER_UNAVAILABLE = "server_unavailable"
    INVALID_VIDEO_FORMAT = "invalid_video_format"
    VIDEO_TOO_SHORT = "video_too_short"
    VIDEO_TOO_LONG = "video_too_long"
    INSUFFICIENT_FRAMES = "insufficient_frames"
    POSE_ESTIMATION_FAILED = "pose_estimation_failed"
    LOW_REGISTRATION_RATE = "low_registration_rate"
    TRAINING_FAILED = "training_failed"
    GPU_OUT_OF_MEMORY = "gpu_out_of_memory"
    PROCESSING_TIMEOUT = "processing_timeout"
    PACKAGING_FAILED = "packaging_failed"
    INTERNAL_ERROR = "internal_error"
    
    @property
    def is_retryable(self) -> bool:
        """Whether this failure reason is retryable."""
        return self in {
            FailureReason.NETWORK_ERROR,
            FailureReason.UPLOAD_INTERRUPTED,
            FailureReason.SERVER_UNAVAILABLE,
            FailureReason.TRAINING_FAILED,
            FailureReason.GPU_OUT_OF_MEMORY,
            FailureReason.PROCESSING_TIMEOUT,
            FailureReason.PACKAGING_FAILED,
            FailureReason.INTERNAL_ERROR,
        }
    
    @property
    def is_server_only(self) -> bool:
        """Whether this failure reason is server-side only."""
        return self not in {
            FailureReason.NETWORK_ERROR,
            FailureReason.UPLOAD_INTERRUPTED,
        }


class CancelReason(str, Enum):
    """Cancel reason enumeration (2 reasons)."""
    
    USER_REQUESTED = "user_requested"
    APP_TERMINATED = "app_terminated"


class JobStateMachineError(Exception):
    """Job state machine error types."""
    
    def __init__(self, code: str, message: str):
        self.code = code
        self.message = message
        super().__init__(self.message)


# Legal transitions (13 total)
LEGAL_TRANSITIONS: frozenset = frozenset([
    (JobState.PENDING, JobState.UPLOADING),
    (JobState.PENDING, JobState.CANCELLED),
    (JobState.UPLOADING, JobState.QUEUED),
    (JobState.UPLOADING, JobState.FAILED),
    (JobState.UPLOADING, JobState.CANCELLED),
    (JobState.QUEUED, JobState.PROCESSING),
    (JobState.QUEUED, JobState.FAILED),
    (JobState.QUEUED, JobState.CANCELLED),
    (JobState.PROCESSING, JobState.PACKAGING),
    (JobState.PROCESSING, JobState.FAILED),
    (JobState.PROCESSING, JobState.CANCELLED),
    (JobState.PACKAGING, JobState.COMPLETED),
    (JobState.PACKAGING, JobState.FAILED),
])

# Failure reason binding map
FAILURE_REASON_BINDING: dict = {
    FailureReason.NETWORK_ERROR: {JobState.UPLOADING},
    FailureReason.UPLOAD_INTERRUPTED: {JobState.UPLOADING},
    FailureReason.SERVER_UNAVAILABLE: {JobState.UPLOADING, JobState.QUEUED},
    FailureReason.INVALID_VIDEO_FORMAT: {JobState.UPLOADING, JobState.QUEUED},
    FailureReason.VIDEO_TOO_SHORT: {JobState.QUEUED},
    FailureReason.VIDEO_TOO_LONG: {JobState.QUEUED},
    FailureReason.INSUFFICIENT_FRAMES: {JobState.QUEUED, JobState.PROCESSING},
    FailureReason.POSE_ESTIMATION_FAILED: {JobState.PROCESSING},
    FailureReason.LOW_REGISTRATION_RATE: {JobState.PROCESSING},
    FailureReason.TRAINING_FAILED: {JobState.PROCESSING},
    FailureReason.GPU_OUT_OF_MEMORY: {JobState.PROCESSING},
    FailureReason.PROCESSING_TIMEOUT: {JobState.PROCESSING},
    FailureReason.PACKAGING_FAILED: {JobState.PACKAGING},
    FailureReason.INTERNAL_ERROR: {JobState.UPLOADING, JobState.QUEUED, JobState.PROCESSING, JobState.PACKAGING},
}

# Cancel reason binding map
CANCEL_REASON_BINDING: dict = {
    CancelReason.USER_REQUESTED: {JobState.PENDING, JobState.UPLOADING, JobState.QUEUED, JobState.PROCESSING},
    CancelReason.APP_TERMINATED: {JobState.PENDING, JobState.UPLOADING, JobState.QUEUED, JobState.PROCESSING},
}


def can_transition(from_state: JobState, to_state: JobState) -> bool:
    """Check if a transition is legal (does not include 30-second window check).
    
    Args:
        from_state: Source state
        to_state: Target state
        
    Returns:
        True if transition is legal
    """
    if from_state == to_state:
        return False
    return (from_state, to_state) in LEGAL_TRANSITIONS


def _validate_job_id(job_id: str) -> None:
    """Validate job ID format (15-20 digit string).
    
    Args:
        job_id: Job ID to validate
        
    Raises:
        JobStateMachineError if validation fails
    """
    # 1. Check empty
    if not job_id:
        raise JobStateMachineError("JSM.EMPTY_JOB_ID", "Job ID cannot be empty")
    
    # 2. Check length
    if len(job_id) < ContractConstants.JOB_ID_MIN_LENGTH:
        raise JobStateMachineError("JSM.JOB_ID_TOO_SHORT", f"Job ID too short: {len(job_id)}")
    if len(job_id) > ContractConstants.JOB_ID_MAX_LENGTH:
        raise JobStateMachineError("JSM.JOB_ID_TOO_LONG", f"Job ID too long: {len(job_id)}")
    
    # 3. Check characters (only digits allowed)
    for index, char in enumerate(job_id):
        if not char.isdigit():
            raise JobStateMachineError("JSM.JOB_ID_INVALID_CHARS", f"Job ID contains invalid character at index {index}")


def _is_valid_failure_reason(reason: FailureReason, from_state: JobState) -> bool:
    """Validate failure reason is allowed from source state.
    
    Args:
        reason: Failure reason
        from_state: Source state
        
    Returns:
        True if valid
    """
    allowed_states = FAILURE_REASON_BINDING.get(reason)
    if allowed_states is None:
        return False
    return from_state in allowed_states


def _is_valid_cancel_reason(reason: CancelReason, from_state: JobState) -> bool:
    """Validate cancel reason is allowed from source state.
    
    Args:
        reason: Cancel reason
        from_state: Source state
        
    Returns:
        True if valid
    """
    allowed_states = CANCEL_REASON_BINDING.get(reason)
    if allowed_states is None:
        return False
    return from_state in allowed_states


def transition(
    job_id: str,
    from_state: JobState,
    to_state: JobState,
    failure_reason: Optional[FailureReason] = None,
    cancel_reason: Optional[CancelReason] = None,
    elapsed_seconds: Optional[int] = None,
    is_server_side: bool = False,
    logger: Optional[Callable] = None
) -> JobState:
    """Execute state transition (pure function).
    
    Args:
        job_id: Job ID (snowflake ID, 15-20 digits)
        from_state: Current state
        to_state: Target state
        failure_reason: Failure reason (required when to_state == FAILED)
        cancel_reason: Cancel reason (required when to_state == CANCELLED)
        elapsed_seconds: Seconds elapsed since entering PROCESSING (required for PROCESSING → CANCELLED)
        is_server_side: Whether this is a server-side call (for serverOnly validation)
        logger: Log callback
        
    Returns:
        New state after transition
        
    Raises:
        JobStateMachineError if transition is invalid
    """
    # Error priority order (strictly enforced):
    # 1. jobId validation
    _validate_job_id(job_id)
    
    # 2. Check terminal state
    if from_state.is_terminal:
        raise JobStateMachineError("JSM.ALREADY_TERMINAL", f"Cannot transition from terminal state: {from_state.value}")
    
    # 3. Check transition legality
    if not can_transition(from_state, to_state):
        raise JobStateMachineError("JSM.ILLEGAL_TRANSITION", f"Cannot transition from {from_state.value} to {to_state.value}")
    
    # 4. Check 30-second cancel window (only for PROCESSING → CANCELLED)
    if from_state == JobState.PROCESSING and to_state == JobState.CANCELLED:
        if elapsed_seconds is None:
            raise JobStateMachineError("JSM.CANCEL_WINDOW_EXPIRED", "elapsed_seconds is required for PROCESSING → CANCELLED")
        if elapsed_seconds > ContractConstants.CANCEL_WINDOW_SECONDS:
            raise JobStateMachineError("JSM.CANCEL_WINDOW_EXPIRED", f"Cancel window expired: {elapsed_seconds} seconds")
    
    # 5. Validate failure reason
    if to_state == JobState.FAILED:
        if failure_reason is None:
            raise JobStateMachineError("JSM.INVALID_FAILURE_REASON", f"Failure reason is required when transitioning to FAILED from {from_state.value}")
        if not _is_valid_failure_reason(failure_reason, from_state):
            raise JobStateMachineError("JSM.INVALID_FAILURE_REASON", f"Failure reason {failure_reason.value} is not allowed from {from_state.value}")
        if failure_reason.is_server_only and not is_server_side:
            raise JobStateMachineError("JSM.SERVER_ONLY_FAILURE_REASON", f"Failure reason {failure_reason.value} is server-only")
    
    # 6. Validate cancel reason
    if to_state == JobState.CANCELLED:
        if cancel_reason is None:
            raise JobStateMachineError("JSM.INVALID_CANCEL_REASON", f"Cancel reason is required when transitioning to CANCELLED from {from_state.value}")
        if not _is_valid_cancel_reason(cancel_reason, from_state):
            raise JobStateMachineError("JSM.INVALID_CANCEL_REASON", f"Cancel reason {cancel_reason.value} is not allowed from {from_state.value}")
    
    # 7. Log transition
    if logger:
        log_entry = {
            "job_id": job_id,
            "from_state": from_state.value,
            "to_state": to_state.value,
            "failure_reason": failure_reason.value if failure_reason else None,
            "cancel_reason": cancel_reason.value if cancel_reason else None,
            "timestamp": datetime.now().isoformat(),
            "contract_version": ContractConstants.CONTRACT_VERSION,
        }
        logger(log_entry)
    
    return to_state

