#!/bin/sh
# Coverage acceptance: ordinary build, one instrumented command, sanitized
# scenario, forced termination, a missing hook, and a stale snapshot.
set -eu

dir=$(cd "$(dirname "$0")" && pwd)
repo=$dir
while [ ! -f "$repo/test/fixtures/coverage-app/szaniec/coverage.json" ]; do
  repo=$(dirname "$repo")
  if [ "$repo" = "/" ]; then
    echo "run.sh: cannot locate the szaniec repository" >&2
    exit 2
  fi
done

cd "$repo"
for key in $(env | awk -F= '/^(DUNE_|OCAML|CAML_|BUILD_PATH_PREFIX_MAP|INSIDE_DUNE)/ {print $1}'); do
  unset "$key" || true
done
export DUNE_CACHE=disabled

gap="$repo/test/fixtures/coverage-app/lib/gap_probe"
stale="$repo/test/fixtures/coverage-app/lib/core/stale_marker.ml"
work=$(mktemp -d)
cleanup() {
  rm -rf "$work" "$gap" "$stale"
}
trap cleanup EXIT

dune build bin/szaniec.exe test/fixtures/coverage-app/bin/server.exe
szaniec="$repo/_build/default/bin/szaniec.exe"
server="$repo/_build/default/test/fixtures/coverage-app/bin/server.exe"
config="$repo/test/fixtures/coverage-app/szaniec/coverage.json"
inventory="$repo/test/fixtures/coverage-app/functions.json"

if grep -a -q "BISECT-COVERAGE-" "$server"; then
  echo "ordinary dune build instrumented the server" >&2
  exit 1
fi

if grep -R -n -E "bisect_ppx|BISECT_" \
  "$repo/test/fixtures/coverage-app" \
  --include=dune --include='*.ml' --include='*.json' --include='*.md' \
  --include='*.ts'
then
  echo "fixture names the internal points engine" >&2
  exit 1
fi

for dune_file in lib/core/dune lib/api/dune bin/dune; do
  count=$(grep -c "backend szaniec.instrumentation" \
    "$repo/test/fixtures/coverage-app/$dune_file")
  if [ "$count" -ne 1 ]; then
    echo "$dune_file has $count instrumentation backends" >&2
    exit 1
  fi
done

run_coverage() {
  mode=$1
  out=$2
  shift 2
  COVERAGE_MODE="$mode" "$szaniec" coverage --json \
    --project-root "$repo" --config "$config" --out "$out" "$@"
}

graceful="$work/graceful.json"
run_coverage graceful "$graceful" --function-inventory "$inventory"
deno run --allow-read "$repo/test/coverage/assert_report.ts" graceful "$graceful"

if ! grep -a -q "BISECT-COVERAGE-" "$server"; then
  echo "szaniec coverage did not instrument the server" >&2
  exit 1
fi

forced="$work/forced.json"
set +e
run_coverage forced "$forced"
forced_code=$?
set -e
if [ "$forced_code" -ne 2 ]; then
  echo "forced termination exited $forced_code" >&2
  exit 1
fi
deno run --allow-read "$repo/test/coverage/assert_report.ts" forced "$forced"

mkdir -p "$gap"
cat > "$gap/dune" <<'EOF'
(library
 (name coverage_app_gap))
EOF
printf 'let present () = 1\n' > "$gap/gap_probe.ml"
gap_report="$work/gap.json"
set +e
run_coverage once "$gap_report"
gap_code=$?
set -e
rm -rf "$gap"
if [ "$gap_code" -ne 2 ]; then
  echo "missing hook exited $gap_code" >&2
  exit 1
fi
deno run --allow-read "$repo/test/coverage/assert_report.ts" gap "$gap_report"

rm -f "$stale"
stale_report="$work/stale.json"
set +e
run_coverage stale "$stale_report"
stale_code=$?
set -e
rm -f "$stale"
if [ "$stale_code" -ne 2 ]; then
  echo "stale snapshot exited $stale_code" >&2
  exit 1
fi
deno run --allow-read "$repo/test/coverage/assert_report.ts" stale "$stale_report"

echo "coverage acceptance: ok"
