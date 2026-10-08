#!/usr/bin/env bash
# torii compatibility run on a DEVELOPMENT server: observe phase, approval from the logs, enforce phase.
# It says nothing about behaviour with real players.
#
#   research/compat/run.sh <server-dir> <artifact-dir> <observe-minutes> <enforce-minutes>
#
# <server-dir> holds server.cfg and resources/ (with torii, the resources under test and torii_compat_load).
# A database and the local HTTP endpoint (http_ok.py) must already be running.

set -u
SERVER_DIR=$1
ARTIFACT=$2
OBSERVE_MIN=$3
ENFORCE_MIN=$4
REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$SERVER_DIR/run"
mkdir -p "$OUT"
LOCK="$SERVER_DIR/resources/torii/policy.lock.json"
LOG="$SERVER_DIR/resources/torii/logs/torii.jsonl"

sample_memory() { # phase, seconds
  local phase=$1 until=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$until" ]; do
    local line
    line=$(tasklist //FI "IMAGENAME eq FXServer.exe" //FO CSV //NH 2>/dev/null | head -1)
    if ! echo "$line" | grep -q FXServer; then
      echo "$(date +%s),$phase,DEAD" >> "$OUT/memory.csv"
      return 1
    fi
    local kb
    kb=$(echo "$line" | awk -F'","' '{print $5}' | tr -dc '0-9')
    echo "$(date +%s),$phase,$kb" >> "$OUT/memory.csv"
    sleep 60
  done
}

run_phase() { # phase, minutes, mode
  local phase=$1 minutes=$2 mode=$3
  sed -i "s/^set torii_mode .*/set torii_mode \"$mode\"/" "$SERVER_DIR/server.cfg"
  ( cd "$SERVER_DIR" && "$ARTIFACT/FXServer.exe" +exec server.cfg > "$OUT/$phase.console.log" 2>&1 & )
  sleep 5
  echo "$(date -u +%FT%TZ) $phase started ($mode, $minutes min)" >> "$OUT/run.txt"
  if sample_memory "$phase" $(( minutes * 60 )); then
    echo "$(date -u +%FT%TZ) $phase finished normally" >> "$OUT/run.txt"
  else
    echo "$(date -u +%FT%TZ) $phase: FXServer EXITED EARLY" >> "$OUT/run.txt"
  fi
  taskkill //F //IM FXServer.exe > /dev/null 2>&1
  sleep 5
}

: > "$OUT/memory.csv"
: > "$OUT/run.txt"
rm -f "$LOG"
printf '{\n  "version": 1,\n  "exempt": [],\n  "resources": {}\n}\n' > "$LOCK"

run_phase observe "$OBSERVE_MIN" observe

# the admin flow: approve what observe mode saw, with presets, and exempt the JavaScript resources on purpose
node "$REPO/cli/torii.mjs" approve "$SERVER_DIR/resources" --from-logs "$LOG" --use-presets --lock "$LOCK" --write > "$OUT/approve.txt" 2>&1
python - "$LOCK" <<'PY'
import json, sys
path = sys.argv[1]
lock = json.load(open(path, encoding="utf-8"))
lock["exempt"] = sorted(set(lock.get("exempt", []) + ["oxmysql", "pma-voice"]))
# the human review: the admin refuses the unapproved host the load generator also calls
for grant in lock["resources"].values():
    grant["http"] = [e for e in grant.get("http", []) if "not-approved.invalid" not in e]
json.dump(lock, open(path, "w", encoding="utf-8"), indent=2)
PY
cp "$LOCK" "$OUT/policy.lock.json"
cp "$LOG" "$OUT/observe.torii.jsonl" 2>/dev/null
rm -f "$LOG"

run_phase enforce "$ENFORCE_MIN" enforce
cp "$LOG" "$OUT/enforce.torii.jsonl" 2>/dev/null

python "$REPO/research/compat/summarize.py" "$OUT" > "$OUT/summary.md" 2>&1
echo "done: $OUT/summary.md"
