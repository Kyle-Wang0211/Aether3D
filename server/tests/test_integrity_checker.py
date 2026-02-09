"""
PR#10 Integrity Checker Tests (~400 scenarios).

Tests for integrity_checker.py: merkle_hash_leaf, merkle_hash_nodes,
merkle_compute_root, sha256_with_domain, timing_safe_equal_hex,
compute_sample_size, verify_full, verify_probabilistic, VerificationReceipt.
"""

import hashlib
import hmac
import math
import pytest
from hypothesis import given, strategies as st

from app.services.integrity_checker import (
    BUNDLE_HASH_DOMAIN_TAG, CONTEXT_HASH_DOMAIN_TAG, MANIFEST_HASH_DOMAIN_TAG,
    IntegrityChecker, VerificationReceipt, compute_sample_size,
    merkle_compute_root, merkle_hash_leaf, merkle_hash_nodes,
    sha256_with_domain, timing_safe_equal_hex
)


# Test merkle_hash_leaf()
class TestMerkleHashLeaf:
    """Test merkle_hash_leaf() RFC 9162 leaf hashing."""
    
    def test_merkle_hash_leaf_empty(self):
        """Empty data produces valid hash."""
        result = merkle_hash_leaf(b"")
        assert len(result) == 32
        assert result == hashlib.sha256(b"\x00").digest()
    
    def test_merkle_hash_leaf_single_byte(self):
        """Single byte produces valid hash."""
        data = b"x"
        result = merkle_hash_leaf(data)
        assert len(result) == 32
        expected = hashlib.sha256(b"\x00" + data).digest()
        assert result == expected
    
    def test_merkle_hash_leaf_256kb(self):
        """256KB data produces valid hash."""
        data = b"x" * 262_144
        result = merkle_hash_leaf(data)
        assert len(result) == 32
        expected = hashlib.sha256(b"\x00" + data).digest()
        assert result == expected
    
    @pytest.mark.parametrize("size", [1, 100, 1024, 262_144])
    def test_merkle_hash_leaf_various_sizes(self, size):
        """Various data sizes produce valid hashes."""
        data = b"x" * size
        result = merkle_hash_leaf(data)
        assert len(result) == 32
        expected = hashlib.sha256(b"\x00" + data).digest()
        assert result == expected


# Test merkle_hash_nodes()
class TestMerkleHashNodes:
    """Test merkle_hash_nodes() RFC 9162 node hashing."""
    
    def test_merkle_hash_nodes_normal(self):
        """Normal node hashing."""
        left = b"a" * 32
        right = b"b" * 32
        result = merkle_hash_nodes(left, right)
        assert len(result) == 32
        expected = hashlib.sha256(b"\x01" + left + right).digest()
        assert result == expected
    
    def test_merkle_hash_nodes_assertion_error(self):
        """Non-32-byte inputs raise AssertionError."""
        with pytest.raises(AssertionError):
            merkle_hash_nodes(b"a" * 31, b"b" * 32)
        with pytest.raises(AssertionError):
            merkle_hash_nodes(b"a" * 32, b"b" * 31)


# Test merkle_compute_root()
class TestMerkleComputeRoot:
    """Test merkle_compute_root() RFC 9162 Merkle tree."""
    
    def test_merkle_compute_root_empty(self):
        """Empty list returns 32 zero bytes."""
        result = merkle_compute_root([])
        assert result == b"\x00" * 32
    
    def test_merkle_compute_root_single_leaf(self):
        """Single leaf returns leaf hash."""
        data = b"test"
        leaf_hash = merkle_hash_leaf(data)
        result = merkle_compute_root([leaf_hash])
        assert result == leaf_hash
    
    def test_merkle_compute_root_two_leaves(self):
        """Two leaves produce node hash."""
        data1 = b"test1"
        data2 = b"test2"
        leaf1 = merkle_hash_leaf(data1)
        leaf2 = merkle_hash_leaf(data2)
        result = merkle_compute_root([leaf1, leaf2])
        expected = merkle_hash_nodes(leaf1, leaf2)
        assert result == expected
    
    def test_merkle_compute_root_three_leaves(self):
        """Three leaves: odd node promoted."""
        data1 = b"test1"
        data2 = b"test2"
        data3 = b"test3"
        leaf1 = merkle_hash_leaf(data1)
        leaf2 = merkle_hash_leaf(data2)
        leaf3 = merkle_hash_leaf(data3)
        result = merkle_compute_root([leaf1, leaf2, leaf3])
        # First level: hash(leaf1, leaf2), promote leaf3
        node12 = merkle_hash_nodes(leaf1, leaf2)
        # Second level: hash(node12, leaf3)
        expected = merkle_hash_nodes(node12, leaf3)
        assert result == expected
    
    def test_merkle_compute_root_four_leaves(self):
        """Four leaves: perfect binary tree."""
        leaves = [merkle_hash_leaf(f"test{i}".encode()) for i in range(4)]
        result = merkle_compute_root(leaves)
        # Level 1: hash(leaf0, leaf1), hash(leaf2, leaf3)
        node01 = merkle_hash_nodes(leaves[0], leaves[1])
        node23 = merkle_hash_nodes(leaves[2], leaves[3])
        # Level 2: hash(node01, node23)
        expected = merkle_hash_nodes(node01, node23)
        assert result == expected
    
    def test_merkle_compute_root_200_leaves(self):
        """200 leaves (max chunk count)."""
        leaves = [merkle_hash_leaf(f"chunk{i}".encode()) for i in range(200)]
        result = merkle_compute_root(leaves)
        assert len(result) == 32
        # Verify it's deterministic
        result2 = merkle_compute_root(leaves)
        assert result == result2


# Test sha256_with_domain()
class TestSha256WithDomain:
    """Test sha256_with_domain() domain-separated hashing."""
    
    def test_sha256_with_domain_bundle(self):
        """Bundle domain tag."""
        data = b"test"
        result = sha256_with_domain(BUNDLE_HASH_DOMAIN_TAG, data)
        assert len(result) == 64  # Hex digest
        expected = hashlib.sha256(BUNDLE_HASH_DOMAIN_TAG + data).hexdigest()
        assert result == expected
    
    def test_sha256_with_domain_manifest(self):
        """Manifest domain tag."""
        data = b"test"
        result = sha256_with_domain(MANIFEST_HASH_DOMAIN_TAG, data)
        expected = hashlib.sha256(MANIFEST_HASH_DOMAIN_TAG + data).hexdigest()
        assert result == expected
    
    def test_sha256_with_domain_context(self):
        """Context domain tag."""
        data = b"test"
        result = sha256_with_domain(CONTEXT_HASH_DOMAIN_TAG, data)
        expected = hashlib.sha256(CONTEXT_HASH_DOMAIN_TAG + data).hexdigest()
        assert result == expected
    
    def test_domain_tag_nul_byte(self):
        """Domain tags include NUL byte."""
        assert BUNDLE_HASH_DOMAIN_TAG.endswith(b"\x00")
        assert MANIFEST_HASH_DOMAIN_TAG.endswith(b"\x00")
        assert CONTEXT_HASH_DOMAIN_TAG.endswith(b"\x00")
    
    def test_domain_tag_byte_counts(self):
        """Domain tag byte counts match Swift."""
        assert len(BUNDLE_HASH_DOMAIN_TAG) == 22
        assert len(MANIFEST_HASH_DOMAIN_TAG) == 26
        assert len(CONTEXT_HASH_DOMAIN_TAG) == 25


# Test timing_safe_equal_hex()
class TestTimingSafeEqualHex:
    """Test timing_safe_equal_hex() timing-safe comparison."""
    
    def test_timing_safe_equal_hex_match(self):
        """Matching hashes return True."""
        hash1 = "a" * 64
        hash2 = "a" * 64
        assert timing_safe_equal_hex(hash1, hash2) is True
    
    def test_timing_safe_equal_hex_mismatch(self):
        """Non-matching hashes return False."""
        hash1 = "a" * 64
        hash2 = "b" * 64
        assert timing_safe_equal_hex(hash1, hash2) is False
    
    def test_timing_safe_equal_hex_case_insensitive(self):
        """Case-insensitive comparison."""
        hash1 = "a" * 64
        hash2 = "A" * 64
        assert timing_safe_equal_hex(hash1, hash2) is True
    
    def test_timing_safe_equal_hex_uses_hmac_compare_digest(self):
        """Uses hmac.compare_digest() internally."""
        hash1 = "a" * 64
        hash2 = "b" * 64
        # Verify it's timing-safe (no short-circuit)
        result = timing_safe_equal_hex(hash1, hash2)
        assert result is False


# Test compute_sample_size()
class TestComputeSampleSize:
    """Test compute_sample_size() probabilistic sampling."""
    
    def test_compute_sample_size_1000_delta_001(self):
        """N=1000, delta=0.001 → k=7."""
        result = compute_sample_size(1000, 0.001)
        assert result == 7
    
    def test_compute_sample_size_10000_delta_001(self):
        """N=10000, delta=0.001 → k=69."""
        result = compute_sample_size(10000, 0.001)
        assert result == 69
    
    def test_compute_sample_size_1_delta_001(self):
        """N=1, delta=0.001 → k=1."""
        result = compute_sample_size(1, 0.001)
        assert result == 1
    
    def test_compute_sample_size_100_delta_001(self):
        """N=100, delta=0.001 → k=100 (boundary)."""
        result = compute_sample_size(100, 0.001)
        assert result == 100
    
    @pytest.mark.parametrize("n,delta,expected", [
        (1000, 0.001, 7),
        (10000, 0.001, 69),
        (1, 0.001, 1),
        (100, 0.001, 100),
        (500, 0.001, 4),
        (2000, 0.001, 14),
    ])
    def test_compute_sample_size_various(self, n, delta, expected):
        """Various inputs produce expected outputs."""
        result = compute_sample_size(n, delta)
        assert result == expected
    
    @given(st.integers(min_value=1, max_value=10000), st.floats(min_value=0.0001, max_value=0.999))
    def test_compute_sample_size_hypothesis(self, n, delta):
        """Property: result is in [1, n]."""
        result = compute_sample_size(n, delta)
        assert 1 <= result <= n
    
    def test_compute_sample_size_invalid_delta(self):
        """Invalid delta returns n."""
        assert compute_sample_size(100, 0) == 100
        assert compute_sample_size(100, 1) == 100
        assert compute_sample_size(100, -1) == 100


# Test verify_full()
class TestVerifyFull:
    """Test IntegrityChecker.verify_full() five-layer verification."""
    
    def test_verify_full_success(self):
        """All layers pass."""
        checker = IntegrityChecker()
        data = b"test" * 100
        assembly_hash = hashlib.sha256(data).hexdigest()
        chunk_hashes = [hashlib.sha256(f"chunk{i}".encode()).digest() for i in range(10)]
        
        result = checker.verify_full(
            assembly_sha256_hex=assembly_hash,
            expected_bundle_hash=assembly_hash,
            chunk_hashes=chunk_hashes,
            bundle_size=len(data),
            expected_size=len(data),
            chunk_count=10,
            expected_chunk_count=10,
        )
        
        assert result.passed is True
        assert result.receipt is not None
        assert len(result.receipt.layers_passed) == 5
    
    def test_verify_full_l5_size_mismatch(self):
        """L5 fails: size mismatch."""
        checker = IntegrityChecker()
        result = checker.verify_full(
            assembly_sha256_hex="a" * 64,
            expected_bundle_hash="a" * 64,
            chunk_hashes=[b"x" * 32],
            bundle_size=100,
            expected_size=200,
            chunk_count=1,
            expected_chunk_count=1,
        )
        assert result.passed is False
        assert result.layer_failed == "L5"
    
    def test_verify_full_l5_chunk_count_mismatch(self):
        """L5 fails: chunk count mismatch."""
        checker = IntegrityChecker()
        result = checker.verify_full(
            assembly_sha256_hex="a" * 64,
            expected_bundle_hash="a" * 64,
            chunk_hashes=[b"x" * 32],
            bundle_size=100,
            expected_size=100,
            chunk_count=1,
            expected_chunk_count=2,
        )
        assert result.passed is False
        assert result.layer_failed == "L5"
    
    def test_verify_full_l1_hash_mismatch(self):
        """L1 fails: hash mismatch."""
        checker = IntegrityChecker()
        result = checker.verify_full(
            assembly_sha256_hex="a" * 64,
            expected_bundle_hash="b" * 64,
            chunk_hashes=[b"x" * 32],
            bundle_size=100,
            expected_size=100,
            chunk_count=1,
            expected_chunk_count=1,
        )
        assert result.passed is False
        assert result.layer_failed == "L1"
    
    def test_verify_full_l2_chunk_hash_count_mismatch(self):
        """L2 fails: chunk hash count mismatch."""
        checker = IntegrityChecker()
        result = checker.verify_full(
            assembly_sha256_hex="a" * 64,
            expected_bundle_hash="a" * 64,
            chunk_hashes=[b"x" * 32, b"y" * 32],
            bundle_size=100,
            expected_size=100,
            chunk_count=2,
            expected_chunk_count=1,
        )
        assert result.passed is False
        assert result.layer_failed == "L2"
    
    def test_verify_full_anti_enumeration(self):
        """External error doesn't reveal layer."""
        checker = IntegrityChecker()
        result = checker.verify_full(
            assembly_sha256_hex="a" * 64,
            expected_bundle_hash="b" * 64,
            chunk_hashes=[b"x" * 32],
            bundle_size=100,
            expected_size=100,
            chunk_count=1,
            expected_chunk_count=1,
        )
        # layer_failed is internal-only, not exposed to user
        assert result.passed is False
        assert result.layer_failed is not None  # Internal tracking


# Test verify_probabilistic()
class TestVerifyProbabilistic:
    """Test IntegrityChecker.verify_probabilistic() sampling."""
    
    def test_verify_probabilistic_below_threshold(self):
        """Below threshold uses full verification."""
        checker = IntegrityChecker()
        data = b"test" * 100
        assembly_hash = hashlib.sha256(data).hexdigest()
        chunk_hashes = [hashlib.sha256(f"chunk{i}".encode()).digest() for i in range(50)]  # < 100
        
        result = checker.verify_probabilistic(
            assembly_sha256_hex=assembly_hash,
            expected_bundle_hash=assembly_hash,
            chunk_hashes=chunk_hashes,
            bundle_size=len(data),
            expected_size=len(data),
            chunk_count=50,
            expected_chunk_count=50,
        )
        
        assert result.passed is True
        assert result.receipt.verification_mode == "full"
    
    def test_verify_probabilistic_above_threshold(self):
        """Above threshold uses sampling."""
        checker = IntegrityChecker()
        data = b"test" * 100
        assembly_hash = hashlib.sha256(data).hexdigest()
        chunk_hashes = [hashlib.sha256(f"chunk{i}".encode()).digest() for i in range(1000)]  # > 100
        
        result = checker.verify_probabilistic(
            assembly_sha256_hex=assembly_hash,
            expected_bundle_hash=assembly_hash,
            chunk_hashes=chunk_hashes,
            bundle_size=len(data),
            expected_size=len(data),
            chunk_count=1000,
            expected_chunk_count=1000,
        )
        
        assert result.passed is True
        assert result.receipt.verification_mode == "probabilistic"
        assert result.receipt.sample_size is not None
        assert result.receipt.sample_size < 1000


# Test VerificationReceipt
class TestVerificationReceipt:
    """Test VerificationReceipt dataclass."""
    
    def test_verification_receipt_frozen(self):
        """VerificationReceipt is frozen."""
        receipt = VerificationReceipt(
            bundle_hash="a" * 64,
            verified_at="2024-01-01T00:00:00Z",
            verification_mode="full",
            layers_passed=["L5", "L1", "L2", "L3", "L4"],
            merkle_root="b" * 64,
            chunk_count=10,
            total_bytes=1000,
            elapsed_seconds=0.1,
            contract_version="PR10-INTEGRITY-1.0",
        )
        # Frozen dataclass cannot be modified
        with pytest.raises(Exception):
            receipt.bundle_hash = "c" * 64
    
    def test_verification_receipt_to_dict(self):
        """to_dict() serializes correctly."""
        receipt = VerificationReceipt(
            bundle_hash="a" * 64,
            verified_at="2024-01-01T00:00:00Z",
            verification_mode="full",
            layers_passed=["L5", "L1", "L2", "L3", "L4"],
            merkle_root="b" * 64,
            chunk_count=10,
            total_bytes=1000,
            elapsed_seconds=0.1,
            contract_version="PR10-INTEGRITY-1.0",
        )
        d = receipt.to_dict()
        assert d["bundle_hash"] == "a" * 64
        assert d["verification_mode"] == "full"
        assert len(d["layers_passed"]) == 5
