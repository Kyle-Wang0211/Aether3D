# SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
# Copyright (c) 2024-2026 Aether3D. All rights reserved.
#
# Bakes one .wgsl file into a .cpp constexpr definition.
# Invoked per-file from aether_cpp/CMakeLists.txt via add_custom_command.
#
# Usage:
#   cmake -DINPUT=foo.wgsl -DOUTPUT=foo_wgsl.cpp -DNAME=foo -P bake_one_wgsl.cmake
#
# Why CMake -P (script mode) instead of file(GENERATE):
#   - file(GENERATE) runs at configure time only. We need re-bake on every
#     .wgsl edit, which requires a build-time custom command. CMake -P
#     is the standard way to script a build-time action portably (no
#     bash / python / shell-builtin assumptions).
#
# Why not configure_file():
#   - configure_file() is configure-time, can't be a build-time DEPENDS
#     target, and applies @VAR@ substitution we don't want for raw WGSL
#     text (which contains its own characters that would clash).

if(NOT INPUT OR NOT OUTPUT OR NOT NAME)
    message(FATAL_ERROR "bake_one_wgsl.cmake requires -DINPUT, -DOUTPUT, -DNAME")
endif()

file(READ "${INPUT}" wgsl_content)

# C++ raw-string custom delimiter R"DELIM(...)DELIM". Constraints:
#   - C++ standard caps custom delimiter at 16 characters (clang errors
#     "raw string delimiter longer than 16 characters" otherwise).
#   - Must not appear as a substring anywhere in the .wgsl source — if
#     it did, the raw string literal would terminate mid-content.
#
# WGSL files use snake_case identifiers + symbols + ASCII whitespace +
# basic comments. ALL-CAPS sequences with underscores are extremely
# unlikely in WGSL (the only place CAPS appears is in #define names,
# but those have already been processed away by the Path G ETL before
# vendoring; verified zero collisions across all 15 .wgsl files at
# Phase 6.4a setup time). We also verify defensively below.
set(DELIM "WGSL_BAKE_DELIM")

string(FIND "${wgsl_content}" "${DELIM}" delim_collision_idx)
if(NOT delim_collision_idx EQUAL -1)
    message(FATAL_ERROR
        "bake_one_wgsl.cmake: input file '${INPUT}' contains the raw-string "
        "delimiter '${DELIM}' at offset ${delim_collision_idx}. The bake would "
        "produce malformed C++ raw string literals. Fix: change DELIM in "
        "bake_one_wgsl.cmake to a string that does not appear in any .wgsl "
        "source.")
endif()

file(WRITE "${OUTPUT}"
"// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// AUTO-GENERATED — DO NOT EDIT.
// Source:    ${INPUT}
// Generator: aether_cpp/scripts/bake_one_wgsl.cmake
//
// This file is regenerated whenever the source .wgsl changes (CMake
// add_custom_command DEPENDS). Source of truth is the .wgsl file —
// edits here are clobbered on the next build.

#include \"aether/shaders/wgsl_sources.h\"

namespace aether {
namespace shaders {

extern const char ${NAME}_wgsl[] = R\"${DELIM}(${wgsl_content})${DELIM}\";

}  // namespace shaders
}  // namespace aether
")
