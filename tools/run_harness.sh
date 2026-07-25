#!/usr/bin/env bash
# Runs the map-editor integration harness against the real game and tees
# output to tools/shots/last_run.log. One command for the whole cycle:
#
#   ./tools/run_harness.sh
#
# Requires a real display (headed run; no xvfb) -- see tools/harness/README.md.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT_BIN="${GODOT_BIN:-/usr/local/bin/godot}"
SCENE="res://tools/input_harness.tscn"

mkdir -p "$SCRIPT_DIR/shots"
LOG_FILE="$SCRIPT_DIR/shots/last_run.log"

DISPLAY="${DISPLAY:-:0}" "$GODOT_BIN" --path "$PROJECT_DIR" "$SCENE" 2>&1 | tee "$LOG_FILE"
exit_code="${PIPESTATUS[0]}"

echo
echo "Full log: $LOG_FILE"
exit "$exit_code"
