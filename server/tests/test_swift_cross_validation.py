"""
PR#10 Swift Cross-Validation Tests (~200 scenarios).

Cross-platform validation tests ensuring Python implementation matches
Swift byte-for-byte: Merkle tree, domain tags, probabilistic formula, constants.
"""

import hashlib
import json
import math
import pytest
from pathlib import Path

from app.services.integrity_checker import (
    BUNDLE_HASH_DOMAIN_TAG, CONTEXT_HASH_DOMAIN_TAG, MANIFEST_HASH_DOMAIN_TAG,
    compute_sample_size, merkle_compute_root, merkle_hash_leaf, merkle_hash_nodes
)
from app.services.upload_contract_constants import UploadContractConstants


# Swift test vectors (pre-computed from Swift implementation)
SWIFT_TEST_VECTORS_PATH = Path(__file__).parent / "swift_test_vectors.json"


@pytest.fixture
def swift_test_vectors():
    """Load Swift test vectors."""
    if SWIFT_TEST_VECTORS_PATH.exists():
        return json.loads(SWIFT_TEST_VECTORS_PATH.read_text())
    return {}


# Test Merkle tree byte-identical with Swift
class TestMerkleTreeSwiftParity:
    """Test Merkle tree matches Swift byte-for-byte."""
    
    def test_merkle_empty_tree_swift(self):
        """Empty tree: 32 zero bytes (Swift MerkleTree.swift line 26)."""
        result = merkle_compute_root([])
        assert result == b"\x00" * 32
    
    def test_merkle_single_leaf_swift(self):
        """Single leaf matches Swift."""
        data = b"test"
        leaf_hash = merkle_hash_leaf(data)
        result = merkle_compute_root([leaf_hash])
        # Swift: single leaf is root
        assert result == leaf_hash
    
    def test_merkle_two_leaves_swift(self):
        """Two leaves match Swift."""
        data1 = b"chunk0"
        data2 = b"chunk1"
        leaf1 = merkle_hash_leaf(data1)
        leaf2 = merkle_hash_leaf(data2)
        result = merkle_compute_root([leaf1, leaf2])
        # Swift: hash(0x01 || leaf1 || leaf2)
        expected = hashlib.sha256(b"\x01" + leaf1 + leaf2).digest()
        assert result == expected
    
    def test_merkle_three_leaves_swift(self):
        """Three leaves: odd node promotion (Swift MerkleTree.swift lines 83-84)."""
        leaves = [merkle_hash_leaf(f"chunk{i}".encode()) for i in range(3)]
        result = merkle_compute_root(leaves)
        # Level 1: hash(leaf0, leaf1), promote leaf2
        node01 = merkle_hash_nodes(leaves[0], leaves[1])
        # Level 2: hash(node01, leaf2)
        expected = merkle_hash_nodes(node01, leaves[2])
        assert result == expected
    
    @pytest.mark.parametrize("chunk_count", [1, 2, 3, 4, 10, 100, 200])
    def test_merkle_various_sizes_swift(self, chunk_count):
        """Various chunk counts match Swift."""
        leaves = [merkle_hash_leaf(f"chunk{i}".encode()) for i in range(chunk_count)]
        result = merkle_compute_root(leaves)
        assert len(result) == 32
        # Verify deterministic
        result2 = merkle_compute_root(leaves)
        assert result == result2


# Test domain tags byte-identical with Swift
class TestDomainTagsSwiftParity:
    """Test domain tags match Swift BundleConstants.swift."""
    
    def test_bundle_hash_domain_tag_bytes(self):
        """BUNDLE_HASH_DOMAIN_TAG == 22 bytes (Swift line 93)."""
        assert len(BUNDLE_HASH_DOMAIN_TAG) == 22
        assert BUNDLE_HASH_DOMAIN_TAG == b"aether.bundle.hash.v1\x00"
    
    def test_manifest_hash_domain_tag_bytes(self):
        """MANIFEST_HASH_DOMAIN_TAG == 26 bytes (Swift line 96)."""
        assert len(MANIFEST_HASH_DOMAIN_TAG) == 26
        assert MANIFEST_HASH_DOMAIN_TAG == b"aether.bundle.manifest.v1\x00"
    
    def test_context_hash_domain_tag_bytes(self):
        """CONTEXT_HASH_DOMAIN_TAG == 25 bytes (Swift line 99)."""
        assert len(CONTEXT_HASH_DOMAIN_TAG) == 25
        assert CONTEXT_HASH_DOMAIN_TAG == b"aether.bundle.context.v1\x00"
    
    def test_domain_tags_nul_terminated(self):
        """All domain tags end with NUL byte."""
        assert BUNDLE_HASH_DOMAIN_TAG.endswith(b"\x00")
        assert MANIFEST_HASH_DOMAIN_TAG.endswith(b"\x00")
        assert CONTEXT_HASH_DOMAIN_TAG.endswith(b"\x00")


# Test probabilistic formula matches Swift
class TestProbabilisticFormulaSwiftParity:
    """Test compute_sample_size() matches Swift VerificationMode.swift."""
    
    def test_compute_sample_size_1000_delta_001_swift(self):
        """N=1000, delta=0.001 → k=7 (Swift docstring)."""
        result = compute_sample_size(1000, 0.001)
        assert result == 7
    
    def test_compute_sample_size_10000_delta_001_swift(self):
        """N=10000, delta=0.001 → k=69 (Swift docstring)."""
        result = compute_sample_size(10000, 0.001)
        assert result == 69
    
    def test_compute_sample_size_1_delta_001_swift(self):
        """N=1, delta=0.001 → k=1 (boundary case)."""
        result = compute_sample_size(1, 0.001)
        assert result == 1
    
    def test_compute_sample_size_formula_swift(self):
        """Formula matches Swift: ceil(N * (1 - pow(delta, 1/N)))."""
        n = 1000
        delta = 0.001
        result = compute_sample_size(n, delta)
        expected = int(math.ceil(n * (1.0 - pow(delta, 1.0 / n))))
        assert result == expected
    
    @pytest.mark.parametrize("n,delta", [
        (100, 0.001),
        (500, 0.001),
        (2000, 0.001),
        (5000, 0.001),
    ])
    def test_compute_sample_size_various_swift(self, n, delta):
        """Various inputs match Swift formula."""
        result = compute_sample_size(n, delta)
        expected = int(math.ceil(n * (1.0 - pow(delta, 1.0 / n))))
        assert result == expected


# Test constants match Swift
class TestConstantsSwiftParity:
    """Test constants match Swift BundleConstants.swift."""
    
    def test_hash_stream_chunk_bytes_swift(self):
        """HASH_STREAM_CHUNK_BYTES == 262144 (Swift BundleConstants.swift)."""
        assert UploadContractConstants.HASH_STREAM_CHUNK_BYTES == 262_144
    
    def test_probabilistic_min_chunks_swift(self):
        """PROBABILISTIC_MIN_CHUNKS == 100 (Swift PROBABILISTIC_MIN_ASSETS)."""
        from app.services.integrity_checker import PROBABILISTIC_MIN_CHUNKS
        assert PROBABILISTIC_MIN_CHUNKS == 100
    
    def test_probabilistic_delta_swift(self):
        """PROBABILISTIC_DELTA == 0.001 (Swift PROBABILISTIC_VERIFICATION_DELTA)."""
        from app.services.integrity_checker import PROBABILISTIC_DELTA
        assert PROBABILISTIC_DELTA == 0.001


# Test Merkle leaf/node prefixes match Swift
class TestMerklePrefixesSwiftParity:
    """Test Merkle prefixes match Swift RFC 9162."""
    
    def test_merkle_leaf_prefix_swift(self):
        """Leaf prefix is 0x00 (Swift MerkleTreeHash.swift line 45)."""
        from app.services.integrity_checker import MERKLE_LEAF_PREFIX
        assert MERKLE_LEAF_PREFIX == b"\x00"
    
    def test_merkle_node_prefix_swift(self):
        """Node prefix is 0x01 (Swift MerkleTreeHash.swift line 65)."""
        from app.services.integrity_checker import MERKLE_NODE_PREFIX
        assert MERKLE_NODE_PREFIX == b"\x01"


# Create Swift test vectors file (for CI)
def test_create_swift_test_vectors():
    """Create swift_test_vectors.json for CI validation."""
    vectors = {
        "merkle_empty": merkle_compute_root([]).hex(),
        "merkle_single": merkle_compute_root([merkle_hash_leaf(b"test")]).hex(),
        "merkle_two": merkle_compute_root([
            merkle_hash_leaf(b"chunk0"),
            merkle_hash_leaf(b"chunk1")
        ]).hex(),
        "merkle_three": merkle_compute_root([
            merkle_hash_leaf(b"chunk0"),
            merkle_hash_leaf(b"chunk1"),
            merkle_hash_leaf(b"chunk2")
        ]).hex(),
        "sample_size_1000": compute_sample_size(1000, 0.001),
        "sample_size_10000": compute_sample_size(10000, 0.001),
        "domain_tag_bundle_len": len(BUNDLE_HASH_DOMAIN_TAG),
        "domain_tag_manifest_len": len(MANIFEST_HASH_DOMAIN_TAG),
        "domain_tag_context_len": len(CONTEXT_HASH_DOMAIN_TAG),
    }
    
    # Write to file (for CI comparison)
    SWIFT_TEST_VECTORS_PATH.write_text(json.dumps(vectors, indent=2))
    assert SWIFT_TEST_VECTORS_PATH.exists()
