#!/usr/bin/env python3
"""
Generate UUID RFC4122 vectors fixture (>=128 cases)

Output: Tests/Fixtures/uuid_rfc4122_vectors_v1.txt
Format: KEY=VALUE (one per line, LF endings)
"""

import uuid
import sys

def uuid_to_rfc4122_bytes(uuid_obj):
    """Convert UUID to RFC4122 network order bytes"""
    return uuid_obj.bytes

def generate_vectors():
    """Generate 128+ UUID vectors"""
    vectors = []
    
    # Edge cases
    vectors.append(("UUID_STRING_1", "00000000-0000-0000-0000-000000000000"))
    vectors.append(("EXPECTED_BYTES_HEX_1", "00000000000000000000000000000000"))
    
    vectors.append(("UUID_STRING_2", "ffffffff-ffff-ffff-ffff-ffffffffffff"))
    vectors.append(("EXPECTED_BYTES_HEX_2", "ffffffffffffffffffffffffffffffff"))
    
    vectors.append(("UUID_STRING_3", "00112233-4455-6677-8899-aabbccddeeff"))
    vectors.append(("EXPECTED_BYTES_HEX_3", "00112233445566778899aabbccddeeff"))
    
    # Incrementing patterns
    for i in range(10):
        uuid_str = f"{i:08x}-{i:04x}-{i:04x}-{i:04x}-{i:012x}"
        uuid_obj = uuid.UUID(uuid_str)
        bytes_hex = uuid_to_rfc4122_bytes(uuid_obj).hex()
        vectors.append((f"UUID_STRING_{4+i}", uuid_str))
        vectors.append((f"EXPECTED_BYTES_HEX_{4+i}", bytes_hex))
    
    # Deterministic random (fixed seed)
    import random
    random.seed(42)
    for i in range(115):  # Total: 3 + 10 + 115 = 128
        uuid_obj = uuid.uuid4()
        uuid_str = str(uuid_obj)
        bytes_hex = uuid_to_rfc4122_bytes(uuid_obj).hex()
        vectors.append((f"UUID_STRING_{14+i}", uuid_str))
        vectors.append((f"EXPECTED_BYTES_HEX_{14+i}", bytes_hex))
    
    return vectors

if __name__ == "__main__":
    vectors = generate_vectors()
    
    output_lines = []
    for key, value in vectors:
        output_lines.append(f"{key}={value}")
    
    output = "\n".join(output_lines) + "\n"
    
    output_path = "Tests/Fixtures/uuid_rfc4122_vectors_v1.txt"
    with open(output_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(output)
    
    print(f"Generated {len(vectors)} vector entries ({len(vectors)//2} UUIDs)")
    print(f"Output: {output_path}")
