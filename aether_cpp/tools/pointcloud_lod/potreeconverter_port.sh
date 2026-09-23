#!/bin/bash
# Portability patch for PotreeConverter 2.0 @ 8bfad98 on Linux/GCC-14.
# Compile-only. No algorithmic line is touched. Deviations listed in PORT_DEVIATIONS.md.
set -euo pipefail
# Usage: potreeconverter_port.sh <path to a PotreeConverter checkout at 8bfad98>
cd "${1:?usage: $0 <PotreeConverter checkout>}/Converter"

cat > include/pw_portability.h <<'HDR'
#pragma once
// Portability shim: PotreeConverter 2.0 upstream targets MSVC and uses the
// __debugbreak() intrinsic, which does not exist in GCC/Clang.
// On Windows with no debugger attached, __debugbreak() raises STATUS_BREAKPOINT
// and terminates the process; __builtin_trap() reproduces exactly that.
#if defined(_MSC_VER)
  #define PW_DEBUG_BREAK() __debugbreak()
#else
  #define PW_DEBUG_BREAK() __builtin_trap()
#endif
HDR

# --- D1..D3: __debugbreak -> PW_DEBUG_BREAK ---
for f in src/VBuffer.cpp src/indexer.cpp; do
  grep -q 'pw_portability.h' "$f" || sed -i '0,/^#include/s//#include "pw_portability.h"\n#include/' "$f"
  sed -i 's/\b__debugbreak()/PW_DEBUG_BREAK()/g' "$f"
done

# --- D4..D7: nlohmann implicit json->std::string is ambiguous in modern nlohmann ---
sed -i 's|state->name = js\["state"\]\["name"\];|state->name = js["state"]["name"].get<std::string>();|' src/indexer.cpp
sed -i 's|attribute.description = jsAttribute\["description"\];|attribute.description = jsAttribute["description"].get<std::string>();|' src/indexer.cpp
sed -i 's|chunk->id = jsChunk\["id"\];|chunk->id = jsChunk["id"].get<std::string>();|' src/indexer.cpp
sed -i 's|chunk->file = jsChunk\["file"\];|chunk->file = jsChunk["file"].get<std::string>();|' src/indexer.cpp

# --- D8: upstream copy-paste bug: the NIR block at 655-664 is duplicated verbatim at 666-675 ---
python3 - <<'PY'
p = 'src/chunker_countsort_laszip.cpp'
lines = open(p).read().split('\n')
a, b = lines[654:664], lines[665:675]            # 0-indexed
assert a == b, "duplicate block not verbatim -- refusing to edit"
assert 'offsetNIR' in a[0], a[0]
del lines[664:675]                                # drop blank + second copy
open(p, 'w').write('\n'.join(lines))
print('D8: removed verbatim duplicate NIR block (11 lines)')
PY
echo "patched"
