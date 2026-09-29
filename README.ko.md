# herdr-respawn

[English](README.md) | 한국어

[Herdr](https://herdr.dev) 서버를 재시작하거나 머신을 재부팅한 뒤에도 lazygit, 에디터 같은 TUI를 원래 페인에서 다시 실행해 주는 플러그인이에요.

Herdr는 워크스페이스, 탭, 페인, cwd, 그리고 지원하는 에이전트 세션(Claude Code, Codex 등)을 스스로 복원해요. 하지만 그 밖의 페인은 모두 빈 셸로 돌아와요. 이 플러그인은 각 페인에서 실행 중이던 명령 중 허용 목록에 있는 것을 서버가 다시 뜨자마자 자동으로 실행해요.

## 설치

```sh
herdr plugin install devicki/herdr-respawn --ref v0.2.2
```

`--ref`는 설치할 릴리스를 고정해요. 빼면 `main` 브랜치의 최신 코드가 설치돼요. 릴리스 목록은 [tags](https://github.com/devicki/herdr-respawn/tags)에서 볼 수 있어요.

`bash`와 `jq`가 필요해요. Herdr 서버를 쓰는 계정마다 설치하세요. 서버마다 스냅샷을 따로 저장해요.

## 동작 방식

- **저장**: `pane.focused`, `tab.focused`, `workspace.focused`, `pane.closed`, `pane.agent_status_changed` 이벤트가 발생할 때마다 각 페인의 포그라운드 명령(argv)과 cwd를 확인해요. 허용 목록에 있는 명령이면 플러그인 상태 폴더에 저장해요. 바로 저장하고 싶으면 `respawn: save now` 액션을 실행하세요.
- **복원**: Herdr가 세션 복원을 마치면 시작 훅이 실행돼요. 저장해 둔 명령을 `herdr pane run`으로 원래 페인에 다시 입력하고, 뒤에 있는 탭이나 워크스페이스의 페인도 포함돼요. 단, 그 페인이 빈 셸 프롬프트로 돌아왔을 때만 입력해요. 라이브 핸드오프처럼 이미 뭔가 실행 중인 페인은 건드리지 않아요.
  - 명령 앞에 공백을 붙여 셸 히스토리에 남지 않게 해요(bash는 `HISTCONTROL=ignorespace`/`ignoreboth`, zsh는 `setopt HIST_IGNORE_SPACE`).
  - 페인의 셸이 저장된 폴더에 있지 않으면 `cd <폴더> &&`를 앞에 붙여요. 그 폴더가 없어졌다면 명령은 실행되지 않아요.
  - 재부팅 후 사라진 절대 경로의 프로그램(임시 폴더나 `/nix/store` 아래 경로 포함)은 프로그램 이름으로 바꿔서, 셸의 `PATH`에서 찾게 해요.
  - 복원 결과를 토스트로 알려 줘요. 서버가 시작될 때 연결된 클라이언트가 있어야 Herdr가 토스트를 보여 줘요.
- 스냅샷 파일이 깨졌으면 `<파일>.bad`로 옮기고 새로 저장을 시작해요. 삭제된 네임드 세션의 스냅샷은 시작할 때 정리해요.

## 허용 목록

아무 명령이나 다시 실행하면(`git push`, 마이그레이션 등) 위험하기 때문에, 아래 명령만 다시 실행해요.

```
lazygit lazydocker tig gitui vim nvim vi hx micro nano emacs htop btop top yazi ranger lf nnn k9s
```

목록은 `$(herdr plugin config-dir devicki.respawn)/allowlist`에서 바꿀 수 있어요. 한 줄에 이름 하나씩 쓰면 추가되고, `!이름`으로 쓰면 목록에서 빠져요. 이름은 프로그램 파일 이름과 비교해요.

```
# 항상 다시 띄우고 싶은 개발 서버
npm
# top은 다시 실행하지 않기
!top
```

## 한계

- 환경 변수는 복원되지 않아요(가상 환경, alias로 지정한 `NVIM_APPNAME` 등).
- 포커스된 페인에서 시작한 명령은 다음 포커스 이동이나 에이전트 상태 변화 때 저장돼요. 그 전에 머신이 꺼질 수 있다면 `respawn: save now`를 실행하거나 단축키로 지정해 두세요.

  ```toml
  [[keys.command]]
  key = "prefix+shift+s"
  type = "plugin_action"
  command = "devicki.respawn.save"
  ```

- 스냅샷에는 argv 전체가 저장돼요. 허용 목록에 있는 프로그램의 명령줄 인자에는 비밀값을 넣지 마세요.

## 팁

각 페인의 최근 화면 내용까지 복원하려면 `config.toml`에서 Herdr 자체의 화면 기록 기능을 켜세요. 페인 출력이 디스크에 저장되기 때문에 기본으로 꺼져 있어요.

```toml
[experimental]
pane_history = true
```

## 업데이트와 삭제

Herdr에는 업데이트 명령이 없어서, 새 태그로 다시 설치하면 돼요. 다시 설치해도 허용 목록, 저장된 스냅샷, 켜짐/꺼짐 상태는 그대로 남아요. 설치된 버전은 `herdr plugin list`로 확인할 수 있어요.

```sh
herdr plugin install devicki/herdr-respawn --ref v0.2.2 --yes
herdr plugin uninstall devicki.respawn
```

## 개발

```sh
herdr plugin link .
./test.sh   # 클라이언트로 띄운 격리된 Herdr에서 재부팅처럼 SIGTERM을 보내고 재실행을 확인해요
```

`test.sh`는 포커스된 페인, 뒤에 있는 탭, 뒤에 있는 워크스페이스에서 TUI를 실행하고, 허용 목록에 없는 명령도 하나 함께 띄워요. `tmux`, `htop`, `vim`이 필요하고, 사용 중인 Herdr 세션은 건드리지 않아요.

릴리스할 때는 `herdr-plugin.toml`의 `version`을 올리고, 두 README의 `--ref`를 바꿔 커밋한 뒤 `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`를 실행하세요.

## 라이선스

MIT
