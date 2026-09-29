#!/usr/bin/env bash
# Reboot-like check with a client attached, the way a laptop reconnects after the host reboots:
# an isolated Herdr (own HOME, only this plugin linked) is started by its client, TUIs run in the
# focused pane, a background tab and a background workspace next to a command off the allowlist,
# then the server gets SIGTERM and the client dies with it, and a new client starts the server
# again. Needs tmux, jq, htop and vim.
# TEST_WORK picks the scratch dir (default: a new mktemp dir).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=${TEST_WORK:-$(mktemp -d)}
herdr=$(command -v herdr)
# Unix socket paths must stay under 108 bytes, so HOME is a short symlink to the scratch dir.
home="${XDG_RUNTIME_DIR:-/tmp}/respawn-test"
tmx=(tmux -L respawn-test -f /dev/null)
env_=(env -i HOME="$home" PATH="${herdr%/*}:/usr/local/bin:/usr/bin:/bin" TERM=xterm-256color
  LANG=en_US.UTF-8 SHELL=/bin/bash)
h() { "${env_[@]}" "$herdr" "$@"; }
fg_of() { h pane process-info --pane "$1" | jq -r '[.result.process_info.foreground_processes[].argv | join(" ")] | first // "-"'; }
client() {
  "${tmx[@]}" new-session -d -s c -x 160 -y 40 "$(printf '%q ' "${env_[@]}") $herdr"
  "${tmx[@]}" set -g status off
  for _ in $(seq 50); do h pane list >/dev/null 2>&1 && return; sleep 0.2; done
  echo "FAIL: server did not come up" >&2
  exit 1
}
# Only the server whose HOME is this test's HOME; the user's own server runs the same binary.
test_server() {
  pgrep -u "$(id -u)" -f 'herdr server' | while read -r p; do
    tr '\0' '\n' </proc/"$p"/environ 2>/dev/null | grep -qx "HOME=$home" && echo "$p"
  done
}
cleanup() {
  h server stop >/dev/null 2>&1 || :
  "${tmx[@]}" kill-server 2>/dev/null || :
  rm -f "$home"
}
trap cleanup EXIT

mkdir -p "$work/home/.config/herdr" "$work/proj"
ln -sfn "$work/home" "$home"
printf 'onboarding = false\n[update]\nversion_check = false\nmanifest_check = false\n[ui.sound]\nenabled = false\n' \
  >"$work/home/.config/herdr/config.toml"
printf 'hello\n' >"$work/proj/notes.txt"
h plugin link "$here" >/dev/null

client
p1=$(h pane list | jq -r '.result.panes[0].pane_id')
p2=$(h tab create --workspace "${p1%%:*}" --cwd "$work/proj" --no-focus | jq -r .result.root_pane.pane_id)
p3=$(h workspace create --cwd "$work/proj" --no-focus | jq -r .result.root_pane.pane_id)
p4=$(h pane split "$p3" --direction right --no-focus | jq -r .result.pane.pane_id)
h pane run "$p1" " cd '$work/proj' && htop" >/dev/null
h pane run "$p2" ' top' >/dev/null
h pane run "$p3" ' vim notes.txt' >/dev/null
h pane run "$p4" ' sleep 999' >/dev/null
sleep 1.5
h plugin action invoke devicki.respawn.save >/dev/null
sleep 1

# The "reboot".
srv=$(test_server)
[ -n "$srv" ] && [ "$(wc -l <<<"$srv")" -eq 1 ] || { echo "FAIL: test server not identified: '$srv'" >&2; exit 1; }
kill -TERM "$srv"
"${tmx[@]}" kill-server 2>/dev/null
for _ in $(seq 25); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done

client
sleep 4
fail=0
check() {
  local got
  got=$(fg_of "$1")
  [ "$got" = "$2" ] || { echo "FAIL: $1 runs '$got', want '$2'" >&2; fail=1; }
}
check "$p1" htop            # the focused pane
check "$p2" top             # a background tab, never focused since the restart
check "$p3" "vim notes.txt" # a background workspace
case "$(fg_of "$p4")" in *sleep*) echo "FAIL: $p4 relaunched sleep, which is off the allowlist" >&2; fail=1 ;; esac
[ "$fail" -eq 0 ] && echo PASS
exit "$fail"
