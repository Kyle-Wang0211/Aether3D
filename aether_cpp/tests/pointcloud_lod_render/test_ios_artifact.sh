#!/bin/sh
# Judges for the vendored iOS LOD library (plan L3, option A1):
#
#   test_ios_artifact.sh <vendor/aether_lod dir> <scratch dir> [dawn object .o]
#
#   V1  <vendor>/build_ios_lod.sh --verify-only passes on the shipped archive
#       (archive sha, member manifest, member names/order, defined-symbol table
#       == .syms.txt, 0 defined wgpu*, every undefined wgpu* declared in the
#       pinned webgpu.h, the 18 C entry points, header / licence hashes, receipt)
#   V2  independent of that script: nm finds 0 defined wgpu* in the archive
#   N1  negative control: the archive plus ONE extra (harmless) member must fail
#       --verify-only, and the member-count check must be among the failures
#   N2  negative control: the archive plus ONE Dawn member (an object that
#       defines wgpu*; pass a real one, e.g. webgpu_dawn_native_proc.o from an
#       iOS Dawn build, or a stub that defines wgpuDeviceRelease is compiled)
#       must fail, and the "defined wgpu*" check must be among the failures
set -u
V="${1:?vendor dir}"; S="${2:?scratch dir}"; DAWN_OBJ="${3:-}"
rm -rf "$S"; mkdir -p "$S"
fails=0
pass() { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }

lib="$(ls "$V"/libs/ios-arm64/libpw_lod_*.a 2>/dev/null | head -1)"
[ -n "$lib" ] || { echo "no libpw_lod_*.a under $V/libs/ios-arm64"; exit 1; }
name="$(basename "$lib")"

# V1
if "$V/build_ios_lod.sh" --verify-only > "$S/v1.log" 2>&1; then pass "V1 --verify-only on $name"; else
  bad "V1 --verify-only on $name"; cat "$S/v1.log"; fi

# V2 (write nm output to a file first: never pipe nm into grep -q)
nm -g --defined-only "$lib" > "$S/defs.txt" 2>/dev/null
n="$(awk 'NF==3 && $3 ~ /^_wgpu/' "$S/defs.txt" | wc -l | tr -d ' ')"
[ "$n" = "0" ] && pass "V2 nm: defined wgpu* = 0" || bad "V2 nm: defined wgpu* = $n"

sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
cc="$(xcrun --sdk iphoneos --find clang)"

# N1: one extra harmless member
printf 'int pw_lod_extra_member_for_negative_control(void) { return 1; }\n' > "$S/extra.c"
"$cc" -arch arm64 -isysroot "$sdk" -miphoneos-version-min=15.0 -c "$S/extra.c" -o "$S/extra.o"
mkdir -p "$S/n1"; cp "$lib" "$S/n1/$name"
xcrun ar -q "$S/n1/$name" "$S/extra.o" 2>/dev/null; xcrun ranlib "$S/n1/$name" 2>/dev/null
if PW_LOD_ARTIFACT="$S/n1/$name" "$V/build_ios_lod.sh" --verify-only > "$S/n1.log" 2>&1; then
  bad "N1 extra member NOT rejected"
elif grep -q "FAIL member count" "$S/n1.log"; then
  pass "N1 extra member rejected ($(grep -c '  FAIL' "$S/n1.log") failed checks, incl. member count)"
else bad "N1 rejected but not by the member-count check"; cat "$S/n1.log"; fi

# N2: one Dawn member
if [ -z "$DAWN_OBJ" ]; then
  printf 'void wgpuDeviceRelease(void* d) { (void)d; }\n' > "$S/dawn_stub.c"
  "$cc" -arch arm64 -isysroot "$sdk" -miphoneos-version-min=15.0 -c "$S/dawn_stub.c" -o "$S/dawn_member.o"
  DAWN_OBJ="$S/dawn_member.o"; what="stub defining wgpuDeviceRelease"
else what="$(basename "$DAWN_OBJ")"; fi
mkdir -p "$S/n2"; cp "$lib" "$S/n2/$name"
xcrun ar -q "$S/n2/$name" "$DAWN_OBJ" 2>/dev/null; xcrun ranlib "$S/n2/$name" 2>/dev/null
if PW_LOD_ARTIFACT="$S/n2/$name" "$V/build_ios_lod.sh" --verify-only > "$S/n2.log" 2>&1; then
  bad "N2 Dawn member NOT rejected"
elif grep -q "FAIL defined wgpu\*" "$S/n2.log"; then
  pass "N2 Dawn member ($what) rejected: $(grep 'FAIL defined wgpu' "$S/n2.log" | sed 's/^ *FAIL //' | cut -c1-60)"
else bad "N2 rejected but not by the defined-wgpu* check"; cat "$S/n2.log"; fi

echo; [ "$fails" = "0" ] && echo "==== ALL PASS ====" || echo "==== FAILED ===="
exit "$fails"
