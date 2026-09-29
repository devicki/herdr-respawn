#!/usr/bin/env bash
# respawn.sh save     snapshot each pane's allowlisted foreground command
# respawn.sh restore  relaunch them after a server restart (startup hook)
set -uo pipefail

# herdr runs plugin commands with a minimal PATH; ensure jq resolves on common installs.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

H="${HERDR_BIN_PATH:-herdr}"
sock="${HERDR_SOCKET_PATH:?run from herdr}"
dir="${HERDR_PLUGIN_STATE_DIR:?run from herdr}"
# The state dir is shared by every named session, so key the file by the session's directory.
state="$dir/$(printf %s "${sock%/*}" | tr / _).json"
# The server creates its socket at startup, so the socket mtime identifies one server run.
instance=$(stat -c %Y "$sock" 2>/dev/null || stat -f %m "$sock") || exit 1

# A corrupt snapshot would block every save below forever; set it aside and start fresh.
if [ -f "$state" ] && ! jq -e .instance "$state" >/dev/null 2>&1; then
  mv -f "$state" "$state.bad"
fi

# Only these are relaunched: a TUI is safe to rerun, an arbitrary command (git push, a migration) is not.
# $HERDR_PLUGIN_CONFIG_DIR/allowlist adds names, one per line; `!name` removes one.
extra="${HERDR_PLUGIN_CONFIG_DIR:-}/allowlist"
allow_json=$(
  {
    echo "lazygit lazydocker tig gitui vim nvim vi hx micro nano emacs htop btop top yazi ranger lf nnn k9s"
    [ ! -f "$extra" ] || sed 's/#.*//' "$extra"
  } | tr -s '[:space:]' '\n' | jq -R . |
    jq -sc 'map(select(length > 0)) | map(select(startswith("!") | not)) - map(select(startswith("!")) | ltrimstr("!"))'
)

save() {
  # A snapshot from an earlier server run is still waiting for restore; overwriting it now
  # would record the bare shells the restart left behind. A minute into the run the startup
  # restore is not coming (the plugin was disabled at startup), so saving takes over.
  if [ -f "$state" ] && [ "$(jq -r .instance "$state")" != "$instance" ] &&
    [ $(($(date +%s) - instance)) -lt 60 ]; then
    return 0
  fi
  ids=$("$H" pane list | jq -r '.result.panes[].pane_id') || return 1
  tmp=$(mktemp "$state.XXXXXX") || return 1
  for p in $ids; do
    # `nvim --embed` is the child Neovim spawns for its UI; relaunching it would hang the pane.
    "$H" pane process-info --pane "$p" 2>/dev/null | jq -c --arg p "$p" --argjson allow "$allow_json" '
      first(.result.process_info.foreground_processes[]
        | select((.argv[0] // "" | split("/") | last | IN($allow[])) and (any(.argv[]; . == "--embed") | not)))
      | {pane: $p, argv, cwd}'
  done | jq -s --arg i "$instance" --arg d "${sock%/*}" '{instance: $i, session_dir: $d, panes: .}' >"$tmp" &&
    mv "$tmp" "$state" || rm -f "$tmp"
}

restore() {
  # Snapshots of named sessions deleted since (`herdr session delete` removes their directory).
  for f in "$dir"/*.json; do
    d=$(jq -r '.session_dir // empty' "$f" 2>/dev/null)
    [ -z "$d" ] || [ -d "$d" ] || rm -f "$f"
  done
  [ -f "$state" ] || return 0
  [ "$(jq -r .instance "$state")" != "$instance" ] || return 0
  restored=$(jq -c '.panes[]' "$state" | while IFS= read -r e; do
    p=$(jq -r .pane <<<"$e")
    info=$("$H" pane process-info --pane "$p" 2>/dev/null) || continue
    # Only type into a pane that came back as a bare shell; anything else is live (handoff) or reused.
    sh=$(jq -r '.result.process_info.foreground_processes[0].argv[0] // "" | split("/") | last | ltrimstr("-")' <<<"$info")
    case "$sh" in bash | zsh | fish | sh | dash | ksh) ;; *) continue ;; esac
    # A saved absolute path may be gone after a reboot (tmp mounts, Nix, AppImage); let the shell's PATH find it by name.
    a0=$(jq -r '.argv[0]' <<<"$e")
    case "$a0" in
    /tmp/* | /private/tmp/* | /var/folders/* | /private/var/folders/* | /nix/store/*) a0=${a0##*/} ;;
    /*) [ -x "$a0" ] || a0=${a0##*/} ;;
    esac
    cur=$(jq -r '.result.process_info.foreground_processes[0].cwd // ""' <<<"$info")
    # The leading space keeps the command out of shell history (bash ignorespace, zsh HIST_IGNORE_SPACE).
    cmd=$(jq -r --arg cur "$cur" --arg a0 "$a0" '.argv[0] = $a0
      | " " + (if .cwd != $cur then "cd \(.cwd | @sh) && " else "" end) + (.argv | @sh)' <<<"$e")
    "$H" pane run "$p" "$cmd" >/dev/null && printf '%s %s\n' "$p" "${a0##*/}"
  done)
  if [ -n "$restored" ]; then
    sed 's/^/restored /' <<<"$restored"
    "$H" notification show "respawn: $(grep -c '' <<<"$restored") pane(s) restored" \
      --body "$(cut -d' ' -f2 <<<"$restored" | sort | uniq -c | awk '{printf "%s%s", sep, $2 ($1 > 1 ? " x" $1 : ""); sep=", "}')" >/dev/null 2>&1 || :
  fi
  # Adopt the snapshot for this server run so saves resume.
  tmp=$(mktemp "$state.XXXXXX") && jq --arg i "$instance" '.instance = $i' "$state" >"$tmp" && mv "$tmp" "$state"
}

case "${1:-}" in
save) save ;;
restore) restore ;;
*) echo "usage: respawn.sh save|restore" >&2; exit 2 ;;
esac
