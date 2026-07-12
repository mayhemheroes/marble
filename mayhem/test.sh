#!/usr/bin/env bash
#
# mayhem/test.sh — RUN marble's OWN test suite (already compiled by mayhem/build.sh via
# `cargo test --no-run` into $SRC/mayhem-tests-target) and emit a CTRF summary.
#
# PATCH-grade oracle: tests/regressions.rs is a real known-answer suite (15 tests that
# write batches, read objects back and assert exact values/lengths, exercise GC and
# recovery invariants); tests/burn_in.rs asserts write/maintenance behavior; and
# tests/crash_atomicity.rs (harness=false, its own main) spawns child processes that are
# killed mid-write and asserts crash-consistent recovery of the store. A no-op / exit(0)
# patch to the storage engine FAILS these assertions. Neutered libtest binaries are also
# detected structurally: they emit no `test result:` lines, so the parsed count collapses
# and the oracle reports failure.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# marble keeps one open file handle per storage-file; the crash_atomicity suite (tiny
# target_file_size, many batches) legitimately needs more than the docker-build default
# soft limit of 1024 fds. Raise the soft limit toward the hard limit (no root needed).
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN the pre-built test binaries directly (no cargo, no recompilation — build.sh compiled them).
# `cargo test --no-run` left one executable per test target under mayhem-tests-target/release/deps.
TDIR="$SRC/mayhem-tests-target/release/deps"
[ -d "$TDIR" ] || { echo "ERROR: $TDIR missing — build.sh should have built the test suite" >&2; emit_ctrf cargo-test 0 1; exit 1; }

OUT="$(mktemp)"
# libtest binaries: lib unit tests (marble-*), tests/burn_in.rs, tests/regressions.rs.
for bin in "$TDIR"/marble-* "$TDIR"/burn_in-* "$TDIR"/regressions-*; do
  [ -f "$bin" ] && [ -x "$bin" ] || continue
  case "$bin" in *.d) continue ;; esac
  echo "=== running $(basename "$bin") ==="
  "$bin" --test-threads=1 2>&1 | tee -a "$OUT"
done

# Sum every `test result: ok. X passed; Y failed; ... Z ignored` line.
sum_field() { grep -E '^test result:' "$OUT" | sed -E "s/.* ([0-9]+) $1.*/\1/" | awk '{s+=$1} END {print s+0}'; }
PASSED=$(sum_field passed)
FAILED=$(sum_field failed)
SKIPPED=$(sum_field ignored)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"
rm -f "$OUT"

# tests/crash_atomicity.rs is harness=false (its own main; re-execs itself as crash-test
# children and asserts recovery invariants) — no libtest `test result:` line, so count it
# as one pass/fail by exit status.
CRASH_BIN=""
for bin in "$TDIR"/crash_atomicity-*; do
  [ -f "$bin" ] && [ -x "$bin" ] || continue
  case "$bin" in *.d) continue ;; esac
  CRASH_BIN="$bin"
done
if [ -n "$CRASH_BIN" ]; then
  echo "=== running $(basename "$CRASH_BIN") (harness=false crash-atomicity suite) ==="
  if "$CRASH_BIN"; then
    PASSED=$(( PASSED + 1 ))
  else
    echo "crash_atomicity suite FAILED" >&2
    FAILED=$(( FAILED + 1 ))
  fi
else
  echo "ERROR: crash_atomicity test binary missing — build.sh should have built it" >&2
  FAILED=$(( FAILED + 1 ))
fi

# No parsed results at all (e.g. neutered binaries emitting nothing) → honest failure.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "ERROR: no 'test result:' lines parsed — test binaries produced no results" >&2
  emit_ctrf cargo-test 0 1; exit 1
fi

emit_ctrf cargo-test "$PASSED" "$FAILED" "$SKIPPED"
