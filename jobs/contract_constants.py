# =============================================================================
# CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
# Contract Version: PR2-JSM-2.5 (PR1 C-Class: +1 state CAPACITY_SATURATED)
# States: 9 | Transitions: 14 | FailureReasons: 14 | CancelReasons: 2
# =============================================================================

"""Contract constants for PR#2 Job State Machine (SSOT)."""


class ContractConstants:
    # Version
    CONTRACT_VERSION = "PR2-JSM-2.5"
    
    # Counts (MUST match actual enum counts)
    STATE_COUNT = 9  # PR1 C-Class: +1 for CAPACITY_SATURATED
    LEGAL_TRANSITION_COUNT = 14  # PR1 C-Class: +1 for PROCESSING -> CAPACITY_SATURATED
    ILLEGAL_TRANSITION_COUNT = 67  # 9 × 9 - 14 = 67
    TOTAL_STATE_PAIRS = 81  # 9 × 9 = 81
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
    
    # PR1 C-Class Capacity Control Constants
    SOFT_LIMIT_PATCH_COUNT = 5000
    HARD_LIMIT_PATCH_COUNT = 8000
    EEB_BASE_BUDGET = 10000.0
    EEB_MIN_QUANTUM = 1.0
    SOFT_BUDGET_THRESHOLD = 2000.0
    HARD_BUDGET_THRESHOLD = 500.0
    IG_MIN_SOFT = 0.1
    NOVELTY_MIN_SOFT = 0.1
    
    # Duplicate Detection Constants
    POSE_EPS = 0.01
    COVERAGE_CELL_SIZE = 0.1
    RADIANCE_BINNING = 16

