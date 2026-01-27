# =============================================================================
# Capacity Contract Tests (v0)
# PR1 C-Class: Ensures Python-side capacity constants and state transitions stay aligned
# =============================================================================

"""Capacity contract tests for PR1 C-Class.

These tests enforce that:
- JobState enum contains CAPACITY_SATURATED
- Legal transitions include PROCESSING -> CAPACITY_SATURATED
- Contract constants match expected values
"""

import sys
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from jobs.job_state import JobState, LEGAL_TRANSITIONS
from jobs.contract_constants import ContractConstants


def test_capacity_saturated_in_enum():
    """Test that CAPACITY_SATURATED exists in JobState enum."""
    assert hasattr(JobState, 'CAPACITY_SATURATED'), "JobState must have CAPACITY_SATURATED"
    assert JobState.CAPACITY_SATURATED == "capacity_saturated", "CAPACITY_SATURATED rawValue must be 'capacity_saturated'"


def test_capacity_saturated_transition_exists():
    """Test that PROCESSING -> CAPACITY_SATURATED transition exists."""
    transition = (JobState.PROCESSING, JobState.CAPACITY_SATURATED)
    assert transition in LEGAL_TRANSITIONS, "PROCESSING -> CAPACITY_SATURATED must be legal"


def test_soft_limit_patch_count():
    """Test that SOFT_LIMIT_PATCH_COUNT equals 5000."""
    assert ContractConstants.SOFT_LIMIT_PATCH_COUNT == 5000, "SOFT_LIMIT_PATCH_COUNT must be 5000"


def test_hard_limit_patch_count():
    """Test that HARD_LIMIT_PATCH_COUNT equals 8000."""
    assert ContractConstants.HARD_LIMIT_PATCH_COUNT == 8000, "HARD_LIMIT_PATCH_COUNT must be 8000"


def test_eeb_base_budget():
    """Test that EEB_BASE_BUDGET equals 10000.0."""
    assert ContractConstants.EEB_BASE_BUDGET == 10000.0, "EEB_BASE_BUDGET must be 10000.0"


def test_capacity_saturated_is_terminal():
    """Test that CAPACITY_SATURATED is a terminal state."""
    assert JobState.CAPACITY_SATURATED.is_terminal, "CAPACITY_SATURATED must be terminal"


if __name__ == "__main__":
    # Run tests as standalone script
    test_capacity_saturated_in_enum()
    test_capacity_saturated_transition_exists()
    test_soft_limit_patch_count()
    test_hard_limit_patch_count()
    test_eeb_base_budget()
    test_capacity_saturated_is_terminal()
    print("All capacity contract tests passed!")
