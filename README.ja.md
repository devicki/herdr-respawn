# herdr-respawn

[English](README.md) | [한국어](README.ko.md) | 日本語 | [繁體中文](README.zh-TW.md)

![herdr-respawn: 再起動でペインのプロセスがすべて終了しても、respawn が元に戻します](docs/demo.svg)

[Herdr](https://herdr.dev) サーバーの再起動やマシンの再起動のあとも、中断したところから作業を続けられるようにするプラグインです。

Herdr はワークスペース、タブ、ペイン、cwd を自分で復元し、対応しているエージェントも再開します。ただしエージェントは起動時のフラグなしで再開され、それ以外のペインはすべて空のシェルに戻ります。respawn は、サーバーが戻るとすぐに、キー入力なしで、それらのペインで動いていたものを元に戻します。

- 開いていた **TUI**: lazygit、vim、htop、yazi など、[許可リスト](#許可リスト)にあるもの
- エージェントの横に開いた [reviewr](https://github.com/persiyanov/herdr-reviewr) の diff などの **プラグインペイン**
- **Claude Code の agent view** (`claude agents`)
- 設定を 1 行追加すると、**起動フラグを保ったままのエージェント**: `claude --dangerously-skip-permissions` のセッションは、権限確認をスキップしたまま戻ります([詳細](#エージェントの起動フラグを保持))

最初の 3 つは設定不要です。インストールすると、すぐに保存が始まります。

## インストール

```sh
herdr plugin install devicki/herdr-respawn --ref v0.7.4
```

`--ref` はリリースを固定します。省略すると、代わりに `main` を追従します。リリースの一覧は [tags](https://github.com/devicki/herdr-respawn/tags) にあります。

Herdr サーバーを動かすすべてのアカウントにインストールしてください。サーバーごと、また名前付きセッションごとに、それぞれのスナップショットを保持します。最初の復元は、プラグインが一度保存したあとの次の再起動で行われます。保存はフォーカスを移した時点ですぐに行われます。

**互換性**: Linux と macOS で動作します。`bash`(macOS 標準の 3.2 で十分です)と `jq` 1.6 以降(macOS では `brew install jq`)が必要です。Windows には対応していないため、WSL で Herdr を実行してください。

## 仕組み

- **保存**: `pane.focused`、`tab.focused`、`workspace.focused`、`pane.closed`、`pane.agent_status_changed` の各イベントのたびに、各ペインのフォアグラウンドのコマンド(argv)と cwd を確認し、そのコマンドが許可リストにあればプラグインの状態ディレクトリに書き込みます。エージェントはセッション id とともに([詳細](#エージェントの起動フラグを保持))、プラグインペインはどのプラグインかとして([詳細](#プラグインペイン))保存します。すぐに保存したいときは `respawn: save now` アクションを実行してください。
- **復元**: Herdr がセッションの復元を終えると、起動フックが実行されます。保存したコマンドを `herdr pane run` で元のペインに入力し直します。背後のタブやワークスペースのペインも対象です。ただし、そのペインが空のシェルプロンプトに戻っているとき(フォアグラウンドに対話シェルしかないとき)に限ります。まだ起動中のシェル(rc ファイル、fish の設定、プロンプトツール)は、落ち着くまで最大 15 秒待ちます。そのあとも何かを実行中のペイン(スクリプト、`sh -c` のジョブ、ライブのハンドオフ)には手を付けません。
  - コマンドの先頭にスペースを付け、シェルの履歴に残らないようにします(fish は標準で、bash は `HISTCONTROL=ignorespace`/`ignoreboth`、zsh は `setopt HIST_IGNORE_SPACE` のとき)。
  - ペインのシェルが保存したディレクトリにいなければ、先頭に `cd <ディレクトリ> &&` を付けます。そのディレクトリがもう存在しない場合、コマンドは実行されません。
  - 再起動後に存在しなくなったプログラムの絶対パス(一時ディレクトリや `/nix/store` の下にあるものも含む)は、プログラム名に置き換え、シェルの `PATH` で見つかるようにします。
- **シャットダウン**: マシンのシャットダウン中にまだ接続しているクライアント(たとえばノート PC からの SSH セッション)が、その途中で Herdr を再び起動することがあります。そのサーバーはすべてのペインが強制終了されるのを目にし、それぞれを閉じたものとして記録してワークスペースを空にしてしまいます。保存も終了しかけのペインを記録してしまいます。そこで systemd 環境では、logind がシャットダウンを通知した時点から(Herdr 自身が保存に使うのと同じ信号で、systemd が何かを停止し始める最大 30 秒前です)、respawn は何も保存せず、そのようなサーバーを起動直後に停止します。停止時には、読み込んだばかりのレイアウトが保存されます。スナップショットは起動後の開始を待ちます。
- スナップショットが壊れている場合は `<ファイル>.bad` に移動し、保存をやり直します。その後削除された名前付きセッションのスナップショットは、起動時に削除します。

### 復元通知

respawn は、`respawn: 4 pane(s) restored` のようなトーストで、戻ってきたものの名前を知らせます。Herdr のトーストは標準では無効で、サーバーの起動時に接続しているクライアントにしか表示されません。表示するには、次のように設定します。

```toml
[ui.toast]
delivery = "herdr"      # デスクトップ通知にするなら "terminal" または "system"
```

[herdr-pager](https://github.com/devicki/herdr-pager) をインストールして有効にしておくと、クライアントが接続しているかどうかに関係なく、スマートフォンにも通知が届きます。

```
🔄 [work] Herdr 再起動 · respawn がペイン 4 個を復元
claude x2, lazygit, persiyanov.reviewr
```

通知は herdr-pager 自身の設定と言語(`pager.conf` の `lang = ko`、`ja`、`zh-TW` で韓国語、日本語、繁体字中国語)で送られ、名前付きセッションの場合はセッション名も付きます。設定は不要で、herdr-pager がなければ何も変わりません。

## 許可リスト

任意のコマンド(`git push` やマイグレーションなど)を再実行するのは安全ではないため、次のコマンドだけを再起動します。

```
lazygit lazydocker tig gitui vim nvim vi hx micro nano emacs htop btop top yazi ranger lf nnn k9s
```

リストは `$(herdr plugin config-dir devicki.respawn)/allowlist`(たとえば `~/.config/herdr/plugins/config/devicki.respawn/allowlist`)で変更できます。このファイルは、プラグインが初めて実行されたときに、組み込みのリストと書き方をコメントに記して作成されます。1 行に 1 つずつ名前を書きます。名前だけを書くとコマンドが追加され、`!名前` と書くと除外されます。名前は、シェルがペインで起動したコマンドのベース名と照合し、そのコマンドが起動するプロセスは見ません。そのため、lazygit 自身が実行する `git log` が lazygit の代わりになることはありません。

```
# いつも戻してほしい開発サーバー
npm
# top は再起動しない
!top
```

## エージェントの起動フラグを保持

Herdr は Claude Code、Codex、Devin などのエージェントを自分で再開しますが、常に `claude --resume <id>` のようにフラグなしで再開するため、起動時に付けたフラグは失われます。たとえば `claude-yolo` エイリアスなどで `claude --dangerously-skip-permissions` として開いたセッションは、戻ると再び権限の確認を求めます。Claude Code は、再開時にバイパスモードを意図的に復元しないためです。

フラグを保つには、`config.toml` で Herdr 自身のエージェント再開を無効にします。

```toml
[session]
resume_agents_on_restore = false
```

すると respawn が、Herdr が記録したセッション id と次の起動フラグで、Claude Code、Codex、Devin を自分で再開します。

| エージェント | 再開に使うコマンド | 保持するフラグ |
| --- | --- | --- |
| Claude Code | `claude <フラグ> --resume <id>` | `--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions`, `--permission-mode`, `--model` |
| Codex | `codex resume <フラグ> <id>` | `--dangerously-bypass-approvals-and-sandbox`, `-s`/`--sandbox`, `-a`/`--ask-for-approval`, `-m`/`--model` |
| Devin | `devin <フラグ> --resume <id>` | `--permission-mode`, `--model` |

それ以外のフラグやプロンプトは除きます。Herdr のエージェント再開が有効なとき(標準)は、respawn はエージェントに手を付けません。2 つの仕組みが同じペインに入力してしまうためです。

- 無効にすると、この 3 つ以外のエージェントは空のシェルとして戻ります。それらを使う場合は有効のままにしてください。
- エージェントは Herdr 自身の再開と同じく、100 ms 間隔で 1 つずつ起動します。各エージェントはランタイムと MCP サーバーを立ち上げ、Claude Code のセッションは設定ファイルを共有するため、一度に多数を起動すると負荷が急増します。セッションが多い場合は、Herdr 自身の設定で間隔を広げてください。respawn もこの値に従います。

  ```toml
  [session]
  startup_per_agent_delay_ms = 1000
  ```

  TUI とプラグインペインはすぐに起動します。
- Herdr 0.9.2 以降、エージェントはフラグを含む自分の再開コマンドを報告できます。そのようなエージェントは、Herdr の再開を有効にしたままでも起動フラグが保たれ、respawn は必要ありません。
- エージェントは自分の名前(`claude`、`codex`、`devin`)で実行されている必要があります。`npx` などのラッパー経由で起動したものは認識されません。
- Claude Code の agent view(`claude agents`)はバックグラウンドのセッションを管理する画面で、それ自身のセッションを持たないため、フラグも含めて起動時のとおりに再実行します。これは Herdr のエージェント再開が有効なときにも動作します。

## プラグインペイン

Herdr は、エージェントの横に開いた [reviewr](https://github.com/persiyanov/herdr-reviewr) の diff や memex のサイドバーなどのプラグインペインも、空のシェルとして戻します。respawn は、コマンドがプラグインのディレクトリ内にあることでそれらを見分け、そのペインに対応するプラグインの現在のコマンドを、Herdr がプラグインペインに渡す環境で再び起動します。そのため、終了すると以前と同じくペインも閉じます。

- エントリーポイントのコマンドは、プラグインのディレクトリ内のプログラムかスクリプトである必要があります(直接実行するか、`bash script.sh` のようにインタープリターで実行)。`exec` なしの `sh -c '...'` のように、ラッパーの中にとどまるものは認識されません。
- ペインを開いたときのペインのエントリーポイントを使います。1 つのプラグインに同じコマンドのエントリーポイントが複数ある場合(memex の desk、palette、sidebar)は、プロセスの環境から読み取ります。
- その後無効化またはアンインストールされたプラグインはスキップします。
- 許可リストはプラグインペインには適用されません。

## 保存内容の確認

スナップショットは、プラグインの状態ディレクトリに、サーバーまたは名前付きセッションごとに 1 つの JSON ファイルとして保存されます。

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

`herdr plugin log list --plugin devicki.respawn` で、保存と復元の実行記録を確認できます。最後の復元で何が戻ったかも表示されます。

## 制限事項

- 環境変数は復元されません(仮想環境、エイリアスで設定した `NVIM_APPNAME` など)。
- フォーカス中のペインで起動したコマンドは、次のフォーカス移動かエージェントの状態変化のときに保存されます。その前にマシンが停止するおそれがある場合は、`respawn: save now` を実行するか、キーに割り当ててください。

  ```toml
  [[keys.command]]
  key = "prefix+shift+s"
  type = "plugin_action"
  command = "devicki.respawn.save"
  ```

- スナップショットには argv 全体が保存されます。許可リストにあるプログラムのコマンドライン引数に、秘密情報を含めないでください。

## ヒント

各ペインの最近の画面出力も復元するには、`config.toml` で Herdr 自身の履歴再生を有効にします。ペインの出力をディスクに書き込むため、標準では無効になっています。

```toml
[experimental]
pane_history = true
```

## 更新とアンインストール

Herdr には更新コマンドがないため、新しいタグで再インストールします。許可リスト、保存されたスナップショット、有効/無効の状態は再インストール後も残ります。インストール済みのバージョンは `herdr plugin list` で確認できます。

```sh
herdr plugin install devicki/herdr-respawn --ref v0.7.4 --yes
herdr plugin uninstall devicki.respawn
```

アンインストールしても、許可リスト(`~/.config/herdr/plugins/config/devicki.respawn`)とスナップショット(`~/.local/state/herdr/plugins/devicki.respawn`)は残ります。再インストールしない場合は削除してください。

## 開発

```sh
herdr plugin link .
./test.sh   # クライアントから起動した隔離環境の Herdr に再起動のような SIGTERM を送り、再実行を確認します
```

`test.sh` は、フォーカス中のペイン、背後のタブ、背後のワークスペースで TUI を実行し、あわせて許可リストにないコマンド、フラグを保ったまま戻る必要がある代役の `claude --dangerously-skip-permissions`、Claude の agent view、同じコマンドを共有する 2 つのエントリーポイントのうち 2 つ目で開いた代役のプラグインペインも起動します。そして 2 つのエージェントが `startup_per_agent_delay_ms` の間隔で起動すること、代役の herdr-pager に復元通知が渡されることを確認します。最後にシャットダウンを模擬し、その間に起動したサーバーがすぐに停止され、スナップショットが変更されていないことを確認します。`tmux`、`jq`、`htop`、`vim`、`python3`、procps(`top`、`pgrep`)が必要で、`/proc` を通じて自分のサーバーを見つけるため Linux でのみ動作します。使用中の Herdr セッションには一切手を付けません。

`docs/demo/record.sh` は、架空のプロジェクトを使った隔離環境の Herdr で `docs/demo.svg` を録画し直します(`tmux`、`lazygit`、reviewr のためのネットワーク接続が必要です)。

リリースするには、`herdr-plugin.toml` の `version` を上げ、すべての README の `--ref` を更新してコミットし、`git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z` を実行します。

## ライセンス

MIT
