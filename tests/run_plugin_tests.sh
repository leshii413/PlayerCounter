#!/usr/bin/env bash
# Runs every tests/plugin_test*.lua against main.lua with the BeamMP server mock.
# Needs: Lua 5.3 (LUA=path, default lua5.3) and mock_beammp.lua (MOCK_BEAMMP=path).
# mock_beammp.lua ships with the beamng-beammp-dev skill (scripts/mock_beammp.lua);
# it is not part of this repo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LUA="${LUA:-lua5.3}"
: "${MOCK_BEAMMP:?set MOCK_BEAMMP to the path of mock_beammp.lua}"
export MOCK_BEAMMP="$(cd "$(dirname "$MOCK_BEAMMP")" && pwd)/$(basename "$MOCK_BEAMMP")"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/Resources/Server/PlayerCounter"
cp "$HERE/../main.lua" "$ROOT/Resources/Server/PlayerCounter/"
status=0
for test in "$HERE"/plugin_test*.lua; do
  rm -rf "$ROOT/Resources/Server/PlayerCounter/data"
  echo "### $(basename "$test")"
  (cd "$ROOT" && TZ=UTC "$LUA" "$test") || status=1
done
exit $status
