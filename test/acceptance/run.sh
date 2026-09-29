#!/usr/bin/env sh
# Entry point for Szaniec's acceptance suite (manual and CI). Builds the
# checker and the runner when needed, then executes the scenarios. The
# repository root is resolved by walking up until the fixture is found,
# which works from the source tree as well as from a dune build directory.
set -e

dir=$(cd "$(dirname "$0")" && pwd)
repo=$dir
while [ ! -f "$repo/test/fixtures/tasks-app/dune-project" ]; do
  repo=$(dirname "$repo")
  if [ "$repo" = "/" ]; then
    echo "run.sh: cannot locate the szaniec repository" >&2
    exit 2
  fi
done

if [ ! -x "$repo/_build/default/bin/szaniec.exe" ] ||
   [ ! -x "$repo/_build/default/test/acceptance/runner.exe" ]; then
  cd "$repo" && dune build bin/szaniec.exe test/acceptance/runner.exe
fi

exec "$repo/_build/default/test/acceptance/runner.exe" \
  "$repo/_build/default/bin/szaniec.exe" "$repo/test/fixtures/tasks-app" \
  "$repo/test/acceptance/expected"
