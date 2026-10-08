#!/usr/bin/env sh
# Suggestions acceptance: replay the corpus fixture, then prove that a
# suggestions run does not change a following szaniec check.
set -eu

dir=$(cd "$(dirname "$0")" && pwd)
repo=$dir
while [ ! -f "$repo/test/fixtures/suggestions-corpus/dune-project" ]; do
  repo=$(dirname "$repo")
  if [ "$repo" = "/" ]; then
    echo "suggestions.sh: cannot locate the szaniec repository" >&2
    exit 2
  fi
done

szaniec="$repo/_build/default/bin/szaniec.exe"
if [ ! -x "$szaniec" ]; then
  (cd "$repo" && dune build bin/szaniec.exe)
fi

corpus="$repo/test/fixtures/suggestions-corpus"
expected_dir="$repo/test/acceptance/expected"
work="/tmp/szaniec-sug-$$"
rm -rf "$work"
mkdir -p "$work"
tar -C "$corpus" -cf - --exclude _build . | tar -C "$work" -xf -

clean_nested_env() {
  keys=$(env | sed -n 's/^\(DUNE_[^=]*\|OCAML[^=]*\|CAML_[^=]*\|INSIDE_DUNE\|BUILD_PATH_PREFIX_MAP\)=.*/\1/p')
  for k in $keys; do
    unset "$k"
  done
  export DUNE_CACHE=disabled
}

(
  clean_nested_env
  cd "$work"
  dune build
)

if ! "$szaniec" approve \
  --config "$work/szaniec.toml" \
  --project-root "$work" >"$work/approve.txt"
then
  echo "suggestions.sh: approve failed" >&2
  cat "$work/approve.txt" >&2
  exit 1
fi

run_check() {
  "$szaniec" check \
    --config "$work/szaniec.toml" \
    --project-root "$work" \
    --json
}

check_out="$work/check-before.json"
set +e
run_check >"$check_out" 2>"$work/check-before.err"
check_code=$?
set -e
if [ ! -f "$work/szaniec.json" ]; then
  echo "suggestions.sh: check did not write szaniec.json (exit $check_code)" >&2
  cat "$work/check-before.err" >&2
  exit 1
fi
cp "$work/szaniec.json" "$work/callgraph-before.json"

run_suggestions() {
  extra=$1
  out=$2
  set +e
  "$szaniec" suggestions \
    --config "$work/szaniec.toml" \
    --project-root "$work" \
    --json \
    --no-cache \
    --provider-fixture "$work/szaniec/provider-fixture.json" \
    $extra >"$out"
  code=$?
  set -e
  if [ "$code" -ne 0 ]; then
    echo "suggestions.sh: suggestions exited $code" >&2
    cat "$out" >&2
    exit 1
  fi
}

run_suggestions "" "$work/suggestions.json"
run_suggestions "--experimental" "$work/suggestions-experimental.json"

check_after="$work/check-after.json"
set +e
run_check >"$check_after" 2>"$work/check-after.err"
check_code_after=$?
set -e

if [ "$check_code" -ne "$check_code_after" ]; then
  echo "suggestions.sh: check exit changed from $check_code to $check_code_after" >&2
  exit 1
fi
if ! cmp -s "$check_out" "$check_after"; then
  echo "suggestions.sh: check JSON changed after suggestions" >&2
  diff -u "$check_out" "$check_after" >&2 || true
  exit 1
fi
if ! cmp -s "$work/callgraph-before.json" "$work/szaniec.json"; then
  echo "suggestions.sh: szaniec.json changed after suggestions" >&2
  exit 1
fi

compare() {
  name=$1
  actual=$2
  golden="$expected_dir/$name"
  if [ "${SZANIEC_UPDATE_SUGGESTIONS:-}" = "1" ]; then
    cp "$actual" "$golden"
    echo "updated $name"
    return
  fi
  if [ ! -f "$golden" ]; then
    echo "suggestions.sh: missing $golden" >&2
    exit 1
  fi
  if ! cmp -s "$golden" "$actual"; then
    echo "suggestions.sh: $name mismatch" >&2
    diff -u "$golden" "$actual" >&2 || true
    exit 1
  fi
}

compare "suggestions-corpus.json" "$work/suggestions.json"
compare "suggestions-corpus-experimental.json" "$work/suggestions-experimental.json"

if [ "${SZANIEC_KEEP:-}" != "1" ]; then
  rm -rf "$work"
fi
echo "suggestions acceptance passed"
