# herdr-respawn

English | [한국어](README.ko.md)

Bring back lazygit, editors and other TUIs in their panes after a [Herdr](https://herdr.dev) server restart or machine reboot.

Herdr already restores workspaces, tabs, panes, cwd and supported agent sessions (Claude Code, Codex, ...) on its own. Every other pane comes back as a bare shell. This plugin relaunches the allowlisted command that was running in each pane, automatically, as soon as the server is back.

## Install

```sh
herdr plugin install devicki/herdr-respawn --ref v0.2.4
```

`--ref` pins a release. Leave it out to track `main` instead. Releases are listed under [tags](https://github.com/devicki/herdr-respawn/tags).

Install it in every account that runs a Herdr server; each server keeps its own snapshot.

**Compatibility**: Linux and macOS. It needs `bash` (3.2, the macOS default, is enough) and `jq` (`brew install jq` on macOS). Windows is not supported; run Herdr in WSL there.

## How it works

- **Save**: on every `pane.focused`, `tab.focused`, `workspace.focused`, `pane.closed` and `pane.agent_status_changed` event, each pane's foreground command (argv) and cwd are written to the plugin state dir if the command is on the allowlist. Run the `respawn: save now` action to save on demand.
- **Restore**: the startup hook runs once Herdr has restored the session. It types each saved command back into its pane with `herdr pane run`, in background tabs and workspaces too, but only when that pane is back at a bare shell prompt. A pane that is still running something, for example after a live handoff, is left alone.
  - The command gets a leading space so it stays out of shell history (bash `HISTCONTROL=ignorespace`/`ignoreboth`, zsh `setopt HIST_IGNORE_SPACE`).
  - It is prefixed with `cd <dir> &&` when the pane's shell is not already in the saved directory. If that directory no longer exists, the command does not run.
  - An absolute program path that is gone after the reboot (or lives under a temp dir or `/nix/store`) is replaced by the program name, so the shell's `PATH` finds it.
  - A toast summarizes what was restored. Herdr only shows it if a client is attached when the server starts.
- A corrupt snapshot is moved aside to `<file>.bad` and saving starts fresh. Snapshots of named sessions deleted since are removed at startup.

## Allowlist

Only these commands are relaunched, since rerunning an arbitrary command (`git push`, a migration) is not safe:

```
lazygit lazydocker tig gitui vim nvim vi hx micro nano emacs htop btop top yazi ranger lf nnn k9s
```

Customize the list in `$(herdr plugin config-dir devicki.respawn)/allowlist`, for example `~/.config/herdr/plugins/config/devicki.respawn/allowlist`. The plugin creates it the first time it runs, with the built-in list and the syntax in comments. Put one name per line: a plain name adds a command, `!name` removes one. Names are matched against the program's basename.

```
# dev servers I always want back
npm
# never relaunch top
!top
```

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
herdr plugin install devicki/herdr-respawn --ref v0.2.4 --yes
herdr plugin uninstall devicki.respawn
```

## Development

```sh
herdr plugin link .
./test.sh   # isolated Herdr started by its client; reboot-like SIGTERM; expect the relaunch
```

`test.sh` runs TUIs in the focused pane, a background tab and a background workspace, next to a command off the allowlist. It needs `tmux`, `htop` and `vim`, runs on Linux only (it finds its server through `/proc`), and never touches your own Herdr session.

To release, bump `version` in `herdr-plugin.toml`, update the `--ref` in both READMEs, commit, then `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`.

## License

MIT
