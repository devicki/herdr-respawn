# Contributing to herdr-respawn

Thanks for helping. herdr-respawn relaunches TUIs, plugin panes and agents in their panes after a Herdr restart. Issues and pull requests are welcome, in English, Korean, Japanese or Chinese.

## Reporting a bug

Open an issue with the **Bug report** form. The versions it asks for and the exact steps matter most; the plugin log usually shows what went wrong: `herdr plugin log list --plugin devicki.respawn`.

## Changing something

1. Fork the repository and make a branch.
2. Keep the change small and focused. Match the style around it: short functions, comments that say why.
3. Run the tests and make sure they pass:
   ```sh
   ./test.sh
   ```
   They need tmux, jq, htop, vim, python3 and procps (`top`, `pgrep`); Linux only, since it finds its test server through `/proc`.
4. If you fix a bug, add a check to `test.sh` that fails without your fix.
5. Update `README.md` and its translations (`README.ko.md`, `README.ja.md`, `README.zh-TW.md`) together when behaviour or settings change. The English README is the main one; a translation update can be a rough one, it will be polished.
6. Open a pull request and say what changed and how you tested it.

## Things to keep in mind

- macOS runs these scripts with `/bin/bash` 3.2. Check that they still parse there:
  ```sh
  for f in respawn.sh test.sh; do docker run --rm -v "$PWD:/p:ro" bash:3.2 bash -n /p/$f; done
  ```
  In bash 3.2, a `case` inside `$( )` needs its patterns to start with `(`. Use BSD-compatible flags (no `sed -i`, no `\I`) and `stat -c %Y || stat -f %m`.
- respawn types commands into panes. Keep everything it types quoted (`q` in respawn.sh) and never relaunch a command off the allowlist.
- Test on an isolated Herdr (test.sh does) or a throwaway named session, never on the session you work in.

## Releases

The maintainer releases: bump `version` in `herdr-plugin.toml`, update the `--ref` in every README, then tag `vX.Y.Z`. You do not need to bump versions in a pull request.
