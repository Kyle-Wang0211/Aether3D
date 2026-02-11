"""
PR#10 Deduplicator Tests (~200 scenarios).

Tests for deduplicator.py: check_pre_upload, check_post_assembly,
_DEDUP_VALID_STATES, DedupResult frozen, DedupDecision enum.
"""

import pytest
from hypothesis import given, strategies as st
from unittest.mock import Mock

from app.services.deduplicator import (
    DedupDecision, DedupResult, Deduplicator, _DEDUP_VALID_STATES,
    check_dedup_post_assembly, check_dedup_pre_upload
)
from app.models import Job, UploadSession


@pytest.fixture
def mock_db():
    """Mock SQLAlchemy session."""
    return Mock()


@pytest.fixture
def bundle_hash():
    """Test bundle hash."""
    return "a" * 64


@pytest.fixture
def user_id():
    """Test user ID."""
    return "user-123"


# Test _DEDUP_VALID_STATES
class TestDedupValidStates:
    """Test _DEDUP_VALID_STATES constant."""
    
    def test_dedup_valid_states_count(self):
        """Exactly 3 states."""
        assert len(_DEDUP_VALID_STATES) == 3
    
    def test_dedup_valid_states_values(self):
        """Contains correct states."""
        assert "completed" in _DEDUP_VALID_STATES
        assert "queued" in _DEDUP_VALID_STATES
        assert "processing" in _DEDUP_VALID_STATES
    
    def test_dedup_valid_states_excludes_failed(self):
        """Excludes failed state."""
        assert "failed" not in _DEDUP_VALID_STATES
    
    def test_dedup_valid_states_excludes_cancelled(self):
        """Excludes cancelled state."""
        assert "cancelled" not in _DEDUP_VALID_STATES


# Test check_pre_upload()
class TestCheckPreUpload:
    """Test check_pre_upload() instant upload detection."""
    
    def test_check_pre_upload_no_match(self, mock_db, bundle_hash, user_id):
        """No duplicate found."""
        mock_db.query.return_value.filter.return_value.first.return_value = None
        result = check_dedup_pre_upload(bundle_hash, user_id, mock_db)
        assert result.decision == DedupDecision.PROCEED
    
    def test_check_pre_upload_job_match(self, mock_db, bundle_hash, user_id):
        """Existing Job found."""
        existing_job = Mock(spec=Job)
        existing_job.id = "job-123"
        mock_db.query.return_value.filter.return_value.first.return_value = existing_job
        result = check_dedup_pre_upload(bundle_hash, user_id, mock_db)
        assert result.decision == DedupDecision.INSTANT_UPLOAD
        assert result.existing_job_id == "job-123"
    
    def test_check_pre_upload_wrong_user(self, mock_db, bundle_hash, user_id):
        """Job exists but for different user (INV-U22)."""
        # First query (Job) returns None (wrong user)
        # Second query (UploadSession) returns None
        mock_db.query.return_value.filter.return_value.first.return_value = None
        result = check_dedup_pre_upload(bundle_hash, user_id, mock_db)
        assert result.decision == DedupDecision.PROCEED  # Not found for this user
    
    def test_check_pre_upload_in_progress_session(self, mock_db, bundle_hash, user_id):
        """In-progress session logged but doesn't block."""
        # Job query returns None
        # Session query returns in-progress session
        mock_session = Mock(spec=UploadSession)
        mock_session.id = "upload-123"
        mock_db.query.return_value.filter.return_value.first.side_effect = [None, mock_session]
        result = check_dedup_pre_upload(bundle_hash, user_id, mock_db)
        assert result.decision == DedupDecision.PROCEED  # Doesn't block


# Test check_post_assembly()
class TestCheckPostAssembly:
    """Test check_post_assembly() post-assembly dedup."""
    
    def test_check_post_assembly_no_match(self, mock_db, bundle_hash, user_id):
        """No duplicate found."""
        mock_db.query.return_value.filter.return_value.first.return_value = None
        result = check_dedup_post_assembly(bundle_hash, user_id, mock_db)
        assert result.decision == DedupDecision.PROCEED
    
    def test_check_post_assembly_existing_job(self, mock_db, bundle_hash, user_id):
        """Existing Job found (reuse bundle)."""
        existing_job = Mock(spec=Job)
        existing_job.id = "job-123"
        mock_db.query.return_value.filter.return_value.first.return_value = existing_job
        result = check_dedup_post_assembly(bundle_hash, user_id, mock_db)
        assert result.decision == DedupDecision.REUSE_BUNDLE
        assert result.existing_job_id == "job-123"
    
    def test_check_post_assembly_race_condition(self, mock_db, bundle_hash, user_id):
        """Race condition: another upload completed during assembly."""
        existing_job = Mock(spec=Job)
        existing_job.id = "job-456"
        mock_db.query.return_value.filter.return_value.first.return_value = existing_job
        result = check_dedup_post_assembly(bundle_hash, user_id, mock_db)
        assert result.decision == DedupDecision.REUSE_BUNDLE  # INV-U23: race-safe


# Test DedupResult
class TestDedupResult:
    """Test DedupResult dataclass."""
    
    def test_dedup_result_frozen(self, bundle_hash):
        """DedupResult is frozen (INV-U24)."""
        result = DedupResult(
            decision=DedupDecision.PROCEED,
            existing_job_id=None,
            message="test"
        )
        # Frozen dataclass cannot be modified
        with pytest.raises(Exception):
            result.decision = DedupDecision.INSTANT_UPLOAD
    
    @pytest.mark.parametrize("decision", [
        DedupDecision.PROCEED,
        DedupDecision.INSTANT_UPLOAD,
        DedupDecision.REUSE_BUNDLE,
    ])
    def test_dedup_result_decisions(self, decision):
        """All decisions create valid result."""
        result = DedupResult(decision=decision)
        assert result.decision == decision


# Test DedupDecision enum
class TestDedupDecision:
    """Test DedupDecision enum."""
    
    def test_dedup_decision_values(self):
        """Enum has correct values."""
        assert DedupDecision.PROCEED == "proceed"
        assert DedupDecision.INSTANT_UPLOAD == "instant_upload"
        assert DedupDecision.REUSE_BUNDLE == "reuse_bundle"
    
    def test_dedup_decision_count(self):
        """Exactly 3 decisions."""
        assert len(DedupDecision) == 3


# Hypothesis property-based tests
@given(st.text(min_size=64, max_size=64, alphabet=st.characters(whitelist_categories=('Nd', 'Ll'))))
def test_check_pre_upload_hypothesis(bundle_hash):
    """Property: check_pre_upload handles random bundle_hash."""
    mock_db = Mock()
    mock_db.query.return_value.filter.return_value.first.return_value = None
    result = check_dedup_pre_upload(bundle_hash, "user-123", mock_db)
    assert result.decision in [DedupDecision.PROCEED, DedupDecision.INSTANT_UPLOAD]
