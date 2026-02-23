# =============================================================================
# CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
# Contract Version: PR2-JSM-2.5
# States: 8 | Transitions: 13 | FailureReasons: 14 | CancelReasons: 2
# =============================================================================

"""Tests for job state machine."""

import pytest

from jobs.contract_constants import ContractConstants
from jobs.job_state import (
    JobState,
    FailureReason,
    CancelReason,
    JobStateMachineError,
    transition,
    can_transition,
)


# Test constants
VALID_JOB_ID = "12345678901234567"  # 17 digits


class TestJobStateMachine:
    """Test job state machine functionality."""
    
    def test_all_state_pairs(self):
        """Test all 64 state pair combinations."""
        legal_count = 0
        illegal_count = 0
        
        for from_state in JobState:
            for to_state in JobState:
                if from_state.is_terminal:
                    # From terminal state: must raise alreadyTerminal (priority over illegalTransition)
                    with pytest.raises(JobStateMachineError) as exc_info:
                        transition(VALID_JOB_ID, from_state, to_state)
                    assert "ALREADY_TERMINAL" in str(exc_info.value) or "ALREADY_TERMINAL" in exc_info.value.code
                    illegal_count += 1
                elif from_state == to_state:
                    # Self-transition (non-terminal): must raise illegalTransition
                    with pytest.raises(JobStateMachineError) as exc_info:
                        transition(VALID_JOB_ID, from_state, to_state)
                    assert "ILLEGAL_TRANSITION" in str(exc_info.value) or "ILLEGAL_TRANSITION" in exc_info.value.code
                    illegal_count += 1
                elif can_transition(from_state, to_state):
                    # Legal transition: will be tested in specific test methods
                    legal_count += 1
                else:
                    # Illegal transition: must raise illegalTransition
                    with pytest.raises(JobStateMachineError) as exc_info:
                        transition(VALID_JOB_ID, from_state, to_state)
                    assert "ILLEGAL_TRANSITION" in str(exc_info.value) or "ILLEGAL_TRANSITION" in exc_info.value.code
                    illegal_count += 1
        
        # Verify counts
        assert legal_count == ContractConstants.LEGAL_TRANSITION_COUNT
        assert illegal_count == ContractConstants.ILLEGAL_TRANSITION_COUNT
        assert legal_count + illegal_count == ContractConstants.TOTAL_STATE_PAIRS
    
    def test_cancel_window_exactly_30s(self):
        """Exactly 30 seconds should succeed."""
        result = transition(
            VALID_JOB_ID,
            JobState.PROCESSING,
            JobState.CANCELLED,
            cancel_reason=CancelReason.USER_REQUESTED,
            elapsed_seconds=30
        )
        assert result == JobState.CANCELLED
    
    def test_cancel_window_31s_fails(self):
        """31 seconds should fail."""
        with pytest.raises(JobStateMachineError) as exc_info:
            transition(
                VALID_JOB_ID,
                JobState.PROCESSING,
                JobState.CANCELLED,
                cancel_reason=CancelReason.USER_REQUESTED,
                elapsed_seconds=31
            )
        assert "CANCEL_WINDOW_EXPIRED" in str(exc_info.value) or "CANCEL_WINDOW_EXPIRED" in exc_info.value.code
    
    def test_cancel_window_29s_succeeds(self):
        """29 seconds should succeed."""
        result = transition(
            VALID_JOB_ID,
            JobState.PROCESSING,
            JobState.CANCELLED,
            cancel_reason=CancelReason.USER_REQUESTED,
            elapsed_seconds=29
        )
        assert result == JobState.CANCELLED
    
    def test_cancel_window_missing_elapsed_seconds(self):
        """Missing elapsed_seconds for PROCESSING → CANCELLED should fail."""
        with pytest.raises(JobStateMachineError) as exc_info:
            transition(
                VALID_JOB_ID,
                JobState.PROCESSING,
                JobState.CANCELLED,
                cancel_reason=CancelReason.USER_REQUESTED,
                elapsed_seconds=None
            )
        assert "CANCEL_WINDOW_EXPIRED" in str(exc_info.value) or "CANCEL_WINDOW_EXPIRED" in exc_info.value.code
    
    def test_error_priority_order(self):
        """Test error priority order."""
        # Empty jobId should have highest priority
        with pytest.raises(JobStateMachineError) as exc_info:
            transition("", JobState.COMPLETED, JobState.FAILED)
        assert "EMPTY_JOB_ID" in str(exc_info.value) or "EMPTY_JOB_ID" in exc_info.value.code
        
        # alreadyTerminal should come before illegalTransition
        with pytest.raises(JobStateMachineError) as exc_info:
            transition(VALID_JOB_ID, JobState.COMPLETED, JobState.PENDING)
        assert "ALREADY_TERMINAL" in str(exc_info.value) or "ALREADY_TERMINAL" in exc_info.value.code
    
    def test_job_id_boundary(self):
        """Test job ID boundary conditions."""
        # 14 digits: too short
        with pytest.raises(JobStateMachineError) as exc_info:
            transition("12345678901234", JobState.PENDING, JobState.UPLOADING, cancel_reason=CancelReason.USER_REQUESTED)
        assert "JOB_ID_TOO_SHORT" in str(exc_info.value) or "JOB_ID_TOO_SHORT" in exc_info.value.code
        
        # 15 digits: valid (minimum)
        result = transition(
            "123456789012345",
            JobState.PENDING,
            JobState.UPLOADING,
            cancel_reason=CancelReason.USER_REQUESTED
        )
        assert result == JobState.UPLOADING
        
        # 20 digits: valid (maximum)
        result = transition(
            "12345678901234567890",
            JobState.PENDING,
            JobState.UPLOADING,
            cancel_reason=CancelReason.USER_REQUESTED
        )
        assert result == JobState.UPLOADING
        
        # 21 digits: too long
        with pytest.raises(JobStateMachineError) as exc_info:
            transition("123456789012345678901", JobState.PENDING, JobState.UPLOADING)
        assert "JOB_ID_TOO_LONG" in str(exc_info.value) or "JOB_ID_TOO_LONG" in exc_info.value.code
        
        # Invalid characters
        with pytest.raises(JobStateMachineError) as exc_info:
            transition("12345678901234a", JobState.PENDING, JobState.UPLOADING)
        assert "JOB_ID_INVALID_CHARS" in str(exc_info.value) or "JOB_ID_INVALID_CHARS" in exc_info.value.code
    
    def test_failure_reason_binding(self):
        """Test failure reason binding."""
        # Valid: networkError from UPLOADING
        result = transition(
            VALID_JOB_ID,
            JobState.UPLOADING,
            JobState.FAILED,
            failure_reason=FailureReason.NETWORK_ERROR
        )
        assert result == JobState.FAILED
        
        # Invalid: networkError from QUEUED (not allowed)
        with pytest.raises(JobStateMachineError) as exc_info:
            transition(
                VALID_JOB_ID,
                JobState.QUEUED,
                JobState.FAILED,
                failure_reason=FailureReason.NETWORK_ERROR
            )
        assert "INVALID_FAILURE_REASON" in str(exc_info.value) or "INVALID_FAILURE_REASON" in exc_info.value.code
        
        # Missing failure reason for FAILED state
        with pytest.raises(JobStateMachineError) as exc_info:
            transition(
                VALID_JOB_ID,
                JobState.UPLOADING,
                JobState.FAILED,
                failure_reason=None
            )
        assert "INVALID_FAILURE_REASON" in str(exc_info.value) or "INVALID_FAILURE_REASON" in exc_info.value.code
    
    def test_cancel_reason_binding(self):
        """Test cancel reason binding."""
        # Valid: userRequested from PENDING
        result = transition(
            VALID_JOB_ID,
            JobState.PENDING,
            JobState.CANCELLED,
            cancel_reason=CancelReason.USER_REQUESTED
        )
        assert result == JobState.CANCELLED
        
        # Valid: appTerminated from UPLOADING
        result = transition(
            VALID_JOB_ID,
            JobState.UPLOADING,
            JobState.CANCELLED,
            cancel_reason=CancelReason.APP_TERMINATED
        )
        assert result == JobState.CANCELLED
        
        # Missing cancel reason for CANCELLED state
        with pytest.raises(JobStateMachineError) as exc_info:
            transition(
                VALID_JOB_ID,
                JobState.PENDING,
                JobState.CANCELLED,
                cancel_reason=None
            )
        assert "INVALID_CANCEL_REASON" in str(exc_info.value) or "INVALID_CANCEL_REASON" in exc_info.value.code
    
    def test_server_only_failure_reason(self):
        """Test server-only failure reason validation."""
        # Client-side attempt with serverOnly reason: should fail
        with pytest.raises(JobStateMachineError) as exc_info:
            transition(
                VALID_JOB_ID,
                JobState.PROCESSING,
                JobState.FAILED,
                failure_reason=FailureReason.GPU_OUT_OF_MEMORY,
                is_server_side=False
            )
        assert "SERVER_ONLY_FAILURE_REASON" in str(exc_info.value) or "SERVER_ONLY_FAILURE_REASON" in exc_info.value.code
        
        # Server-side with serverOnly reason: should succeed
        result = transition(
            VALID_JOB_ID,
            JobState.PROCESSING,
            JobState.FAILED,
            failure_reason=FailureReason.GPU_OUT_OF_MEMORY,
            is_server_side=True
        )
        assert result == JobState.FAILED
        
        # Client-side with non-serverOnly reason: should succeed
        result = transition(
            VALID_JOB_ID,
            JobState.UPLOADING,
            JobState.FAILED,
            failure_reason=FailureReason.NETWORK_ERROR,
            is_server_side=False
        )
        assert result == JobState.FAILED
    
    def test_job_state_from_string(self):
        """Test creating JobState from string."""
        valid_cases = [
            ("pending", JobState.PENDING),
            ("uploading", JobState.UPLOADING),
            ("queued", JobState.QUEUED),
            ("processing", JobState.PROCESSING),
            ("packaging", JobState.PACKAGING),
            ("completed", JobState.COMPLETED),
            ("failed", JobState.FAILED),
            ("cancelled", JobState.CANCELLED),
        ]
        
        for raw_value, expected in valid_cases:
            assert JobState(raw_value) == expected
        
        assert len(valid_cases) == ContractConstants.STATE_COUNT
    
    def test_invalid_job_state_raises(self):
        """Invalid values must raise ValueError."""
        invalid_values = ["PENDING", "Pending", "unknown", "", "0"]
        
        for invalid in invalid_values:
            with pytest.raises(ValueError):
                JobState(invalid)
    
    def test_terminal_state_protection(self):
        """Test terminal state protection."""
        terminal_states = [JobState.COMPLETED, JobState.FAILED, JobState.CANCELLED]
        
        for terminal_state in terminal_states:
            # Try to transition from terminal state to any other state
            for target_state in JobState:
                if target_state != terminal_state:
                    with pytest.raises(JobStateMachineError) as exc_info:
                        transition(VALID_JOB_ID, terminal_state, target_state)
                    assert "ALREADY_TERMINAL" in str(exc_info.value) or "ALREADY_TERMINAL" in exc_info.value.code
    
    def test_legal_transitions(self):
        """Test all legal transitions."""
        # Test each legal transition with appropriate reasons
        legal_tests = [
            (JobState.PENDING, JobState.UPLOADING, None, None, None),
            (JobState.PENDING, JobState.CANCELLED, None, CancelReason.USER_REQUESTED, None),
            (JobState.UPLOADING, JobState.QUEUED, None, None, None),
            (JobState.UPLOADING, JobState.FAILED, FailureReason.NETWORK_ERROR, None, None),
            (JobState.UPLOADING, JobState.CANCELLED, None, CancelReason.USER_REQUESTED, None),
            (JobState.QUEUED, JobState.PROCESSING, None, None, None),
            (JobState.QUEUED, JobState.FAILED, FailureReason.SERVER_UNAVAILABLE, None, None),
            (JobState.QUEUED, JobState.CANCELLED, None, CancelReason.USER_REQUESTED, None),
            (JobState.PROCESSING, JobState.PACKAGING, None, None, None),
            (JobState.PROCESSING, JobState.FAILED, FailureReason.TRAINING_FAILED, None, None),
            (JobState.PROCESSING, JobState.CANCELLED, None, CancelReason.USER_REQUESTED, 30),
            (JobState.PACKAGING, JobState.COMPLETED, None, None, None),
            (JobState.PACKAGING, JobState.FAILED, FailureReason.PACKAGING_FAILED, None, None),
        ]
        
        for from_state, to_state, failure_reason, cancel_reason, elapsed_seconds in legal_tests:
            result = transition(
                VALID_JOB_ID,
                from_state,
                to_state,
                failure_reason=failure_reason,
                cancel_reason=cancel_reason,
                elapsed_seconds=elapsed_seconds,
                is_server_side=True
            )
            assert result == to_state

