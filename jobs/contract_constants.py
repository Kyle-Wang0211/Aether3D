# =============================================================================
# CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
# Contract Version: PR2-JSM-2.5
# States: 8 | Transitions: 13 | FailureReasons: 14 | CancelReasons: 2
# =============================================================================

"""Contract constants for PR#2 Job State Machine (SSOT)."""


class ContractConstants:
    # Version
    CONTRACT_VERSION = "PR2-JSM-2.5"
    
    # Counts (MUST match actual enum counts)
    STATE_COUNT = 8
    LEGAL_TRANSITION_COUNT = 13
    ILLEGAL_TRANSITION_COUNT = 51
    TOTAL_STATE_PAIRS = 64
    FAILURE_REASON_COUNT = 14
    CANCEL_REASON_COUNT = 2
    
    # JobId Validation
    JOB_ID_MIN_LENGTH = 15
    JOB_ID_MAX_LENGTH = 20
    
    # Cancel Window
    CANCEL_WINDOW_SECONDS = 30
    
    # Progress Report
    PROGRESS_REPORT_INTERVAL_SECONDS = 5
    HEALTH_CHECK_INTERVAL_SECONDS = 10
    
    # Upload
    CHUNK_SIZE_BYTES = 5 * 1024 * 1024
    MAX_VIDEO_DURATION_SECONDS = 15 * 60
    MIN_VIDEO_DURATION_SECONDS = 10
    
    # Retry
    MAX_AUTO_RETRY_COUNT = 3
    RETRY_BASE_INTERVAL_SECONDS = 2
    
    # Queued Timeout
    QUEUED_TIMEOUT_SECONDS = 3600
    QUEUED_WARNING_SECONDS = 1800

