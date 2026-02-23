#!/usr/bin/env python3
"""
BLAKE3 "abc" Reference Verification Script

This script computes BLAKE3-256("abc") using an independent reference implementation
to verify the correct digest value.

Usage:
    python3 scripts/verify_blake3_abc.py

Output:
    Prints the hex digest of BLAKE3-256("abc") computed by the reference implementation.
"""

import sys
import hashlib

def verify_blake3_abc():
    """Compute BLAKE3-256("abc") using reference implementation."""
    try:
        # Try using blake3 library (if available)
        try:
            import blake3
            test_input = b"abc"
            hash_obj = blake3.blake3(test_input)
            digest = hash_obj.digest(length=32)
            hex_digest = digest.hex()
            print(f"BLAKE3-256('abc') (blake3 library): {hex_digest}")
            print(f"DECISION: Reference implementation produces: {hex_digest}")
            print(f"Expected in test: 6437b8acd6da8a3f8c14a5f5877223b8348fc64e7e1e27bd65e032899e7e1d5c")
            if hex_digest == "6437b8acd6da8a3f8c14a5f5877223b8348fc64e7e1e27bd65e032899e7e1d5c":
                print("MATCH: Reference matches expected -> Our implementation is wrong")
            elif hex_digest == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85":
                print("MATCH: Reference matches Python output -> Expected value in test is WRONG")
                print("ACTION: Update test expected value to match reference")
            else:
                print("MISMATCH: Reference differs from both -> Need to investigate")
            return hex_digest
        except ImportError:
            print("ERROR: blake3 library not available. Install with: pip install blake3", file=sys.stderr)
            sys.exit(1)
        
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    verify_blake3_abc()
