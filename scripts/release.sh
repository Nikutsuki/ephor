#!/bin/sh
# Ephor release script — thin wrapper around release.py
# Usage: ./scripts/release.sh <new_version>
# Example: ./scripts/release.sh 0.12.7

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "${SCRIPT_DIR}/release.py" "$@"
