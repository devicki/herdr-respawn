# herdr-respawn

English | [한국어](README.ko.md)

![herdr-respawn: a restart takes every pane process down, and respawn brings them back](docs/demo.svg)

Keep working where you left off after a [Herdr](https://herdr.dev) server restart or a machine reboot.

Herdr restores workspaces, tabs, panes and cwd on its own, and resumes supported agents without their launch flags. Every other pane comes back as a bare shell. respawn brings back what was running in them, as soon as the server is back and without a keystroke:

- **TUIs** you had open: lazygit, vim, htop, yazi and the rest of the [allowlist](#allowlist)
- **Plugin panes**, such as a [reviewr](https://github.com/persiyanov/herdr-reviewr) diff beside an agent
- **Claude Code's agent view** (`claude agents`)
- With one line of config, **agents with their launch flags**: a `claude --dangerously-skip-permissions` session comes back still bypassing permissions ([details](#agents-keep-their-launch-flags))

There is nothing to set up for the first three. Install it, and it starts saving right away.

## Install

```sh
herdr plugin install devicki/herdr-respawn --ref v0.7.2
```

`--ref` pins a release. Leave it out to track `main` instead. Releases are listed under [tags](https://github.com/devicki/herdr-respawn/tags).

Install it in every account that runs a Herdr server. Each server, and each named session, keeps its own snapshot. The first restore happens at the next restart after the plugin has saved once, which it does as soon as you move focus.

**Compatibility**: Linux and macOS. It needs `bash` (3.2, the macOS default, is enough) and `jq` 1.6 or newer (`brew install jq` on macOS). Windows is not supported; run Herdr in WSL there.

## How it works

- **Save**: on every `pane.focused`, `tab.focused`, `workspace.focused`, `pane.closed` and `pane.agent_status_changed` event, each pane's foreground command (argv) and cwd are written to the plugin state dir if the command is on the allowlist. Agents are saved with their session id ([details](#agents-keep-their-launch-flags)) and plugin panes as their plugin ([details](#plugin-panes)). Run the `respawn: save now` action to save on demand.
- **Restore**: the startup hook runs once Herdr has restored the session. It types each saved command back into its pane with `herdr pane run`, in background tabs and workspaces too, but only when that pane is back at a bare shell prompt: nothing in the foreground but an interactive shell. Shells that are still starting (rc files, a fish config, prompt tools) get up to 15 seconds to settle; a pane that is still running something after that (a script, an `sh -c` job, a live handoff) is left alone.
  - The command gets a leading space so it stays out of shell history (fish by default, bash with `HISTCONTROL=ignorespace`/`ignoreboth`, zsh with `setopt HIST_IGNORE_SPACE`).
  - It is prefixed with `cd <dir> &&` when the pane's shell is not already in the saved directory. If that directory no longer exists, the command does not run.
  - An absolute program path that is gone after the reboot (or lives under a temp dir or `/nix/store`) is replaced by the program name, so the shell's `PATH` finds it.
- **Shutdown**: a client still connected while the machine shuts down (an SSH session from a laptop, say) can start Herdr again in the middle of it. That server then sees every pane killed: it would persist each one as closed, emptying workspaces, and saves would record the dying panes. So on systemd, from the moment logind announces a shutdown (the signal Herdr itself saves on, up to 30 s before systemd starts stopping anything), respawn saves nothing and stops such a server as soon as it starts, which saves the layout it just loaded; the snapshot waits for the start after boot.
- A corrupt snapshot is moved aside to `<file>.bad` and saving starts fresh. Snapshots of named sessions deleted since are removed at startup.

### Restore notification

respawn posts a toast such as `respawn: 4 pane(s) restored` with the names of what came back. Herdr's toasts are off by default, and Herdr shows one only to a client that is attached when the server starts. To see it:

```toml
[ui.toast]
delivery = "herdr"      # or "terminal" / "system" for a desktop notification
```

With [herdr-pager](https://github.com/devicki/herdr-pager) installed and enabled, your phone hears about it too, whether or not a client is attached:

```
🔄 [work] Herdr restarted · respawn restored 4 pane(s)
claude x2, lazygit, persiyanov.reviewr
```

It goes out with herdr-pager's own settings and language (`lang = ko` in `pager.conf` for Korean), and names the session when it is a named one. There is nothing to set up, and without herdr-pager nothing changes.

## Allowlist

Only these commands are relaunched, since rerunning an arbitrary command (`git push`, a migration) is not safe:

```
lazygit lazydocker tig gitui vim nvim vi hx micro nano emacs htop btop top yazi ranger lf nnn k9s
```

Customize the list in `$(herdr plugin config-dir devicki.respawn)/allowlist`, for example `~/.config/herdr/plugins/config/devicki.respawn/allowlist`. The plugin creates it the first time it runs, with the built-in list and the syntax in comments. Put one name per line: a plain name adds a command, `!name` removes one. Names are matched against the basename of the command the shell started in the pane, not the processes it spawns, so lazygit's own `git log` runs never replace lazygit.

```
# dev servers I always want back
npm
# never relaunch top
!top
```

## Agents keep their launch flags

Herdr resumes Claude Code, Codex, Devin and other agents on its own, but always as a plain `claude --resume <id>`, so the flags they were started with are lost. A session opened with `claude --dangerously-skip-permissions` (a `claude-yolo` alias, say) comes back asking for permissions again: Claude Code deliberately does not restore bypass mode on resume.

To keep the flags, turn off Herdr's own agent resume in `config.toml`:

```toml
[session]
resume_agents_on_restore = false
```

respawn then resumes Claude Code, Codex and Devin itself, with the session id Herdr recorded and these launch flags:

| Agent | Resumed as | Flags kept |
| --- | --- | --- |
| Claude Code | `claude <flags> --resume <id>` | `--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions`, `--permission-mode`, `--model` |
| Codex | `codex resume <flags> <id>` | `--dangerously-bypass-approvals-and-sandbox`, `-s`/`--sandbox`, `-a`/`--ask-for-approval`, `-m`/`--model` |
| Devin | `devin <flags> --resume <id>` | `--permission-mode`, `--model` |

Other flags and any prompt are dropped. With Herdr's agent resume on (the default), respawn leaves agents alone, since two resumers would type into the same pane.

- With it off, agents other than these three come back as plain shells. Keep it on if you use them.
- Agents start one at a time, 100 ms apart, as Herdr's own resume does. Each brings up its runtime and MCP servers, and Claude Code sessions share config files, so many at once make a load spike. With many sessions, widen the gap with Herdr's own setting, which respawn follows:

  ```toml
  [session]
  startup_per_agent_delay_ms = 1000
  ```

  TUIs and plugin panes start at once.
- Since Herdr 0.9.2, an agent can report its own resume command, flags included. Such agents keep their launch flags with Herdr's resume on and need nothing from respawn.
- The agent has to run under its own name (`claude`, `codex`, `devin`); one started through a wrapper such as `npx` is not recognized.
- Claude Code's agent view (`claude agents`) manages background sessions and has no session of its own, so it is relaunched exactly as it was started, flags included. This works with Herdr's agent resume on as well.

## Plugin panes

Herdr brings plugin panes, such as a [reviewr](https://github.com/persiyanov/herdr-reviewr) diff beside an agent or a memex sidebar, back as plain shells too. respawn recognises them by their command living in the plugin's directory, and starts the plugin's current command for that pane again with the environment Herdr gives plugin panes, so quitting it closes the pane as before.

- The entrypoint's command has to be a program or script in the plugin's directory (run directly or by an interpreter such as `bash script.sh`). One that stays in a wrapper, such as `sh -c '...'` without `exec`, is not recognised.
- It uses the pane entrypoint the pane was opened with. When a plugin has several entrypoints with the same command (memex's desk, palette and sidebar), that is read from the process environment.
- A plugin that has since been disabled or uninstalled is skipped.
- The allowlist does not apply to plugin panes.

## Check what is saved

The snapshot is a JSON file per server or named session in the plugin state dir:

```sh
herdr plugin action invoke devicki.respawn.save; sleep 1
jq -r '.panes[] | "\(.pane) \(.plugin // .agent // "-") \(.entrypoint // (.argv | join(" ")))"' \
  ~/.local/state/herdr/plugins/devicki.respawn/*.json
```

```
w1:p1 claude claude --dangerously-skip-permissions --resume 3f2c9a
w1:p2 persiyanov.reviewr pane
w1:p3 - lazygit
```

`herdr plugin log list --plugin devicki.respawn` shows each save and restore run, including what the last restore brought back.

## Limitations

- Environment variables are not restored (virtualenvs, `NVIM_APPNAME` set by an alias, ...).
- A command started in the focused pane is saved on the next focus change or agent state change. If the machine may go down before then, run `respawn: save now`, or bind it to a key:

  ```toml
  [[keys.command]]
  key = "prefix+shift+s"
  type = "plugin_action"
  command = "devicki.respawn.save"
  ```

- The snapshot stores full argv. Keep secrets out of command-line arguments of allowlisted programs.

## Tip

To also restore each pane's recent screen output, turn on Herdr's own history replay in `config.toml`. It is off by default because it writes pane output to disk:

```toml
[experimental]
pane_history = true
```

## Update and uninstall

Herdr has no update command; reinstall at the new tag. The allowlist, the saved snapshot and the enabled state survive a reinstall, and `herdr plugin list` shows the installed version.

```sh
herdr plugin install devicki/herdr-respawn --ref v0.7.2 --yes
herdr plugin uninstall devicki.respawn
```

Uninstalling leaves the allowlist in `~/.config/herdr/plugins/config/devicki.respawn` and the snapshots in `~/.local/state/herdr/plugins/devicki.respawn`; delete them if you do not reinstall.

## Development

```sh
herdr plugin link .
./test.sh   # isolated Herdr started by its client; reboot-like SIGTERM; expect the relaunch
```

`test.sh` runs TUIs in the focused pane, a background tab and a background workspace, next to a command off the allowlist, a stand-in `claude --dangerously-skip-permissions` that must come back with its flag, Claude's agent view, and a stand-in plugin pane opened on the second of two entrypoints that share one command, and checks that the two agents start `startup_per_agent_delay_ms` apart and that a stand-in herdr-pager is handed the restore notification, then fakes a shutdown and checks that a server started during it is stopped at once with the snapshot untouched. It needs `tmux`, `jq`, `htop`, `vim`, `python3` and procps (`top`, `pgrep`), runs on Linux only (it finds its server through `/proc`), and never touches your own Herdr session.

`docs/demo/record.sh` re-records `docs/demo.svg` in an isolated Herdr with a made-up project (needs `tmux`, `lazygit` and network access for reviewr).

To release, bump `version` in `herdr-plugin.toml`, update the `--ref` in both READMEs, commit, then `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`.

## License

MIT
