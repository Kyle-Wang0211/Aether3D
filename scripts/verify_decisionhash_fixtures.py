#!/usr/bin/env python3
"""
verify_decisionhash_fixtures.py
PR1 v2.4 Addendum - Python Reference Verifier for DecisionHash Fixtures

Cross-language verification: Swift output == Python output
"""

import sys
import hashlib
import re

try:
    import blake3
except ImportError:
    print("ERROR: blake3 library not found. Install with: pip install blake3", file=sys.stderr)
    sys.exit(1)


def parse_fixture_header(line: str) -> tuple[int, str, int]:
    """Parse header line: # v=1 sha256=<hex> len=<decimal>"""
    if not line.startswith("#"):
        raise ValueError("Header must start with #")
    
    content = line[1:].strip()
    version = None
    sha256_hex = None
    length = None
    
    for part in content.split():
        if "=" in part:
            key, value = part.split("=", 1)
            if key == "v":
                version = int(value)
            elif key == "sha256":
                sha256_hex = value
                if len(value) != 64 or not all(c in "0123456789abcdefABCDEF" for c in value):
                    raise ValueError(f"sha256 must be 64 hex characters, got: {value}")
            elif key == "len":
                length = int(value)
    
    if version is None or sha256_hex is None or length is None:
        raise ValueError("Missing required fields: v, sha256, or len")
    
    return (version, sha256_hex.lower(), length)


def compute_sha256(data: bytes) -> str:
    """Compute SHA256 hash of data"""
    return hashlib.sha256(data).hexdigest()


def validate_fixture_header(filepath: str) -> None:
    """Validate fixture file header"""
    with open(filepath, "rb") as f:
        data = f.read()
    
    content = data.decode("utf-8")
    lines = content.split("\n")
    
    if not lines:
        raise ValueError("File is empty")
    
    header_line = lines[0]
    version, expected_sha256, expected_len = parse_fixture_header(header_line)
    
    # Reconstruct content without header
    content_lines = lines[1:]
    content_string = "\n".join(content_lines) + "\n"
    content_bytes = content_string.encode("utf-8")
    
    # Compute actual hash
    actual_sha256 = compute_sha256(content_bytes)
    actual_len = len(content_bytes)
    
    # Validate
    if actual_sha256 != expected_sha256:
        raise ValueError(
            f"Hash mismatch in {filepath}: expected {expected_sha256[:16]}..., "
            f"got {actual_sha256[:16]}..."
        )
    
    if actual_len != expected_len:
        raise ValueError(
            f"Length mismatch in {filepath}: expected {expected_len}, got {actual_len}"
        )


def verify_decisionhash_fixtures(filepath: str) -> int:
    """Verify DecisionHash fixtures against Python BLAKE3"""
    errors = 0
    
    # Validate header first
    try:
        validate_fixture_header(filepath)
    except Exception as e:
        print(f"ERROR: Header validation failed: {e}", file=sys.stderr)
        return 1
    
    # Read and parse fixtures
    with open(filepath, "r") as f:
        lines = f.readlines()
    
    # Skip header line
    content_lines = [line.rstrip("\n") for line in lines[1:] if line.strip() and not line.startswith("#")]
    
    case_id = None
    preimage_hex = None
    expected_hash_hex = None
    
    for line in content_lines:
        line = line.strip()
        if not line:
            continue
        
        # Parse lines like: CANONICAL_INPUT_HEX_1=... or EXPECTED_DECISION_HASH_HEX_1=...
        if line.startswith("CANONICAL_INPUT_HEX_"):
            # Extract case ID
            match = re.match(r"CANONICAL_INPUT_HEX_(\d+)=", line)
            if match:
                case_id = int(match.group(1))
                preimage_hex = line.split("=", 1)[1].strip()
        elif line.startswith("EXPECTED_DECISION_HASH_HEX_"):
            match = re.match(r"EXPECTED_DECISION_HASH_HEX_(\d+)=", line)
            if match:
                expected_case_id = int(match.group(1))
                expected_hash_hex = line.split("=", 1)[1].strip()
                
                # Verify this matches the case_id we're processing
                if expected_case_id == case_id and preimage_hex:
                    # Convert hex to bytes
                    try:
                        preimage_bytes = bytes.fromhex(preimage_hex)
                    except ValueError as e:
                        print(f"ERROR: Invalid hex in case {case_id}: {e}", file=sys.stderr)
                        errors += 1
                        continue
                    
                    # Compute BLAKE3-256 hash with domain tag
                    # DecisionHash uses: domain_tag + canonical_bytes
                    domain_tag = b"AETHER3D_DECISION_HASH_V1\0"
                    input_bytes = domain_tag + preimage_bytes
                    computed_hash = blake3.blake3(input_bytes).digest(length=32)
                    computed_hash_hex = computed_hash.hex()
                    
                    if computed_hash_hex != expected_hash_hex:
                        # Find first differing byte
                        diff_index = None
                        for i, (e, c) in enumerate(zip(expected_hash_hex, computed_hash_hex)):
                            if e != c:
                                diff_index = i // 2  # Convert hex char index to byte index
                                break
                        
                        print(
                            f"ERROR: Case {case_id} hash mismatch:\n"
                            f"  Expected: {expected_hash_hex}\n"
                            f"  Computed: {computed_hash_hex}\n"
                            f"  First diff at byte {diff_index}",
                            file=sys.stderr
                        )
                        errors += 1
                    else:
                        print(f"✓ Case {case_id} verified")
                    
                    # Reset for next case
                    case_id = None
                    preimage_hex = None
                    expected_hash_hex = None
    
    return errors


def main():
    if len(sys.argv) != 2:
        print("Usage: verify_decisionhash_fixtures.py <fixture_file>", file=sys.stderr)
        sys.exit(1)
    
    filepath = sys.argv[1]
    errors = verify_decisionhash_fixtures(filepath)
    
    if errors > 0:
        print(f"\nFAILED: {errors} verification errors", file=sys.stderr)
        sys.exit(1)
    else:
        print("\n✓ All fixtures verified successfully")
        sys.exit(0)


if __name__ == "__main__":
    main()
