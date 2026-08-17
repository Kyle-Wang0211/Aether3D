set(contract_header
    "${CMAKE_CURRENT_LIST_DIR}/../../official_pipeline/src/official_gpu_timestamp_diagnostics_v1.h")

if(NOT EXISTS "${contract_header}")
    message(FATAL_ERROR
        "GPU_TIMESTAMP_CONTRACT_RED: private schema-v1 POD contract is absent")
endif()

file(READ "${contract_header}" contract_text)
foreach(required IN ITEMS
        "AETHER_GPU_TIMESTAMP_STATUS_OFF_V1 = 0"
        "AETHER_GPU_TIMESTAMP_STATUS_ENABLED_V1 = 1"
        "AETHER_GPU_TIMESTAMP_STATUS_UNSUPPORTED_V1 = 2"
        "AETHER_GPU_TIMESTAMP_STATUS_RESOURCE_FAILED_V1 = 3"
        "AETHER_GPU_TIMESTAMP_STATUS_RESOLVE_FAILED_V1 = 4"
        "AETHER_GPU_TIMESTAMP_ENV_KEY_V1")
    string(FIND "${contract_text}" "${required}" required_at)
    if(required_at EQUAL -1)
        message(FATAL_ERROR
            "GPU_TIMESTAMP_CONTRACT_RED: missing required behavior: ${required}")
    endif()
endforeach()
