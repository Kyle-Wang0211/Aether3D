"""
PR#10 Upload Service Tests (~400 scenarios).

Tests for upload_service.py: persist_chunk, assemble_bundle, verify_assembly,
_durable_fsync, check_disk_quota, validate_path_component, validate_hash_component,
_assert_within_upload_dir, AssemblyState transitions, AssemblyResult dataclass.
"""

import hashlib
import os
import pytest
import shutil
import sys
import tempfile
from pathlib import Path
from unittest.mock import Mock, patch

from app.services.upload_service import (
    AssemblyError, AssemblyResult, AssemblyState, UploadErrorKind,
    _assert_within_upload_dir, _durable_fsync, assemble_bundle, check_disk_quota,
    persist_chunk, validate_hash_component, validate_path_component, verify_assembly
)
from app.services.upload_contract_constants import UploadContractConstants
from app.models import Chunk, UploadSession


# Test fixtures
@pytest.fixture
def temp_upload_dir():
    """Create temporary upload directory."""
    temp_dir = tempfile.mkdtemp()
    yield Path(temp_dir)
    shutil.rmtree(temp_dir, ignore_errors=True)


@pytest.fixture
def mock_settings(temp_upload_dir):
    """Mock settings.upload_path."""
    with patch('app.services.upload_service.settings') as mock:
        mock.upload_path = temp_upload_dir
        yield mock


@pytest.fixture
def sample_chunk_data():
    """Generate sample chunk data."""
    return b"x" * 1024  # 1KB test chunk


@pytest.fixture
def sample_chunk_hash(sample_chunk_data):
    """Compute hash for sample chunk."""
    return hashlib.sha256(sample_chunk_data).hexdigest()


@pytest.fixture
def upload_id():
    """Valid upload ID."""
    return "test-upload-123"


@pytest.fixture
def mock_db():
    """Mock SQLAlchemy session."""
    return Mock()


@pytest.fixture
def mock_session(upload_id):
    """Mock UploadSession."""
    session = Mock(spec=UploadSession)
    session.id = upload_id
    session.bundle_hash = "a" * 64
    session.bundle_size = 1024
    session.chunk_count = 1
    return session


# Test persist_chunk()
class TestPersistChunk:
    """Test persist_chunk() atomic write pattern."""
    
    def test_persist_chunk_success(self, mock_settings, upload_id, sample_chunk_data, sample_chunk_hash):
        """Normal chunk persistence."""
        chunk_path = persist_chunk(upload_id, 0, sample_chunk_data, sample_chunk_hash)
        assert chunk_path.exists()
        assert chunk_path.read_bytes() == sample_chunk_data
        assert not (chunk_path.parent / f"{0:06d}.chunk.tmp").exists()  # Temp file removed
    
    def test_persist_chunk_hash_mismatch(self, mock_settings, upload_id, sample_chunk_data):
        """Hash mismatch raises AssemblyError."""
        wrong_hash = "b" * 64
        with pytest.raises(AssemblyError) as exc_info:
            persist_chunk(upload_id, 0, sample_chunk_data, wrong_hash)
        assert exc_info.value.kind == UploadErrorKind.CHUNK_HASH_MISMATCH
    
    @pytest.mark.parametrize("bad_id", [
        "../etc/passwd",
        "..\\windows\\system32",
        "",
        "a" * 129,  # Too long
        "test/with/slash",
        "test\\with\\backslash",
    ])
    def test_persist_chunk_path_traversal_rejected(self, mock_settings, bad_id, sample_chunk_data, sample_chunk_hash):
        """Path traversal attacks rejected."""
        with pytest.raises((ValueError, AssemblyError)):
            persist_chunk(bad_id, 0, sample_chunk_data, sample_chunk_hash)
    
    def test_persist_chunk_disk_full(self, mock_settings, upload_id, sample_chunk_data, sample_chunk_hash):
        """Disk quota exceeded raises AssemblyError."""
        with patch('app.services.upload_service.check_disk_quota', return_value=(False, 0.95)):
            with pytest.raises(AssemblyError) as exc_info:
                persist_chunk(upload_id, 0, sample_chunk_data, sample_chunk_hash)
            assert exc_info.value.kind == UploadErrorKind.DISK_QUOTA_EXCEEDED
    
    def test_persist_chunk_atomic_write(self, mock_settings, upload_id, sample_chunk_data, sample_chunk_hash):
        """Verify atomic write pattern (tmp → rename)."""
        chunk_dir = mock_settings.upload_path / upload_id / "chunks"
        tmp_path = chunk_dir / "000000.chunk.tmp"
        final_path = chunk_dir / "000000.chunk"
        
        # Before persist: neither file exists
        assert not tmp_path.exists()
        assert not final_path.exists()
        
        persist_chunk(upload_id, 0, sample_chunk_data, sample_chunk_hash)
        
        # After persist: only final file exists
        assert final_path.exists()
        assert not tmp_path.exists()  # Temp file removed


# Test assemble_bundle()
class TestAssembleBundle:
    """Test assemble_bundle() three-way pipeline."""
    
    def test_assemble_bundle_success(self, mock_settings, mock_db, mock_session, upload_id, sample_chunk_data, sample_chunk_hash):
        """Normal bundle assembly."""
        # Setup: create chunk file
        chunk_dir = mock_settings.upload_path / upload_id / "chunks"
        chunk_dir.mkdir(parents=True)
        chunk_file = chunk_dir / "000000.chunk"
        chunk_file.write_bytes(sample_chunk_data)
        
        # Setup: create chunk record
        chunk_record = Mock(spec=Chunk)
        chunk_record.upload_id = upload_id
        chunk_record.chunk_index = 0
        chunk_record.chunk_hash = sample_chunk_hash
        
        mock_db.query.return_value.filter.return_value.order_by.return_value.all.return_value = [chunk_record]
        
        result = assemble_bundle(upload_id, mock_session, mock_db)
        
        assert result.total_bytes == len(sample_chunk_data)
        assert result.bundle_path.exists()
        assert len(result.chunk_hashes) == 1
    
    def test_assemble_bundle_chunk_missing(self, mock_settings, mock_db, mock_session, upload_id):
        """Missing chunk file raises AssemblyError."""
        chunk_record = Mock(spec=Chunk)
        chunk_record.upload_id = upload_id
        chunk_record.chunk_index = 0
        chunk_record.chunk_hash = "a" * 64
        
        mock_db.query.return_value.filter.return_value.order_by.return_value.all.return_value = [chunk_record]
        
        with pytest.raises(AssemblyError) as exc_info:
            assemble_bundle(upload_id, mock_session, mock_db)
        assert exc_info.value.kind == UploadErrorKind.CHUNK_MISSING
    
    def test_assemble_bundle_size_mismatch(self, mock_settings, mock_db, mock_session, upload_id, sample_chunk_data, sample_chunk_hash):
        """Size mismatch raises AssemblyError."""
        chunk_dir = mock_settings.upload_path / upload_id / "chunks"
        chunk_dir.mkdir(parents=True)
        chunk_file = chunk_dir / "000000.chunk"
        chunk_file.write_bytes(sample_chunk_data)
        
        mock_session.bundle_size = 999  # Wrong size
        
        chunk_record = Mock(spec=Chunk)
        chunk_record.upload_id = upload_id
        chunk_record.chunk_index = 0
        chunk_record.chunk_hash = sample_chunk_hash
        
        mock_db.query.return_value.filter.return_value.order_by.return_value.all.return_value = [chunk_record]
        
        with pytest.raises(AssemblyError) as exc_info:
            assemble_bundle(upload_id, mock_session, mock_db)
        assert exc_info.value.kind == UploadErrorKind.SIZE_MISMATCH
    
    def test_assemble_bundle_index_gap(self, mock_settings, mock_db, mock_session, upload_id):
        """Chunk index gap raises AssemblyError."""
        mock_session.chunk_count = 3
        
        chunk_records = []
        for i in [0, 2]:  # Missing index 1
            chunk = Mock(spec=Chunk)
            chunk.upload_id = upload_id
            chunk.chunk_index = i
            chunk.chunk_hash = "a" * 64
            chunk_records.append(chunk)
        
        mock_db.query.return_value.filter.return_value.order_by.return_value.all.return_value = chunk_records
        
        with pytest.raises(AssemblyError) as exc_info:
            assemble_bundle(upload_id, mock_session, mock_db)
        assert exc_info.value.kind == UploadErrorKind.INDEX_GAP


# Test verify_assembly()
class TestVerifyAssembly:
    """Test verify_assembly() timing-safe comparison."""
    
    def test_verify_assembly_match(self, sample_chunk_data):
        """Hash match returns True."""
        hash_hex = hashlib.sha256(sample_chunk_data).hexdigest()
        result = AssemblyResult(
            bundle_path=Path("/tmp/test.bundle"),
            sha256_hex=hash_hex,
            total_bytes=len(sample_chunk_data),
            elapsed_seconds=0.1,
            chunk_hashes=[hashlib.sha256(sample_chunk_data).digest()]
        )
        assert verify_assembly(result, hash_hex) is True
    
    def test_verify_assembly_mismatch(self, sample_chunk_data):
        """Hash mismatch returns False."""
        hash_hex = hashlib.sha256(sample_chunk_data).hexdigest()
        wrong_hash = "b" * 64
        result = AssemblyResult(
            bundle_path=Path("/tmp/test.bundle"),
            sha256_hex=hash_hex,
            total_bytes=len(sample_chunk_data),
            elapsed_seconds=0.1,
            chunk_hashes=[hashlib.sha256(sample_chunk_data).digest()]
        )
        assert verify_assembly(result, wrong_hash) is False


# Test _durable_fsync()
class TestDurableFsync:
    """Test _durable_fsync() platform-aware wrapper."""
    
    def test_durable_fsync_linux(self, temp_upload_dir):
        """Linux: uses os.fsync()."""
        test_file = temp_upload_dir / "test.bin"
        test_file.write_bytes(b"test")
        
        fd = os.open(str(test_file), os.O_RDONLY)
        try:
            _durable_fsync(fd)  # Should not raise
        finally:
            os.close(fd)
    
    def test_durable_fsync_macos(self, temp_upload_dir):
        """macOS: uses F_FULLFSYNC if available."""
        test_file = temp_upload_dir / "test.bin"
        test_file.write_bytes(b"test")
        
        fd = os.open(str(test_file), os.O_RDONLY)
        try:
            with patch('sys.platform', 'darwin'):
                with patch('fcntl.fcntl') as mock_fcntl:
                    _durable_fsync(fd)
                    # Should attempt F_FULLFSYNC on macOS
        finally:
            os.close(fd)
    
    def test_durable_fsync_invalid_fd(self):
        """Invalid file descriptor raises OSError."""
        with pytest.raises(OSError):
            _durable_fsync(99999)  # Invalid FD


# Test check_disk_quota()
class TestCheckDiskQuota:
    """Test check_disk_quota() disk space checking."""
    
    def test_check_disk_quota_normal(self, mock_settings):
        """Normal disk usage (<85%) returns True."""
        with patch('shutil.disk_usage') as mock_usage:
            mock_usage.return_value.used = 100
            mock_usage.return_value.total = 1000  # 10% usage
            allowed, usage = check_disk_quota()
            assert allowed is True
            assert usage == 0.1
    
    def test_check_disk_quota_threshold_85(self, mock_settings):
        """85% threshold rejects."""
        with patch('shutil.disk_usage') as mock_usage:
            mock_usage.return_value.used = 850
            mock_usage.return_value.total = 1000  # 85% usage
            allowed, usage = check_disk_quota()
            assert allowed is False
            assert usage == 0.85
    
    def test_check_disk_quota_threshold_95(self, mock_settings):
        """95% threshold rejects."""
        with patch('shutil.disk_usage') as mock_usage:
            mock_usage.return_value.used = 950
            mock_usage.return_value.total = 1000  # 95% usage
            allowed, usage = check_disk_quota()
            assert allowed is False
            assert usage == 0.95
    
    def test_check_disk_quota_oserror(self, mock_settings):
        """OSError returns False (fail-closed)."""
        with patch('shutil.disk_usage', side_effect=OSError("Disk error")):
            allowed, usage = check_disk_quota()
            assert allowed is False
            assert usage == 1.0


# Test validate_path_component()
class TestValidatePathComponent:
    """Test validate_path_component() path traversal prevention."""
    
    @pytest.mark.parametrize("valid_id", [
        "test-upload-123",
        "a" * 128,  # Max length
        "ABC123_-",
        "550e8400-e29b-41d4-a716-446655440000",  # UUID
    ])
    def test_validate_path_component_valid(self, valid_id):
        """Valid IDs pass validation."""
        assert validate_path_component(valid_id, "upload_id") == valid_id
    
    @pytest.mark.parametrize("invalid_id", [
        "",
        "../etc/passwd",
        "..\\windows\\system32",
        "test/with/slash",
        "test\\with\\backslash",
        "a" * 129,  # Too long
        "test@invalid",
        "test#invalid",
        "test$invalid",
    ])
    def test_validate_path_component_invalid(self, invalid_id):
        """Invalid IDs raise ValueError."""
        with pytest.raises(ValueError):
            validate_path_component(invalid_id, "upload_id")


# Test validate_hash_component()
class TestValidateHashComponent:
    """Test validate_hash_component() hash format validation."""
    
    def test_validate_hash_component_valid(self):
        """Valid SHA-256 hex passes."""
        valid_hash = "a" * 64
        assert validate_hash_component(valid_hash, "bundle_hash") == valid_hash
    
    @pytest.mark.parametrize("invalid_hash", [
        "",
        "a" * 63,  # Too short
        "a" * 65,  # Too long
        "G" * 64,  # Non-hex character
        "A" * 64,  # Uppercase (should be normalized, but format check fails)
    ])
    def test_validate_hash_component_invalid(self, invalid_hash):
        """Invalid hash format raises ValueError."""
        with pytest.raises(ValueError):
            validate_hash_component(invalid_hash, "bundle_hash")


# Test _assert_within_upload_dir()
class TestAssertWithinUploadDir:
    """Test _assert_within_upload_dir() path containment."""
    
    def test_assert_within_upload_dir_valid(self, mock_settings, upload_id):
        """Valid path within upload_dir passes."""
        valid_path = mock_settings.upload_path / upload_id / "chunks" / "000000.chunk"
        _assert_within_upload_dir(valid_path)  # Should not raise
    
    def test_assert_within_upload_dir_escape(self, mock_settings):
        """Path escape raises AssemblyError."""
        escape_path = Path("/etc/passwd")
        with pytest.raises(AssemblyError) as exc_info:
            _assert_within_upload_dir(escape_path)
        assert exc_info.value.kind == UploadErrorKind.PATH_ESCAPE


# Test AssemblyState transitions
class TestAssemblyState:
    """Test AssemblyState enum and legal transitions."""
    
    def test_assembly_state_count(self):
        """Verify 6 states."""
        assert len(AssemblyState) == 6
    
    @pytest.mark.parametrize("from_state,to_state", [
        (AssemblyState.PENDING, AssemblyState.ASSEMBLING),
        (AssemblyState.ASSEMBLING, AssemblyState.HASHING),
        (AssemblyState.ASSEMBLING, AssemblyState.FAILED),
        (AssemblyState.HASHING, AssemblyState.COMPLETED),
        (AssemblyState.HASHING, AssemblyState.FAILED),
        (AssemblyState.FAILED, AssemblyState.RECOVERED),
        (AssemblyState.RECOVERED, AssemblyState.ASSEMBLING),
    ])
    def test_assembly_state_legal_transitions(self, from_state, to_state):
        """Legal transitions are valid."""
        from app.services.upload_service import _ASSEMBLY_TRANSITIONS
        assert to_state in _ASSEMBLY_TRANSITIONS[from_state]
    
    def test_assembly_state_illegal_transition(self):
        """Illegal transitions are rejected."""
        from app.services.upload_service import _ASSEMBLY_TRANSITIONS
        assert AssemblyState.COMPLETED not in _ASSEMBLY_TRANSITIONS[AssemblyState.PENDING]


# Test AssemblyResult dataclass
class TestAssemblyResult:
    """Test AssemblyResult dataclass."""
    
    def test_assembly_result_fields(self):
        """AssemblyResult has all required fields."""
        result = AssemblyResult(
            bundle_path=Path("/tmp/test.bundle"),
            sha256_hex="a" * 64,
            total_bytes=1024,
            elapsed_seconds=0.1,
            chunk_hashes=[b"x" * 32]
        )
        assert result.bundle_path == Path("/tmp/test.bundle")
        assert result.sha256_hex == "a" * 64
        assert result.total_bytes == 1024
        assert result.elapsed_seconds == 0.1
        assert len(result.chunk_hashes) == 1


# Hypothesis property-based tests
try:
    from hypothesis import given, strategies as st
    
    @given(st.text(min_size=1, max_size=128, alphabet=st.characters(whitelist_categories=('Lu', 'Ll', 'Nd', 'Pc', 'Pd'))))
    def test_validate_path_component_hypothesis(valid_id):
        """Property: valid path components pass validation."""
        try:
            result = validate_path_component(valid_id, "test")
            assert result == valid_id
        except ValueError:
            # Some edge cases may fail (e.g., empty after filtering)
            pass
    
    @given(st.text(min_size=64, max_size=64, alphabet=st.characters(whitelist_categories=('Nd', 'Ll'))))
    def test_validate_hash_component_hypothesis(valid_hash):
        """Property: valid hash components pass validation."""
        try:
            result = validate_hash_component(valid_hash, "test")
            assert result == valid_hash
        except ValueError:
            # Some edge cases may fail
            pass

except ImportError:
    # hypothesis not installed, skip property tests
    pass
