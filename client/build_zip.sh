#!/usr/bin/env bash
# Builds playercounter.zip (the optional client mod) next to this script.
# Copy it to <server>/Resources/Client/playercounter.zip.
set -euo pipefail
cd "$(dirname "$0")"
rm -f playercounter.zip
zip -qr -X playercounter.zip scripts lua
echo "built $(pwd)/playercounter.zip"
