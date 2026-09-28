# herdr-resurrect

Bring back lazygit, editors and other TUIs in their panes after a [Herdr](https://herdr.dev) server restart or machine reboot.

Herdr already restores workspaces, tabs, panes, cwd and supported agent sessions (Claude Code, Codex, ...) on its own. Every other pane comes back as a bare shell. This plugin relaunches the allowlisted command that was running in each pane.

## Install

```sh
herdr plugin install devicki/herdr-resurrect
```

Requires `bash` and `jq`.

## How it works

- **Save**: on every `pane.focused`, `tab.focused`, `workspace.focused` and `pane.closed` event, each pane's foreground command and cwd are written to the plugin state dir if the command is on the allowlist. Run the `resurrect: save now` action to save on demand.
- **Restore**: the startup hook runs once Herdr has restored the session. It types each saved command back into its pane with `herdr pane run`, but only when that pane is back at a bare shell prompt. A pane that is still running something, for example after a live handoff, is left alone.

## Allowlist

Only these commands are relaunched, since rerunning an arbitrary command (`git push`, a migration) is not safe:

```
lazygit lazydocker tig gitui vim nvim vi hx micro nano emacs htop btop top yazi ranger lf nnn k9s
```

Add more names, one per line, to `$(herdr plugin config-dir devicki.resurrect)/allowlist`:

```
# dev servers I always want back
npm
```

## Tips

- To also restore each pane's recent screen output, turn on Herdr's own history replay in `config.toml`. It is off by default because it writes pane output to disk:

  ```toml
  [experimental]
  pane_history = true
  ```

- A command started in the focused pane is saved on the next focus change. If the machine may go down before then, run `resurrect: save now` or bind it to a key:

  ```toml
  [[keys.command]]
  key = "prefix+shift+s"
  type = "plugin_action"
  command = "devicki.resurrect.save"
  ```

## Development

```sh
herdr plugin link .
./test.sh   # throwaway named session: save, restart, expect the relaunch
```

## License

MIT
