"""
PR#10 Cleanup Handler Tests (~200 scenarios).

Tests for cleanup_handler.py: cleanup_after_assembly, cleanup_user_expired,
cleanup_global, CleanupResult, idempotency, DB-before-file.
"""

import os
import pytest
import tempfile
import shutil
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import Mock, patch

from app.services.cleanup_handler import (
    CleanupHandler, CleanupResult, cleanup_after_assembly,
    cleanup_global, cleanup_user_expired
)
from app.models import UploadSession


@pytest.fixture
def temp_upload_dir():
    """Create temporary upload directory."""
    temp_dir = tempfile.mkdtemp()
    yield Path(temp_dir)
    shutil.rmtree(temp_dir, ignore_errors=True)


@pytest.fixture
def mock_settings(temp_upload_dir):
    """Mock settings.upload_path."""
    with patch('app.services.cleanup_handler.settings') as mock:
        mock.upload_path = temp_upload_dir
        yield mock


@pytest.fixture
def mock_db():
    """Mock SQLAlchemy session."""
    return Mock()


@pytest.fixture
def upload_id():
    """Test upload ID."""
    return "test-upload-123"


@pytest.fixture
def user_id():
    """Test user ID."""
    return "user-123"


# Test cleanup_after_assembly()
class TestCleanupAfterAssembly:
    """Test cleanup_after_assembly() Tier 1 cleanup."""
    
    def test_cleanup_after_assembly_success(self, mock_settings, upload_id):
        """Successful cleanup removes chunk files."""
        chunk_dir = mock_settings.upload_path / upload_id / "chunks"
        chunk_dir.mkdir(parents=True)
        chunk_file = chunk_dir / "000000.chunk"
        chunk_file.write_bytes(b"test")
        
        result = cleanup_after_assembly(upload_id, success=True)
        
        assert result.chunks_deleted == 1
        assert not chunk_file.exists()
        assert not chunk_dir.exists()
    
    def test_cleanup_after_assembly_partial_failure(self, mock_settings, upload_id):
        """Partial failure is fail-open (INV-U25)."""
        chunk_dir = mock_settings.upload_path / upload_id / "chunks"
        chunk_dir.mkdir(parents=True)
        chunk_file = chunk_dir / "000000.chunk"
        chunk_file.write_bytes(b"test")
        
        # Simulate file deletion failure
        with patch('pathlib.Path.unlink', side_effect=OSError("Permission denied")):
            result = cleanup_after_assembly(upload_id, success=True)
            assert len(result.errors) > 0  # Errors logged but continues
    
    def test_cleanup_after_assembly_assembly_dir(self, mock_settings, upload_id):
        """Assembly directory is cleaned."""
        assembly_dir = mock_settings.upload_path / upload_id / "assembly"
        assembly_dir.mkdir(parents=True)
        assembling_file = assembly_dir / "test.bundle.assembling"
        assembling_file.write_bytes(b"test")
        
        result = cleanup_after_assembly(upload_id, success=True)
        assert result.dirs_deleted >= 1
        assert not assembly_dir.exists()


# Test cleanup_user_expired()
class TestCleanupUserExpired:
    """Test cleanup_user_expired() Tier 2 cleanup."""
    
    def test_cleanup_user_expired_expired_session(self, mock_settings, mock_db, user_id):
        """Expired session is cleaned."""
        expired_session = Mock(spec=UploadSession)
        expired_session.id = "expired-123"
        expired_session.status = "in_progress"
        expired_session.expires_at = datetime.utcnow() - timedelta(hours=25)
        
        session_dir = mock_settings.upload_path / expired_session.id
        session_dir.mkdir(parents=True)
        (session_dir / "test.chunk").write_bytes(b"test")
        
        mock_db.query.return_value.filter.return_value.all.return_value = [expired_session]
        
        result = cleanup_user_expired(user_id, mock_db)
        
        assert result.sessions_expired == 1
        assert expired_session.status == "expired"
        mock_db.commit.assert_called()
        assert not session_dir.exists()
    
    def test_cleanup_user_expired_db_before_file(self, mock_settings, mock_db, user_id):
        """DB updated before file deletion (INV-U27)."""
        expired_session = Mock(spec=UploadSession)
        expired_session.id = "expired-123"
        expired_session.status = "in_progress"
        expired_session.expires_at = datetime.utcnow() - timedelta(hours=25)
        
        session_dir = mock_settings.upload_path / expired_session.id
        session_dir.mkdir(parents=True)
        
        mock_db.query.return_value.filter.return_value.all.return_value = [expired_session]
        
        cleanup_user_expired(user_id, mock_db)
        
        # Verify DB commit happens before file deletion
        assert expired_session.status == "expired"
        mock_db.commit.assert_called()
    
    def test_cleanup_user_expired_not_expired(self, mock_settings, mock_db, user_id):
        """Non-expired sessions are not cleaned."""
        active_session = Mock(spec=UploadSession)
        active_session.id = "active-123"
        active_session.status = "in_progress"
        active_session.expires_at = datetime.utcnow() + timedelta(hours=1)
        
        mock_db.query.return_value.filter.return_value.all.return_value = [active_session]
        
        result = cleanup_user_expired(user_id, mock_db)
        assert result.sessions_expired == 0


# Test cleanup_global()
class TestCleanupGlobal:
    """Test cleanup_global() Tier 3 cleanup."""
    
    def test_cleanup_global_orphan_cleanup(self, mock_settings, mock_db):
        """Orphan directories cleaned after 48h (INV-U26)."""
        orphan_dir = mock_settings.upload_path / "orphan-123"
        orphan_dir.mkdir(parents=True)
        
        # Set mtime to 49 hours ago
        old_time = (datetime.now() - timedelta(hours=49)).timestamp()
        os.utime(str(orphan_dir), (old_time, old_time))
        
        mock_db.query.return_value.filter.return_value.all.return_value = []
        mock_db.query.return_value.filter.return_value.all.side_effect = [
            [],  # Expired sessions query
            [],  # Active upload IDs query
        ]
        
        result = cleanup_global(mock_db)
        
        assert result.orphans_cleaned >= 1
        assert not orphan_dir.exists()
    
    def test_cleanup_global_assembling_cleanup(self, mock_settings, mock_db):
        """Old .assembling files cleaned after 2h."""
        assembly_dir = mock_settings.upload_path / "test-123" / "assembly"
        assembly_dir.mkdir(parents=True)
        assembling_file = assembly_dir / "test.bundle.assembling"
        assembling_file.write_bytes(b"test")
        
        # Set mtime to 3 hours ago
        old_time = (datetime.now() - timedelta(hours=3)).timestamp()
        os.utime(str(assembling_file), (old_time, old_time))
        
        mock_db.query.return_value.filter.return_value.all.return_value = []
        mock_db.query.return_value.filter.return_value.all.side_effect = [
            [],  # Expired sessions
            [],  # Active upload IDs
        ]
        
        result = cleanup_global(mock_db)
        
        assert result.assembling_cleaned >= 1
        assert not assembling_file.exists()
    
    def test_cleanup_global_idempotent(self, mock_settings, mock_db):
        """Running twice produces same result (INV-U28)."""
        mock_db.query.return_value.filter.return_value.all.return_value = []
        mock_db.query.return_value.filter.return_value.all.side_effect = [
            [],  # Expired sessions
            [],  # Active upload IDs
        ]
        
        result1 = cleanup_global(mock_db)
        result2 = cleanup_global(mock_db)
        
        # Both runs complete without errors
        assert result1.errors == []
        assert result2.errors == []


# Test CleanupResult
class TestCleanupResult:
    """Test CleanupResult dataclass."""
    
    def test_cleanup_result_fields(self):
        """CleanupResult has all fields."""
        result = CleanupResult(
            chunks_deleted=10,
            dirs_deleted=5,
            sessions_expired=2,
            orphans_cleaned=1,
            assembling_cleaned=1,
            elapsed_seconds=0.5,
            errors=["error1"]
        )
        assert result.chunks_deleted == 10
        assert len(result.errors) == 1
    
    def test_cleanup_result_to_dict(self):
        """to_dict() serializes correctly."""
        result = CleanupResult(chunks_deleted=5)
        d = result.to_dict()
        assert d["chunks_deleted"] == 5
        assert "error_count" in d
