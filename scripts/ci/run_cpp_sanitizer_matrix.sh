#!/usr/bin/env bash
set -euo pipefail

STRICT=0
STRICT_IF_CI=0
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=1
      shift
      ;;
    --strict-if-ci)
      STRICT_IF_CI=1
      shift
      ;;
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--strict] [--strict-if-ci] [--repo-root PATH]"
      exit 2
      ;;
  esac
done

if [[ $STRICT_IF_CI -eq 1 && -n "${CI:-}" ]]; then
  STRICT=1
fi

CPP_DIR="$REPO_ROOT/aether_cpp"
if [[ ! -d "$CPP_DIR" || ! -f "$CPP_DIR/CMakeLists.txt" ]]; then
  echo "sanitizer-matrix: missing aether_cpp/CMakeLists.txt under $CPP_DIR"
  exit 1
fi

OUT_DIR="$REPO_ROOT/governance/generated"
LOG_DIR="$OUT_DIR/sanitizers"
REPORT="$OUT_DIR/sanitizer_matrix_report.json"
mkdir -p "$LOG_DIR"

FAILURES=0
RESULT_JSON_ITEMS=""

append_result() {
  local name="$1"
  local status="$2"
  local build_dir="$3"
  local log_file="$4"
  local item
  item=$(cat <<EOF
{"name":"$name","status":"$status","build_dir":"$build_dir","log":"$log_file"}
EOF
)
  if [[ -n "$RESULT_JSON_ITEMS" ]]; then
    RESULT_JSON_ITEMS+=","
  fi
  RESULT_JSON_ITEMS+="$item"
}

run_variant() {
  local name="$1"
  local sanitize_flags="$2"
  local build_dir="$CPP_DIR/build.san.$name"
  local log_file="$LOG_DIR/$name.log"

  echo "sanitizer-matrix: [$name] configure + build + test"
  {
    echo "[configure]"
    cmake -S "$CPP_DIR" -B "$build_dir" \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DCMAKE_CXX_STANDARD=20 \
      -DCMAKE_CXX_FLAGS="-O1 -g -fno-omit-frame-pointer $sanitize_flags" \
      -DCMAKE_EXE_LINKER_FLAGS="$sanitize_flags" \
      -DCMAKE_SHARED_LINKER_FLAGS="$sanitize_flags"

    echo "[build]"
    cmake --build "$build_dir" --target c_api_tests status_tests

    echo "[test]"
    # Match exact test names only; avoid unintentionally pulling geo_c_api.
    ctest --test-dir "$build_dir" -R "^(status|c_api)$" --output-on-failure
  } >"$log_file" 2>&1 || {
    append_result "$name" "FAIL" "$build_dir" "$log_file"
    if [[ $STRICT -eq 1 ]]; then
      FAILURES=$((FAILURES + 1))
    fi
    echo "sanitizer-matrix: [$name] failed (strict=$STRICT), log: $log_file"
    return 0
  }

  append_result "$name" "PASS" "$build_dir" "$log_file"
  echo "sanitizer-matrix: [$name] pass"
}

run_variant "asan_ubsan" "-fsanitize=address,undefined -fno-sanitize-recover=all"
run_variant "tsan" "-fsanitize=thread -fno-sanitize-recover=all"

{
  echo "{"
  echo "  \"strict\": $STRICT,"
  echo "  \"results\": [${RESULT_JSON_ITEMS}]"
  echo "}"
} >"$REPORT"

echo "sanitizer-matrix: report=$REPORT"

if [[ $FAILURES -ne 0 ]]; then
  echo "sanitizer-matrix: FAILED ($FAILURES variants)"
  exit 1
fi

echo "sanitizer-matrix: PASSED"
exit 0
