#!/usr/bin/env bash
# resurrect.sh save     snapshot each pane's allowlisted foreground command
# resurrect.sh restore  relaunch them after a server restart (startup hook)
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

# Only these are relaunched: a TUI is safe to rerun, an arbitrary command (git push, a migration) is not.
# Extra names go in $HERDR_PLUGIN_CONFIG_DIR/allowlist, one per line.
allow="lazygit lazydocker tig gitui vim nvim vi hx micro nano emacs htop btop top yazi ranger lf nnn k9s"
extra="${HERDR_PLUGIN_CONFIG_DIR:-}/allowlist"
[ -f "$extra" ] && allow="$allow $(sed 's/#.*//' "$extra")"
allow_json=$(printf '%s\n' $allow | jq -R . | jq -sc .)

save() {
  # A snapshot from an earlier server run is still waiting for restore; overwriting it now
  # would record the bare shells the restart left behind.
  if [ -f "$state" ] && [ "$(jq -r .instance "$state" 2>/dev/null)" != "$instance" ]; then
    return 0
  fi
  ids=$("$H" pane list | jq -r '.result.panes[].pane_id') || return 1
  tmp=$(mktemp "$state.XXXXXX") || return 1
  for p in $ids; do
    "$H" pane process-info --pane "$p" 2>/dev/null | jq -c --arg p "$p" --argjson allow "$allow_json" '
      first(.result.process_info.foreground_processes[]
        | select(.argv[0] // "" | split("/") | last | IN($allow[])))
      | {pane: $p, argv, cwd}'
  done | jq -s --arg i "$instance" '{instance: $i, panes: .}' >"$tmp" && mv "$tmp" "$state" || rm -f "$tmp"
}

restore() {
  [ -f "$state" ] || return 0
  [ "$(jq -r .instance "$state")" != "$instance" ] || return 0
  jq -c '.panes[]' "$state" | while IFS= read -r e; do
    p=$(jq -r .pane <<<"$e")
    info=$("$H" pane process-info --pane "$p" 2>/dev/null) || continue
    # Only type into a pane that came back as a bare shell; anything else is live (handoff) or reused.
    sh=$(jq -r '.result.process_info.foreground_processes[0].argv[0] // "" | split("/") | last | ltrimstr("-")' <<<"$info")
    case "$sh" in bash | zsh | fish | sh | dash | ksh) ;; *) continue ;; esac
    cmd=$(jq -r --arg cur "$(jq -r '.result.process_info.foreground_processes[0].cwd // ""' <<<"$info")" '
      (if .cwd != $cur then "cd \(.cwd | @sh) && " else "" end) + (.argv | @sh)' <<<"$e")
    "$H" pane run "$p" "$cmd" >/dev/null && printf 'restored %s: %s\n' "$p" "$cmd"
  done
  # Adopt the snapshot for this server run so saves resume.
  tmp=$(mktemp "$state.XXXXXX") && jq --arg i "$instance" '.instance = $i' "$state" >"$tmp" && mv "$tmp" "$state"
}

case "${1:-}" in
save) save ;;
restore) restore ;;
*) echo "usage: resurrect.sh save|restore" >&2; exit 2 ;;
esac
