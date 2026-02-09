"""
PR#10 Upload Contract Constants Tests (~100 scenarios).

Meta-guardrail tests (PATCH-V2-N): scan all 5 new files for:
- No bare == comparisons on hash strings
- All 28 INV-U invariants present
- GATE markers >= 12
- SEAL FIX markers >= 12
- All 5 files have constitutional contract headers
- Compile-time assertions
"""

import ast
import re
from pathlib import Path

import pytest

from app.services.upload_contract_constants import UploadContractConstants


# Test compile-time assertions
class TestCompileTimeAssertions:
    """Test compile-time assertions in upload_contract_constants.py."""
    
    def test_invariant_count(self):
        """INVARIANT_COUNT == 28."""
        assert UploadContractConstants.INVARIANT_COUNT == 28
    
    def test_new_file_count(self):
        """NEW_FILE_COUNT == 5."""
        assert UploadContractConstants.NEW_FILE_COUNT == 5
    
    def test_gate_count(self):
        """GATE_COUNT >= 12."""
        assert UploadContractConstants.GATE_COUNT >= 12


# Meta-guardrail tests: scan source files
class TestMetaGuardrails:
    """Meta-guardrail tests (PATCH-V2-N)."""
    
    @pytest.fixture
    def service_files(self):
        """Get all 5 new service files."""
        base_path = Path(__file__).parent.parent / "app" / "services"
        return [
            base_path / "upload_service.py",
            base_path / "integrity_checker.py",
            base_path / "deduplicator.py",
            base_path / "cleanup_handler.py",
            base_path / "upload_contract_constants.py",
        ]
    
    def test_no_bare_hash_comparison(self, service_files):
        """No bare == comparisons on hash strings."""
        hash_pattern = re.compile(r'[a-zA-Z_][a-zA-Z0-9_]*\s*==\s*[a-zA-Z_][a-zA-Z0-9_]*')
        violations = []
        
        for file_path in service_files:
            if not file_path.exists():
                continue
            content = file_path.read_text()
            # Check for hash-related == comparisons (heuristic)
            lines = content.split('\n')
            for i, line in enumerate(lines, 1):
                if 'hash' in line.lower() and '==' in line and 'hmac.compare_digest' not in line:
                    # Skip comments and docstrings
                    if not line.strip().startswith('#') and not '"""' in line:
                        violations.append(f"{file_path.name}:{i}: {line.strip()}")
        
        # Allow some false positives, but flag obvious violations
        assert len(violations) == 0, f"Found potential bare hash comparisons: {violations}"
    
    def test_all_invariants_present(self, service_files):
        """All 28 INV-U invariants are present in code."""
        invariant_pattern = re.compile(r'INV-U(\d+)')
        found_invariants = set()
        
        for file_path in service_files:
            if not file_path.exists():
                continue
            content = file_path.read_text()
            matches = invariant_pattern.findall(content)
            found_invariants.update(int(m) for m in matches)
        
        expected = set(range(1, 29))  # INV-U1 to INV-U28
        missing = expected - found_invariants
        assert len(missing) == 0, f"Missing invariants: {missing}"
    
    def test_gate_markers_present(self, service_files):
        """GATE markers >= 12."""
        gate_pattern = re.compile(r'GATE[:\s]')
        gate_count = 0
        
        for file_path in service_files:
            if not file_path.exists():
                continue
            content = file_path.read_text()
            gate_count += len(gate_pattern.findall(content))
        
        assert gate_count >= 12, f"Found only {gate_count} GATE markers, expected >= 12"
    
    def test_seal_fix_markers_present(self, service_files):
        """SEAL FIX markers >= 12."""
        seal_pattern = re.compile(r'SEAL\s+FIX[:\s]')
        seal_count = 0
        
        for file_path in service_files:
            if not file_path.exists():
                continue
            content = file_path.read_text()
            seal_count += len(seal_pattern.findall(content))
        
        assert seal_count >= 12, f"Found only {seal_count} SEAL FIX markers, expected >= 12"
    
    def test_constitutional_contract_headers(self, service_files):
        """All 5 files have constitutional contract headers."""
        header_pattern = re.compile(r'CONSTITUTIONAL CONTRACT')
        missing_headers = []
        
        for file_path in service_files:
            if not file_path.exists():
                missing_headers.append(file_path.name)
                continue
            content = file_path.read_text()
            if not header_pattern.search(content):
                missing_headers.append(file_path.name)
        
        assert len(missing_headers) == 0, f"Files missing contract headers: {missing_headers}"


# Test constant values
class TestConstantValues:
    """Test constant value ranges."""
    
    def test_hash_stream_chunk_bytes(self):
        """HASH_STREAM_CHUNK_BYTES == 262144."""
        assert UploadContractConstants.HASH_STREAM_CHUNK_BYTES == 262_144
    
    def test_assembly_buffer_bytes(self):
        """ASSEMBLY_BUFFER_BYTES == 1048576."""
        assert UploadContractConstants.ASSEMBLY_BUFFER_BYTES == 1_048_576
    
    def test_disk_usage_reject_threshold(self):
        """DISK_USAGE_REJECT_THRESHOLD == 0.85."""
        assert UploadContractConstants.DISK_USAGE_REJECT_THRESHOLD == 0.85
    
    def test_disk_usage_emergency_threshold(self):
        """DISK_USAGE_EMERGENCY_THRESHOLD == 0.95."""
        assert UploadContractConstants.DISK_USAGE_EMERGENCY_THRESHOLD == 0.95
    
    def test_orphan_retention_hours(self):
        """ORPHAN_RETENTION_HOURS == 48."""
        assert UploadContractConstants.ORPHAN_RETENTION_HOURS == 48
    
    def test_global_cleanup_interval_seconds(self):
        """GLOBAL_CLEANUP_INTERVAL_SECONDS == 3600."""
        assert UploadContractConstants.GLOBAL_CLEANUP_INTERVAL_SECONDS == 3600
    
    def test_assembling_max_age_hours(self):
        """ASSEMBLING_MAX_AGE_HOURS == 2."""
        assert UploadContractConstants.ASSEMBLING_MAX_AGE_HOURS == 2
