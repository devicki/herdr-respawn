#!/usr/bin/env bash
# Re-record docs/demo.svg: an isolated Herdr (its own HOME, with this plugin linked and reviewr
# installed) holding a made-up project: a stand-in Claude Code started with
# --dangerously-skip-permissions beside a reviewr diff, and lazygit in another tab. The server is
# killed like a reboot and a client starts it again. The screen is captured from tmux and
# render.py turns the frames into SVG. Needs tmux, jq, git, lazygit, vim, python3 and network
# access (reviewr's install downloads its binary). DEMO_WORK picks the scratch dir.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${DEMO_WORK:-$(mktemp -d)}
herdr=$(command -v herdr)
# Unix socket paths must stay under 108 bytes, so HOME is a short symlink to the scratch dir.
home="${XDG_RUNTIME_DIR:-/tmp}/herdr-respawn-demo"
tmx=(tmux -L herdr-respawn-demo -f /dev/null)
cols=132 rows=32

mkdir -p "$work/home/.config/herdr" "$work/home/.config/lazygit" "$work/home/.local/state/lazygit" "$work/projects"
ln -sfn "$work/home" "$home"
cp "$here/config.toml" "$work/home/.config/herdr/config.toml"
cp "$here/bashrc" "$work/home/.bashrc"
printf 'update:\n  method: never\n' >"$work/home/.config/lazygit/config.yml"
# lazygit's first-run popups (intro, breaking changes) would cover the demo.
printf 'startuppopupversion: 5\nlastversion: %s\n' "$(lazygit --version | sed -n 's/.*version=\([^,]*\).*/\1/p')" \
  >"$work/home/.local/state/lazygit/state.yml"

# shop-api: a short history and an uncommitted change for reviewr and lazygit to show.
api="$work/projects/shop-api"
mkdir -p "$api/src/auth"
g() { git -C "$api" -c user.name=demo -c user.email=demo@example.com "$@"; }
g init -q -b main
printf 'export function issue(user) {\n  return sign({ sub: user.id }, "15m")\n}\n' >"$api/src/auth/session.ts"
g add -A && g commit -q -m "Issue short-lived access tokens"
printf 'export function refresh(token) {\n  const claims = verify(token)\n  return issue(claims.sub)\n}\n' >"$api/src/auth/refresh.ts"
g add -A && g commit -q -m "Add refresh endpoint"
g checkout -q -b feat/token-rotation
printf 'export function refresh(token) {\n  const claims = verify(token)\n  if (revoked.has(claims.jti)) throw new Error("reused")\n  revoked.add(claims.jti)\n  return issue(claims.sub)\n}\n' >"$api/src/auth/refresh.ts"
web="$work/projects/shop-web"
mkdir -p "$web/src"
git -C "$web" init -q -b main
printf 'export function App() {\n  return <Header />\n}\n' >"$web/src/App.tsx"

env_=(env -i HOME="$home" PATH="$here/bin:${herdr%/*}:/usr/local/bin:/usr/bin:/bin" TERM=xterm-256color
  LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 SHELL=/bin/bash USER=demo LOGNAME=demo)
h() { "${env_[@]}" "$herdr" "$@"; }
client() {
  "${tmx[@]}" new-session -d -s demo -c "$api" -x "$cols" -y "$rows" "$(printf '%q ' "${env_[@]}") $herdr"
  "${tmx[@]}" set -g status off
  "${tmx[@]}" set -g escape-time 0
  for _ in $(seq 50); do h pane list >/dev/null 2>&1 && return; sleep 0.2; done
  echo "server did not come up" >&2
  exit 1
}
server_pid() {
  pgrep -u "$(id -u)" -f 'herdr server' | while read -r p; do
    tr '\0' '\n' </proc/"$p"/environ 2>/dev/null | grep -qx "HOME=$home" && echo "$p"
  done
}
cleanup() {
  kill "${capture:-}" 2>/dev/null || :
  h server stop >/dev/null 2>&1 || :
  "${tmx[@]}" kill-server 2>/dev/null || :
  rm -f "$home"
}
trap cleanup EXIT

h plugin link "$repo" >/dev/null
h plugin install persiyanov/herdr-reviewr --ref v0.38.0 --yes >/dev/null
client

# The scene.
h tab rename w1:t1 agent >/dev/null
h plugin pane open --plugin persiyanov.reviewr --entrypoint pane --placement split --target-pane w1:p1 \
  --direction right --cwd "$api" --no-focus >/dev/null # w1:p2
h tab create --workspace w1 --cwd "$api" --label git --no-focus >/dev/null # w1:t2, w1:p3
h pane run w1:p3 ' lazygit' >/dev/null
h workspace create --cwd "$web" --label shop-web --no-focus >/dev/null # w2
h pane run w2:p1 ' vim src/App.tsx' >/dev/null
h pane run w1:p1 ' claude --dangerously-skip-permissions' >/dev/null
h tab focus w1:t1 >/dev/null
sleep 3
h plugin action invoke devicki.respawn.save >/dev/null
sleep 1

# Snapshot the screen every 50ms while a client is up; render.py drops the unchanged ones.
frames="$work/frames.log"
: >"$frames"
capture_loop() {
  while :; do
    if "${tmx[@]}" has-session -t demo 2>/dev/null; then
      printf '@@frame %s\n' "$(($(date +%s%N) / 1000000))"
      "${tmx[@]}" capture-pane -t demo -p -e -N
    fi
    sleep 0.05
  done >>"$frames"
}
# A title card for the gap while no client is attached.
card() {
  local top=$(((rows - 5) / 2)) i
  printf '@@frame %s\n' "$(($(date +%s%N) / 1000000))"
  for ((i = 0; i < rows; i++)); do
    case $((i - top)) in
    0) printf '%*s\e[1m%s\e[0m\n' $(((cols - 40) / 2)) '' "The Herdr server restarts, like a reboot" ;;
    2) printf '%*s\e[2m%s\e[0m\n' $(((cols - 42) / 2)) '' "Every process in every pane is gone now..." ;;
    4) printf '%*s\e[36m%s\e[0m\n' $(((cols - 45) / 2)) '' "...and respawn brings them back on startup." ;;
    *) echo ;;
    esac
  done
}

capture_loop &
capture=$!
sleep 3.5                           # claude in bypass mode beside the reviewr diff
h tab focus w1:t2 >/dev/null
sleep 2.5                           # lazygit
h tab focus w1:t1 >/dev/null
sleep 1.2

# The "reboot": SIGTERM the server; the client dies with it.
srv=$(server_pid)
[ -n "$srv" ] && [ "$(wc -l <<<"$srv")" -eq 1 ] || { echo "demo server not identified" >&2; exit 1; }
kill -TERM "$srv"
"${tmx[@]}" kill-server 2>/dev/null || :
for _ in $(seq 25); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
card >>"$frames"
sleep 3.2
client                              # a new client starts the server; respawn's startup hook runs
sleep 5                             # back without a keystroke: the toast, claude still in bypass mode, reviewr
h tab focus w1:t2 >/dev/null
sleep 2.5                           # lazygit
h tab focus w1:t1 >/dev/null
sleep 1.5
kill "$capture"
wait "$capture" 2>/dev/null || :

python3 "$here/render.py" "$frames" "$repo/docs/demo.svg" "$cols" "$rows"
echo "wrote $repo/docs/demo.svg ($(du -h "$repo/docs/demo.svg" | cut -f1))"
