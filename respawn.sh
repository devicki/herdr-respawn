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
# - A plugin pane (reviewr, a memex sidebar) is saved as its plugin; Herdr brings those back
#   as shells too. Its command is recognised by living in the plugin's root.
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
  | ([$plugins[] as $pl | $procs[]
      | select((.argv[0] // "" | startswith($pl.root + "/"))
          or ((name | IN("sh", "bash", "dash", "zsh", "node", "python", "python3", "bun", "deno", "ruby", "perl"))
            and (.argv[1] // "" | startswith($pl.root + "/"))))
      | {pl: $pl, proc: .}] | first) as $hit
  | if any($procs[]; name == "claude" and any(.argv[1:][]; . == "agents")) then
      # Claude Code'"'"'s agent view (`claude agents`) manages background sessions: it has no
      # session of its own to resume, and starting it again is safe, so it comes back as it
      # was started, flags included. Marked as an agent when Herdr tracks one there too.
      first($procs[] | select(name == "claude")) | {pane: $p, argv, cwd} + (if $s then {agent: $s.agent} else {} end)
    elif $s and (agents | has($s.agent)) and any($procs[]; name == $s.agent) then
      agents[$s.agent] as $a
      | first($procs[] | select(name == $s.agent))
      | {pane: $p, cwd, agent: $s.agent,
         argv: ([.argv[0]] + $a.pre + (.argv | carry($a.keep)) + $a.post + [$s.value])}
    elif $hit then
      {pane: $p, cwd: $hit.proc.cwd, plugin: $hit.pl.id, pid: $hit.proc.pid, entrypoints: $hit.pl.panes}
    else
      first($procs[] | select((name | IN($allow[])) and (any(.argv[]; . == "--embed") | not)))
      | {pane: $p, argv, cwd}
    end'

# Quote only words that need it: shells title the window with the typed line, and title tools
# read 'lazygit' as something other than lazygit (herdr.auto-title nested it).
q='def q: if test("^[A-Za-z0-9_./:@%+=,-]+$") then . else @sh end; '

# A process's HERDR_PLUGIN_ENTRYPOINT_ID: from /proc on Linux, `ps -E` on macOS.
entrypoint_of() {
  { tr '\0' '\n' <"/proc/$1/environ" || ps -E -o command= -p "$1" | tr ' ' '\n'; } 2>/dev/null |
    sed -n 's/^HERDR_PLUGIN_ENTRYPOINT_ID=//p' | head -n1
}

# One writer at a time: a save from an event must not overwrite the snapshot while the startup
# restore is still working through it. A lock left by a crash expires after 5 minutes.
lockdir="$state.lock"
take_lock() { # [seconds to wait]
  local i=0
  [ -z "$(find "$lockdir" -maxdepth 0 -mmin +5 2>/dev/null)" ] || rmdir "$lockdir" 2>/dev/null
  while ! mkdir "$lockdir" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -le $((${1:-0} * 10)) ] || return 1
    sleep 0.1
  done
}

# A Herdr that starts while the machine shuts down (a client reconnecting starts it) is about to
# see every pane killed. Saving then would record the dying panes as bare shells, and Herdr would
# persist each one as closed, emptying workspaces. So during a shutdown nothing is saved, and
# such a server is stopped at once: stopping saves the layout it just loaded, and the snapshot
# waits for the real start after boot. A shutdown starts when logind announces it
# (PreparingForShutdown, the signal Herdr saves on); systemd itself reports `stopping` only once
# logind has waited out its inhibitor delay, up to 30 s later, and the dangerous server starts in
# between. systemd only; elsewhere this never triggers.
shutting_down() {
  ${RESPAWN_BUSCTL:-busctl} --timeout=2 get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager PreparingForShutdown 2>/dev/null | grep -q true ||
    [ "$(${RESPAWN_SYSTEMCTL:-systemctl} is-system-running 2>/dev/null)" = stopping ]
}

# A save that finds the lock taken is skipped: the next event saves again.
save() {
  ! shutting_down || return 0
  take_lock || return 0
  save_locked
  local rc=$?
  rmdir "$lockdir" 2>/dev/null
  return "$rc"
}

restore() {
  if shutting_down; then
    echo "the machine is shutting down: stopping this server, restore waits for the next start"
    "$H" server stop >/dev/null 2>&1
    return 0
  fi
  take_lock 30 || return 1
  restore_locked
  local rc=$?
  rmdir "$lockdir" 2>/dev/null
  return "$rc"
}

save_locked() {
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
  # Plugins with pane entrypoints, to recognise their panes by where the command lives.
  plugins=$("$H" plugin list --json 2>/dev/null |
    jq -c '[.result.plugins[] | select((.panes // []) | length > 0) | {id: .plugin_id, root: .plugin_root, panes: [.panes[].id]}]')
  [ -n "$plugins" ] || plugins='[]'
  tmp=$(mktemp "$state.tmp.XXXXXX") || return 1
  for p in $(jq -r '.result.panes[].pane_id' <<<"$panes"); do
    e=$("$H" pane process-info --pane "$p" 2>/dev/null |
      jq -c --arg p "$p" --argjson allow "$allow_json" --argjson sessions "$sessions" --argjson plugins "$plugins" "$pick")
    [ -n "$e" ] || continue
    # A plugin pane: which entrypoint it runs is only in its environment when the plugin has
    # several with one command (memex's desk, palette and sidebar).
    if [ -n "$(jq -r '.plugin // empty' <<<"$e")" ]; then
      e=$(jq -c --arg ep "$(entrypoint_of "$(jq -r .pid <<<"$e")")" '
        (if .entrypoints | index($ep) then $ep elif (.entrypoints | length) == 1 then .entrypoints[0] else null end) as $ep
        | if $ep then del(.pid, .entrypoints) + {entrypoint: $ep} else empty end' <<<"$e")
      [ -n "$e" ] || continue
    fi
    printf '%s\n' "$e"
  done | jq -s --arg i "$instance" --arg d "${sock%/*}" '{instance: $i, session_dir: $d, panes: .}' >"$tmp" &&
    mv "$tmp" "$state" || rm -f "$tmp"
}

# The phone hears about a restore too when herdr-pager is installed and enabled. It runs detached
# with pager's own settings and language, so a slow or missing ntfy server never holds up the restore.
notify_pager() { # count, what came back
  local root pcfg lang title session=""
  root=$(jq -r 'first(.result.plugins[] | select(.plugin_id == "devicki.pager" and .enabled)) | .plugin_root' \
    <<<"$plugins_now" 2>/dev/null)
  [ -n "$root" ] && [ -f "$root/bin/herdr-pager" ] || return 0
  pcfg=$("$H" plugin config-dir devicki.pager 2>/dev/null) && [ -n "$pcfg" ] || return 0
  case "$sock" in (*/sessions/*/*) session=" ($(basename "${sock%/*}"))" ;; esac
  lang=$(sed -n 's/^[[:space:]]*lang[[:space:]]*=[[:space:]]*//p' "$pcfg/pager.conf" 2>/dev/null | tail -n1)
  case "$lang" in
  (ko*) title="Herdr 재시작$session · respawn이 페인 $1개 복원" ;;
  (*) title="Herdr restarted$session · respawn restored $1 pane(s)" ;;
  esac
  HERDR_PLUGIN_CONFIG_DIR=$pcfg HERDR_PLUGIN_STATE_DIR="${dir%/*}/devicki.pager" \
    nohup bash "$root/bin/herdr-pager" send -t "$title" -g arrows_counterclockwise "$2" >/dev/null 2>&1 &
}

restore_locked() {
  # Housekeeping: snapshots of named sessions deleted since (`herdr session delete` removes
  # their directory), unreadable snapshots of any session, and temp files a crash left behind.
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    if ! jq -e .instance "$f" >/dev/null 2>&1; then mv -f "$f" "$f.bad"; continue; fi
    d=$(jq -r '.session_dir // empty' "$f" 2>/dev/null)
    [ -z "$d" ] || [ -d "$d" ] || rm -f "$f"
  done
  find "$dir" -maxdepth 1 -name '*.tmp.*' -mmin +5 -exec rm -f {} + 2>/dev/null
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
  # Agents start one at a time, as Herdr's own resume does: each brings up a runtime and its MCP
  # servers, and Claude Code sessions share config files. Herdr's
  # `[session] startup_per_agent_delay_ms` (default 100) sets the gap for both.
  gap=$(awk '
    /^[[:space:]]*\[/ { t = $0; gsub(/[][[:space:]]/, "", t) }
    (t == "session" && sub(/^[[:space:]]*startup_per_agent_delay_ms[[:space:]]*=[[:space:]]*/, "")) ||
    (t == "" && sub(/^[[:space:]]*session\.startup_per_agent_delay_ms[[:space:]]*=[[:space:]]*/, "")) { ms = $0 + 0; set = 1 }
    END { if (!set || ms < 0) ms = 100; printf "%.3f", ms / 1000 }' "$cfg" 2>/dev/null)
  [ -n "$gap" ] || gap=0.100
  started=""
  plugins_now=$("$H" plugin list --json 2>/dev/null)
  restored=$(jq -c '.panes[]' "$state" | while IFS= read -r e; do
    p=$(jq -r .pane <<<"$e")
    [ "$agents" = true ] || [ -z "$(jq -r '.agent // empty' <<<"$e")" ] || continue
    info=$("$H" pane process-info --pane "$p" 2>/dev/null) || continue
    # Only type into a pane that came back as a bare shell: the shell alone in the foreground,
    # with options at most. `sh -c ...` or `bash script.sh` is running something, and text typed
    # now would run when it ends. Anything else is live (handoff) or reused.
    jq -e '.result.process_info.foreground_processes as $f | ($f | length) == 1
      and ($f[0].argv[0] // "" | split("/") | last | ltrimstr("-") | IN("bash", "zsh", "fish", "sh", "dash", "ksh"))
      and ($f[0].argv[1:] | all(startswith("-") and . != "-c"))' <<<"$info" >/dev/null || continue
    cur=$(jq -r '.result.process_info.foreground_processes[0].cwd // ""' <<<"$info")
    # The leading space keeps the command out of shell history (fish, bash ignorespace, zsh HIST_IGNORE_SPACE).
    plug=$(jq -r '.plugin // empty' <<<"$e")
    if [ -n "$plug" ]; then
      # The plugin's current command for that entrypoint (its root moves on reinstall), with the
      # environment Herdr gives plugin panes; exec, so quitting it closes the pane as before.
      a0=$plug
      cmd=$(jq -r --argjson e "$e" --arg cur "$cur" --arg cfg "$("$H" plugin config-dir "$plug" 2>/dev/null)" \
        --arg st "${dir%/*}/$plug" "$q"'
        first(.result.plugins[] | select(.plugin_id == $e.plugin and .enabled)) as $pl
        | first($pl.panes[] | select(.id == $e.entrypoint)) as $ep
        | " " + (if $e.cwd != $cur then "cd \($e.cwd | q) && " else "" end) + "exec "
          + (["env", "HERDR_PLUGIN_ID=\($pl.plugin_id)", "HERDR_PLUGIN_ROOT=\($pl.plugin_root)",
              "HERDR_PLUGIN_CONFIG_DIR=\($cfg)", "HERDR_PLUGIN_STATE_DIR=\($st)",
              "HERDR_PLUGIN_ENTRYPOINT_ID=\($ep.id)"] + $ep.command | map(q) | join(" "))' <<<"$plugins_now")
      [ -n "$cmd" ] || continue
    else
      # A saved absolute path may be gone after a reboot (tmp mounts, Nix, AppImage); let the shell's PATH find it by name.
      a0=$(jq -r '.argv[0]' <<<"$e")
      case "$a0" in
      (/tmp/* | /private/tmp/* | /var/folders/* | /private/var/folders/* | /nix/store/*) a0=${a0##*/} ;;
      (/*) [ -x "$a0" ] || a0=${a0##*/} ;;
      esac
      cmd=$(jq -r --arg cur "$cur" --arg a0 "$a0" "$q"'
        .argv[0] = $a0
        | " " + (if .cwd != $cur then "cd \(.cwd | q) && " else "" end) + (.argv | map(q) | join(" "))' <<<"$e")
    fi
    if jq -e '.agent or (.argv[0] // "" | split("/") | last | IN("claude", "codex", "devin"))' <<<"$e" >/dev/null; then
      [ -z "$started" ] || sleep "$gap"
      started=1
    fi
    "$H" pane run "$p" "$cmd" >/dev/null && printf '%s %s\n' "$p" "${a0##*/}"
  done)
  if [ -n "$restored" ]; then
    sed 's/^/restored /' <<<"$restored"
    n=$(grep -c '' <<<"$restored")
    what=$(cut -d' ' -f2 <<<"$restored" | sort | uniq -c | awk '{printf "%s%s", sep, $2 ($1 > 1 ? " x" $1 : ""); sep=", "}')
    "$H" notification show "respawn: $n pane(s) restored" --body "$what" >/dev/null 2>&1 || :
    notify_pager "$n" "$what"
  fi
  # Adopt the snapshot for this server run so saves resume.
  tmp=$(mktemp "$state.tmp.XXXXXX") && jq --arg i "$instance" '.instance = $i' "$state" >"$tmp" && mv "$tmp" "$state"
}

case "${1:-}" in
save) save ;;
restore) restore ;;
*) echo "usage: respawn.sh save|restore" >&2; exit 2 ;;
esac
