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
defaults="lazygit lazydocker tig gitui vim nvim vi hx micro nano emacs htop btop top yazi ranger lf nnn k9s"
extra="${HERDR_PLUGIN_CONFIG_DIR:-}/allowlist"
# Leave a commented-out example on first run, so the file is there to find and edit.
if [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ ! -e "$extra" ]; then
  cat 2>/dev/null >"$extra" <<EOF || :
# herdr-respawn allowlist: which pane commands come back after a Herdr restart or reboot.
#
# These are relaunched already; you don't need to list them:
#   $defaults
#
# This file only changes that list. Leave it as is to keep the defaults.
# One name per line, matched against the program's file name; lines starting with # are ignored.
#   name    relaunch this command as well
#   !name   never relaunch it, even though it is listed above
#
# Examples:
# npm
# !top
EOF
fi
allow_json=$(
  {
    echo "$defaults"
    [ ! -f "$extra" ] || sed 's/#.*//' "$extra"
  } | tr -s '[:space:]' '\n' | jq -R . |
    jq -sc 'map(select(length > 0)) | map(select(startswith("!") | not)) - map(select(startswith("!")) | ltrimstr("!"))'
)

# One pane's snapshot entry, from its process info.
# - Judge the command the shell started, the process group leader, not whatever it spawned:
#   lazygit runs `git log` in the same group, and saving that would relaunch the wrong thing.
#   Without a leader, fall back to any member; `nvim --embed` is Neovim's own UI child.
# - An agent with a reported session is saved as the command that resumes it, keeping the
#   launch flags that set its permissions and model (`claude-yolo` aliases
#   `claude --dangerously-skip-permissions`; Herdr's own resume would drop that).
pick='
  def agents: {
    claude: {pre: [], post: ["--resume"], keep: {"--dangerously-skip-permissions": 0,
      "--allow-dangerously-skip-permissions": 0, "--permission-mode": 1, "--model": 1}},
    codex: {pre: ["resume"], post: [], keep: {"--dangerously-bypass-approvals-and-sandbox": 0,
      "-s": 1, "--sandbox": 1, "-a": 1, "--ask-for-approval": 1, "-m": 1, "--model": 1}},
    devin: {pre: [], post: ["--resume"], keep: {"--permission-mode": 1, "--model": 1}}
  };
  # The flags in $keep, with as many values as each takes; everything else (prompts, the old
  # --resume/--continue) is dropped.
  def carry($keep): reduce .[1:][] as $t ({out: [], take: 0};
    if .take > 0 then .out += [$t] | .take -= 1
    elif $keep | has($t | split("=")[0]) then
      .out += [$t] | .take = (if $t | contains("=") then 0 else $keep[$t | split("=")[0]] end)
    else . end) | .out;
  def name: .argv[0] // "" | split("/") | last;
  .result.process_info as $i
  | [$i.foreground_processes[] | select(.pid == $i.foreground_process_group_id)] as $lead
  | (if ($lead | length) > 0 then $lead else $i.foreground_processes end) as $procs
  | $sessions[$p] as $s
  | if $s and (agents | has($s.agent)) and any($procs[]; name == $s.agent) then
      agents[$s.agent] as $a
      | first($procs[] | select(name == $s.agent))
      | {pane: $p, cwd, agent: $s.agent,
         argv: ([.argv[0]] + $a.pre + (.argv | carry($a.keep)) + $a.post + [$s.value])}
    else
      first($procs[] | select((name | IN($allow[])) and (any(.argv[]; . == "--embed") | not)))
      | {pane: $p, argv, cwd}
    end'

save() {
  # A snapshot from an earlier server run is still waiting for restore; overwriting it now
  # would record the bare shells the restart left behind. A minute into the run the startup
  # restore is not coming (the plugin was disabled at startup), so saving takes over.
  if [ -f "$state" ] && [ "$(jq -r .instance "$state")" != "$instance" ] &&
    [ $(($(date +%s) - instance)) -lt 60 ]; then
    return 0
  fi
  panes=$("$H" pane list) || return 1
  # Agent sessions Herdr's integrations reported, by pane.
  sessions=$(jq -c '[.result.panes[] | select(.agent_session) | {key: .pane_id, value: .agent_session}] | from_entries' <<<"$panes") || return 1
  tmp=$(mktemp "$state.XXXXXX") || return 1
  for p in $(jq -r '.result.panes[].pane_id' <<<"$panes"); do
    "$H" pane process-info --pane "$p" 2>/dev/null |
      jq -c --arg p "$p" --argjson allow "$allow_json" --argjson sessions "$sessions" "$pick"
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
  # Herdr resumes agents itself unless `[session] resume_agents_on_restore = false`. Two
  # resumers would type into each other's pane, so saved agents are ours only when it is off.
  cfg="${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"
  agents=false
  [ -f "$cfg" ] && awk '
    /^[[:space:]]*\[/ { t = $0; gsub(/[][[:space:]]/, "", t) }
    t == "session" && /^[[:space:]]*resume_agents_on_restore[[:space:]]*=[[:space:]]*false/ { off = 1 }
    t == "" && /^[[:space:]]*session\.resume_agents_on_restore[[:space:]]*=[[:space:]]*false/ { off = 1 }
    END { exit !off }' "$cfg" && agents=true
  restored=$(jq -c '.panes[]' "$state" | while IFS= read -r e; do
    p=$(jq -r .pane <<<"$e")
    [ "$agents" = true ] || [ -z "$(jq -r '.agent // empty' <<<"$e")" ] || continue
    info=$("$H" pane process-info --pane "$p" 2>/dev/null) || continue
    # Only type into a pane that came back as a bare shell; anything else is live (handoff) or reused.
    sh=$(jq -r '.result.process_info.foreground_processes[0].argv[0] // "" | split("/") | last | ltrimstr("-")' <<<"$info")
    # The leading ( on each pattern keeps bash 3.2, macOS's /bin/bash, parsing a case inside $( ).
    case "$sh" in (bash | zsh | fish | sh | dash | ksh) ;; (*) continue ;; esac
    # A saved absolute path may be gone after a reboot (tmp mounts, Nix, AppImage); let the shell's PATH find it by name.
    a0=$(jq -r '.argv[0]' <<<"$e")
    case "$a0" in
    (/tmp/* | /private/tmp/* | /var/folders/* | /private/var/folders/* | /nix/store/*) a0=${a0##*/} ;;
    (/*) [ -x "$a0" ] || a0=${a0##*/} ;;
    esac
    cur=$(jq -r '.result.process_info.foreground_processes[0].cwd // ""' <<<"$info")
    # The leading space keeps the command out of shell history (bash ignorespace, zsh HIST_IGNORE_SPACE).
    # Only words that need quoting get it: shells title the window with the typed line, and
    # title tools read 'lazygit' as something other than lazygit (herdr.auto-title nested it).
    cmd=$(jq -r --arg cur "$cur" --arg a0 "$a0" 'def q: if test("^[A-Za-z0-9_./:@%+=,-]+$") then . else @sh end;
      .argv[0] = $a0
      | " " + (if .cwd != $cur then "cd \(.cwd | q) && " else "" end) + (.argv | map(q) | join(" "))' <<<"$e")
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
