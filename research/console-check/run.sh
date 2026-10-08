#!/usr/bin/env bash
# Checks the console commands and experiment 11 on a DEVELOPMENT server, with no players.
#
#   research/console-check/run.sh <server-dir> <artifact-dir>
#
# <server-dir> must hold a server.cfg with the endpoints and the license key, and nothing else that matters: the
# script replaces its resources/ with torii (this checkout), the demo backdoor and the experiment 11 resources, and
# appends its own lines to a copy of server.cfg. Console output goes to <server-dir>/out/.

set -u
SERVER_DIR=$1
ARTIFACT=$2
REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$SERVER_DIR/out"
RES="$SERVER_DIR/resources"
mkdir -p "$OUT"
rm -rf "$RES"
mkdir -p "$RES"
cp -r "$REPO/torii" "$REPO/demo/torii_demo_backdoor" "$REPO/research/exp11_target" "$REPO/research/exp11_caller_lua" \
  "$REPO/research/exp11_caller_js" "$RES/"
rm -f "$RES/torii/review-state.json" "$RES/torii/logs/"*.jsonl
printf '{\n  "version": 1,\n  "exempt": [],\n  "resources": {}\n}\n' > "$RES/torii/policy.lock.json"

# phase name, extra cfg lines, console commands (one per line, typed 2 s apart after a 25 s start-up)
run() {
  local phase=$1 extra=$2 commands=$3
  { grep -v '^ensure\|^set torii_' "$SERVER_DIR/server.cfg"; printf '%b\n' "$extra"
    printf 'ensure torii\nensure torii_demo_backdoor\nensure exp11_target\nensure exp11_caller_lua\nensure exp11_caller_js\n'
  } > "$SERVER_DIR/check.cfg"
  {
    sleep 25
    while IFS= read -r command; do
      [ -n "$command" ] && echo "$command"
      sleep 2
    done <<< "$commands"
    sleep 3
    echo quit
  } | (cd "$SERVER_DIR" && "$ARTIFACT/FXServer.exe" +exec check.cfg) > "$OUT/$phase.log" 2>&1
}

run first 'set torii_mode "observe"\nset torii_lang "fr"' 'torii
torii review
torii explain 1
torii explain 99
exp11_secure typed
exp11_open typed
exp11_call
exp11_call_js'

# the review state must survive a restart; English this time
run restart 'set torii_mode "observe"' 'torii
torii review
torii explain 1'

# with an ACL the Lua caller may run the restricted command; the handler must still see who invoked it
run acl 'set torii_mode "observe"\nadd_ace resource.exp11_caller_lua command.exp11_secure allow' 'exp11_call'

echo "done: $OUT"
