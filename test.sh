#!/usr/bin/env bash
# End-to-end check on a throwaway named session: save, restart the server, expect the relaunch.
# Needs the plugin linked first: herdr plugin link .
set -euo pipefail
unset HERDR_SOCKET_PATH HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID
export HERDR_SESSION=respawn-test
state="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/devicki.respawn"

up() {
  herdr server >/dev/null 2>&1 &
  for _ in $(seq 50); do herdr pane list >/dev/null 2>&1 && return; sleep 0.2; done
  echo "FAIL: server did not start" >&2
  exit 1
}
fg_of() { herdr pane process-info --pane "$1" | jq -r '.result.process_info.foreground_processes[0].argv[0]'; }
cleanup() {
  herdr server stop >/dev/null 2>&1 || :
  sleep 0.5
  herdr session delete "$HERDR_SESSION" >/dev/null 2>&1 || :
  rm -f "$state"/*"$HERDR_SESSION".json
}
cleanup
trap cleanup EXIT

up
p1=$(herdr workspace create --cwd "$PWD" | jq -r .result.root_pane.pane_id)
p2=$(herdr pane split "$p1" --direction right --no-focus | jq -r .result.pane.pane_id)
herdr pane run "$p1" ' top' >/dev/null
herdr pane run "$p2" ' sleep 999' >/dev/null
sleep 1
herdr plugin action invoke devicki.respawn.save >/dev/null
sleep 1
herdr server stop >/dev/null
sleep 1
up
sleep 2

[ "$(fg_of "$p1")" = top ] || { echo "FAIL: top not relaunched in $p1" >&2; exit 1; }
case "$(fg_of "$p2")" in *sleep*) echo "FAIL: non-allowlisted sleep was relaunched" >&2; exit 1 ;; esac
echo PASS
