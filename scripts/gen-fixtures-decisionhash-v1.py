#!/usr/bin/env python3
"""
Generate DecisionHash vectors fixture (>=128 cases)

Output: Tests/Fixtures/decision_hash_v1.txt
"""

import sys
import struct
import hashlib

try:
    import blake3
    HAS_BLAKE3 = True
except ImportError:
    HAS_BLAKE3 = False
    print("Warning: blake3 library not available", file=sys.stderr)

def blake3_256(data: bytes) -> str:
    """Compute BLAKE3-256 and return hex"""
    if HAS_BLAKE3:
        h = blake3.blake3(data)
        return h.hexdigest(length=32)
    else:
        return hashlib.sha256(data).hexdigest()

def generate_canonical_bytes(seed: int, flow_bucket_count: int, has_throttle: bool, has_reject_reason: bool, has_degradation_reason: bool):
    """Generate canonical bytes for DecisionHashInputBytesLayout_v1"""
    import random
    random.seed(seed)
    
    bytes_list = []
    
    # layoutVersion = 1
    bytes_list.append(1)
    
    # decisionSchemaVersion = 0x0001 (BE)
    bytes_list.extend([0x00, 0x01])
    
    # policyHash (UInt64 BE)
    policy_hash = random.randint(0, 2**64 - 1)
    bytes_list.extend(struct.pack(">Q", policy_hash))
    
    # sessionStableId (UInt64 BE)
    session_id = random.randint(0, 2**64 - 1)
    bytes_list.extend(struct.pack(">Q", session_id))
    
    # candidateStableId (UInt64 BE)
    candidate_id = random.randint(0, 2**64 - 1)
    bytes_list.extend(struct.pack(">Q", candidate_id))
    
    # classification (UInt8)
    classification = random.randint(0, 2)
    bytes_list.append(classification)
    
    # rejectReasonTag (UInt8)
    reject_tag = 1 if has_reject_reason else 0
    bytes_list.append(reject_tag)
    if has_reject_reason:
        bytes_list.append(random.randint(1, 4))
    
    # shedDecisionTag = 0 (absent)
    bytes_list.append(0)
    
    # shedReasonTag = 0 (absent)
    bytes_list.append(0)
    
    # degradationLevel (UInt8)
    degradation_level = random.randint(0, 3)
    bytes_list.append(degradation_level)
    
    # degradationReasonCodeTag (UInt8)
    deg_tag = 1 if has_degradation_reason else 0
    bytes_list.append(deg_tag)
    if has_degradation_reason:
        bytes_list.append(random.randint(1, 6))
    
    # valueScore (Int64 BE)
    value_score = random.randint(-2**63, 2**63 - 1)
    bytes_list.extend(struct.pack(">q", value_score))
    
    # flowBucketCount (UInt8)
    bytes_list.append(flow_bucket_count)
    
    # perFlowCounters ([UInt16] BE)
    for _ in range(flow_bucket_count):
        counter = random.randint(0, 65535)
        bytes_list.extend(struct.pack(">H", counter))
    
    # throttleStatsTag (UInt8)
    throttle_tag = 1 if has_throttle else 0
    bytes_list.append(throttle_tag)
    if has_throttle:
        window_start = random.randint(0, 2**64 - 1)
        bytes_list.extend(struct.pack(">Q", window_start))
        window_duration = random.randint(0, 2**32 - 1)
        bytes_list.extend(struct.pack(">I", window_duration))
        attempts = random.randint(0, 2**32 - 1)
        bytes_list.extend(struct.pack(">I", attempts))
    
    return bytes(bytes_list)

def compute_decision_hash(canonical_bytes: bytes) -> str:
    """Compute DecisionHash with domain tag"""
    domain_tag = b"AETHER3D_DECISION_HASH_V1\0"
    input_bytes = domain_tag + canonical_bytes
    return blake3_256(input_bytes)

def generate_vectors():
    """Generate 128+ DecisionHash vectors"""
    vectors = []
    
    # Vary flowBucketCount (1..8)
    # Vary presence tags combinations
    # Vary degradation levels
    
    seed = 42
    case_num = 1
    
    for flow_bucket_count in [1, 2, 4, 8]:
        for has_throttle in [False, True]:
            for has_reject_reason in [False, True]:
                for has_degradation_reason in [False, True]:
                    for degradation_level in [0, 1, 2, 3]:
                        canonical_bytes = generate_canonical_bytes(
                            seed, flow_bucket_count, has_throttle, 
                            has_reject_reason, has_degradation_reason
                        )
                        decision_hash = compute_decision_hash(canonical_bytes)
                        
                        vectors.append((f"CANONICAL_INPUT_HEX_{case_num}", canonical_bytes.hex()))
                        vectors.append((f"EXPECTED_DECISION_HASH_HEX_{case_num}", decision_hash))
                        
                        case_num += 1
                        seed += 1
                        
                        if case_num > 128:
                            break
                    if case_num > 128:
                        break
                if case_num > 128:
                    break
            if case_num > 128:
                break
        if case_num > 128:
            break
    
    return vectors

if __name__ == "__main__":
    vectors = generate_vectors()
    
    output_lines = []
    for key, value in vectors:
        output_lines.append(f"{key}={value}")
    
    output = "\n".join(output_lines) + "\n"
    
    output_path = "Tests/Fixtures/decision_hash_v1.txt"
    with open(output_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(output)
    
    print(f"Generated {len(vectors)} vector entries ({len(vectors)//2} test cases)")
    print(f"Output: {output_path}")
