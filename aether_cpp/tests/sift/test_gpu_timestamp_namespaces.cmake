if(NOT DEFINED CXX OR NOT DEFINED SOURCE OR NOT DEFINED INCLUDE_DIR OR
   NOT DEFINED WEAK_STUB_SOURCE OR
   NOT DEFINED WEAK_ABSENCE_SOURCE OR NOT DEFINED WEAK_ABSENCE_EXE OR
   NOT DEFINED OFFICIAL_ARTIFACT OR NOT DEFINED SELFTEST_ARTIFACT)
    message(FATAL_ERROR "namespace contract arguments are incomplete")
endif()

function(expect_compile_failure label)
    execute_process(
        COMMAND "${CXX}" -std=c++20 -fsyntax-only "-I${INCLUDE_DIR}"
                ${ARGN} "${SOURCE}"
        RESULT_VARIABLE rc
        OUTPUT_VARIABLE out
        ERROR_VARIABLE err)
    if(rc EQUAL 0)
        message(FATAL_ERROR "${label}: compile unexpectedly succeeded")
    endif()
    if(NOT err MATCHES "define exactly one selector")
        message(FATAL_ERROR "${label}: wrong compiler failure: ${err}")
    endif()
endfunction()

expect_compile_failure(neither)
expect_compile_failure(
    both
    -DAETHER_GPU_TIMESTAMPS_ENV_OFFICIAL=1
    -DAETHER_GPU_TIMESTAMPS_ENV_SELFTEST=1)

execute_process(COMMAND strings "${OFFICIAL_ARTIFACT}"
                RESULT_VARIABLE official_rc OUTPUT_VARIABLE official_strings)
execute_process(COMMAND strings "${SELFTEST_ARTIFACT}"
                RESULT_VARIABLE selftest_rc OUTPUT_VARIABLE selftest_strings)
if(NOT official_rc EQUAL 0 OR NOT selftest_rc EQUAL 0)
    message(FATAL_ERROR "strings failed")
endif()

string(REGEX MATCH "(^|\n)OFFICIAL_AETHER_GPU_TIMESTAMPS(\n|$)"
       official_has_official "${official_strings}")
string(REGEX MATCH "(^|\n)AETHER_GPU_TIMESTAMPS(\n|$)"
       official_has_self "${official_strings}")
string(REGEX MATCH "(^|\n)AETHER_GPU_TIMESTAMPS(\n|$)"
       selftest_has_self "${selftest_strings}")
string(REGEX MATCH "(^|\n)OFFICIAL_AETHER_GPU_TIMESTAMPS(\n|$)"
       selftest_has_official "${selftest_strings}")
if(official_has_official STREQUAL "" OR NOT official_has_self STREQUAL "")
    message(FATAL_ERROR "official artifact namespace leakage")
endif()
if(selftest_has_self STREQUAL "" OR NOT selftest_has_official STREQUAL "")
    message(FATAL_ERROR "selftest artifact namespace leakage")
endif()

execute_process(
    COMMAND "${CXX}" -std=c++20 "-I${INCLUDE_DIR}"
            -DAETHER_GPU_TIMESTAMPS_ENV_OFFICIAL=1
            "${WEAK_ABSENCE_SOURCE}" "${WEAK_STUB_SOURCE}"
            -o "${WEAK_ABSENCE_EXE}"
    RESULT_VARIABLE weak_link_rc
    OUTPUT_VARIABLE weak_link_out
    ERROR_VARIABLE weak_link_err)
if(NOT weak_link_rc EQUAL 0)
    message(FATAL_ERROR
        "CPU-only weak-absence executable failed to link: ${weak_link_err}")
endif()
execute_process(
    COMMAND "${WEAK_ABSENCE_EXE}"
    RESULT_VARIABLE weak_run_rc
    OUTPUT_VARIABLE weak_run_out
    ERROR_VARIABLE weak_run_err)
if(NOT weak_run_rc EQUAL 0)
    message(FATAL_ERROR
        "CPU-only weak-absence executable did not observe null providers")
endif()

message(STATUS "GPU_TIMESTAMP_NAMESPACE_CONTRACT_PASS")
