#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's cargo-fuzz target(s) as sanitized libFuzzer
# binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS). EDIT per repo.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run so cargo won't try to refresh the
#     crates.io index over the (absent) network — so do NOT hard-code `--offline`
#     here (it would break this first, online build).
#   - For a FULLY self-contained image (no runtime flag needed) instead vendor:
#       cargo vendor --versioned-dirs vendor   # commit vendor/ + a .cargo/config.toml
#     with [source.crates-io] replace-with = "vendored-sources".
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself, but we
# pin it explicitly. --cfg fuzzing matches libfuzzer-sys; force-frame-pointers aids
# ASan backtraces. The rlenv PATCH tier prepends `-C debuginfo=2`; we don't fight it.
#
# SANITIZER off-switch (SPEC): the Dockerfile threads $SANITIZER_FLAGS (default asan+ubsan,
# halting). rustc ignores clang flags, so we DERIVE the rustc sanitizer flag from it: if
# $SANITIZER_FLAGS mentions "address" we add -Zsanitizer=address; an EMPTY value (built with
# --build-arg SANITIZER_FLAGS=) yields a natural, un-instrumented crash build.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all}"
RUST_SAN=""
CFZ_SANITIZER="none"   # cargo-fuzz's own -s flag; overridden below when ASan is requested
case "$SANITIZER_FLAGS" in
  *address*) RUST_SAN="-Zsanitizer=address"; CFZ_SANITIZER="address" ;;
esac

# DWARF < 4 contract (§6.2 item 10): clang-19 / recent rustc default to DWARF-5, which Mayhem's
# triage can't read. Thread $RUST_DEBUG_FLAGS (default: DWARF-3 + frame pointers + debuginfo) so
# every fuzz binary carries DWARF < 4 symbols. The rlenv PATCH tier may override it.
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=1 -Zdwarf-version=3 -Cforce-frame-pointers}"

export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_SAN $RUST_DEBUG_FLAGS"

# libfuzzer-sys compiles its C++ libFuzzer runtime through the `cc` crate (clang), which
# defaults to DWARF-5. rustc's -Zdwarf-version only covers Rust CUs, so pin the C/C++ side
# to DWARF-3 too via CFLAGS/CXXFLAGS — otherwise the final binary carries DWARF-5 CUs and
# fails the DWARF < 4 gate (§6.2 item 10).
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# Upstream ships its own cargo-fuzz crate (fuzz/ with the fuzz_model target) and it
# builds on the pinned nightly — use it directly.
FUZZ_DIR="fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it). A `+toolchain`
# override would make rustup try to install another channel into the locked /opt/rust.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -s "$CFZ_SANITIZER" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"     # EDIT the output path/name to match your Mayhemfile target:
  echo "built /mayhem/$t"
done

# Build the project's OWN test suite (tests/regressions.rs, tests/burn_in.rs, the
# harness=false tests/crash_atomicity.rs runner + lib unit tests) with the project's
# NORMAL flags (no sanitizer, no --cfg fuzzing) so mayhem/test.sh only RUNS it.
# A SEPARATE target dir keeps the fuzz RUSTFLAGS above from leaking into this clean build.
echo "=== building marble test suite (cargo test --no-run, normal flags) ==="
( cd "$SRC" \
  && env -u RUSTFLAGS CARGO_TARGET_DIR="$SRC/mayhem-tests-target" \
       cargo test --no-run --release --lib --tests )
echo "test suite built under $SRC/mayhem-tests-target"

echo "build.sh complete"
