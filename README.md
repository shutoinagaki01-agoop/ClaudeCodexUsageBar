# ClaudeCodexUsageBar

macOS のメニューバーに **Claude** と **Codex** の残り使用量と次のリセット時刻を常時表示する、Swift 製の軽量アプリです。

```
┌─────────────────────────────────────────────────────────────────────┐
│  ...   Claude 90%·14:00 | Codex 67%·11:00       🔋 Wi-Fi 🔍 🔔 │
└─────────────────────────────────────────────────────────────────────┘
```

メニューを開くと、Claude / Codex それぞれの 5h・7d 各枠の残量と直近のリセット時刻、現在のプランが見られます。  
(メニューバーには5hの残量とリセット時刻が表示されます)

## 必要環境

- macOS 12 (Monterey) 以降
- Xcode Command Line Tools (`xcode-select --install`) もしくは Xcode 本体
- Claude 機能を使う場合: Claude Code / Claude CLI でログインし、CLI の初回セットアップを完了済み
- Codex 機能を使う場合: Codex CLI でログイン済み

Claude の認証が切れた場合、本アプリは公式 Claude CLI に認証更新を委譲できます。アプリ自身がリフレッシュトークンを保持することはありません。
詳細は [認証情報の扱い](#認証情報の扱い) を参照してください。

## 事前準備
アプリのインストール前後は問いません。Claude / Codex CLI が保存する OAuth 認証情報を利用するため、各 CLI の準備を行ってください。

### 1. Claude

```bash
claude
```

画面の案内に従って通常の入力画面（`? for shortcuts` が表示される画面）まで進み、`/exit` で終了してください。未ログインの場合は、途中でログインを案内されます。
本アプリは初回セットアップ画面を自動操作しません。この操作は初回のみ必要で、アクセストークンが切れるたびに `claude` を手動起動する必要はありません。

### 2. Codex

```bash
codex login
```

## 認証情報の扱い

本アプリ自身は Claude Code / Codex CLI が保存した OAuth 認証情報を **読むだけ** です。書き込みも、リフレッシュトークンを使った直接更新も行いません。

| サービス | 読み取り元 | 方法 |
|---|---|---|
| Claude | `~/.claude/.credentials.json`、無ければ Keychain の `Claude Code-credentials` | `/usr/bin/security` をサブプロセスとして実行 |
| Codex | `~/.codex/auth.json` | ファイル読み取り |

アクセストークンの更新は Claude Code / Codex CLI に任せています。第三者アプリがリフレッシュトークンを直接使うと、サーバ側でトークンがローテーションされた際に CLI 側に古いトークンが残り、**CLI をログアウトさせてしまう**ためです。

Claude のアクセストークンが期限切れ、または Usage API から HTTP 401 を返された場合は、次の手順で復旧します。

1. Claude 所有の設定を読み、CLI の初回セットアップが完了済みか確認
2. 公式 `claude` コマンドを PTY（疑似端末）上で起動
3. 起動出力を確認し、初回設定・再ログイン・その他の対話要求なら入力せず停止
4. 通常画面に `/status` を 1 回だけ送信し、Claude Code 自身に通常の OAuth 更新を行わせる
5. 認証情報が実際に変わったことを最大 2 秒待って確認
6. 新しい認証情報で Usage API を 1 回だけ再試行

初回セットアップが未完了、または設定ファイルを安全に判定できない場合、CLI は起動せず復旧手順を表示します。事前判定を通過した後でも、初回セットアップ画面、再ログイン画面、意味を安全に確定できない対話画面を検知した場合は、キーを送らず直ちに停止します。タイマーによる Enter 連打や、汎用的な `Press Enter to continue` への自動応答は行いません。本アプリのキー入力によってテーマやログイン方法を選んだり、OAuth ブラウザ認証へ進めたりすることはありません。

`⌘R` の手動更新では、この委譲を常に許可します。無操作のまま自動復旧させたい場合は、メニューの **詳細設定 > Claude認証をバックグラウンドで更新** をオンにしてください。この設定は、バックグラウンドで CLI が起動して Keychain の確認画面を出す可能性があるため、既定ではオフです。

同時に複数の更新が走っても CLI は 1 回だけ起動します。成功後は 5 分、失敗後は 20 秒のクールダウンを設けています。CLI 起動後に認証情報が変わらなければ成功扱いにはしません。

CLI 実行後の更新待ちは、`~/.claude/.credentials.json` のファイル属性、または Keychain の復号を伴わない `mdat` メタデータだけを監視します。変更を検出した時だけ認証情報を 1 回復号するため、200ms ごとに Keychain のパスワード値を読み直すことはありません。また、PTY 出力は 1 回 64KB・累積 1MB に制限しています。

Codex は従来どおり直接更新せず、Codex CLI が更新した `~/.codex/auth.json` を読み直します。認証切れ時はメニューバーに `⚠︎` と復旧手順を表示します。


## アプリの起動

```bash
git clone https://github.com/shutoinagaki01-agoop/ClaudeCodexUsageBar.git # もしくは GitHub の Code > Download ZIP からダウンロード
cd ClaudeCodexUsageBar  # アプリの置き場所に移動
chmod +x build.sh
./build.sh
open build/ClaudeCodexUsageBar.app
```

## 更新ポリシー

| 項目 | 値 | 説明 |
|---|---|---|
| 通常時の自動更新間隔 | **JST 11:00–16:00 は 3 分、それ以外は 5 分** | 5h / 7d 枠ともに残量がある間 |
| 自動更新の時間帯 | **JST 09:30–21:00** | 深夜〜朝はサーバー負荷とレートリミットを避けるため停止 |
| 5h 枯渇時 | **次のリセット時刻まで待機**（取れない場合 1 時間後にリトライ） | 0% に張り付いている間に無駄打ちしない |
| 認証切れ時 | **10 分間隔** | 同じ失効トークンでは API を呼ばない。Claude は設定がオンなら公式 CLI に更新を委譲し、Codex は認証情報を読み直す |
| 時間帯外 | メニューバーに「自動更新は JST 09:30-21:00 のみ」と表示 | 手動更新（⌘R）はいつでも可能 |

### 取得間隔・時刻を変更したい場合

メニューバーのドロップダウンから **詳細設定 > 時間設定を変更…** を開くと、以下を変更できます。

- 起動時間（自動更新する時間帯）
- ピーク時間
- ピーク時の更新間隔
- 通常時の更新間隔

## weekly limit 通知

Claude / Codex の 7d 枠（weekly limit）が **50%以下**、**20%以下** になったタイミングで macOS 通知を出します。

- macOS の通知設定で `ClaudeCodexUsageBar` の通知を許可してください
- Claude は `7d` と `7d Fable` を個別に通知判定します


## ログイン時に自動起動

ビルドした `.app` を `/Applications` に入れたら:

1. **システム設定** → **一般** → **ログイン項目** を開く
2. `+` で `ClaudeCodexUsageBar.app` を追加

これで毎回 Mac 起動時にメニューバーへ常駐します。

## メニューの操作

ドロップダウン上部:

```
Claude: team             ← Claude プラン
  5h: 残り 100% · --:--
  7d: 残り 91% · 5/29 07:59
Claude 更新: 14:21:05

Codex: plus              ← Codex プラン
  5h: 残り 67% · 11:00
  7d: 残り 84% · 5/28 12:00
Codex 更新: 14:21:08
```

操作項目:

| 項目 | 動作 |
|---|---|
| Claude/Codexの残量を手動で更新 | 即座に両方を再取得 (`⌘R`)。Claude 認証切れ時は公式 CLI の PTY 更新も実行する |
| Codex 使用量をリセット: 残りN回 | 確認後、Codex のリセット可能回数を1回消費して使用量をリセット。残り0回の場合は押せません |
| 詳細設定 > Claude認証をバックグラウンドで更新 | 認証切れ時の自動更新で公式 Claude CLI を PTY 起動する（既定はオフ） |
| 詳細設定 > 時間設定を変更… | 起動時間、ピーク時間、更新間隔を変更 |
| 終了 | アプリ停止 (`⌘Q`) |


## トラブルシューティング

### Claude Code 起動ごとに Keychain のパスワードを聞かれる

```
security がキーチェーンに含まれるキー "Claude Code-credentials" へアクセスしようとしています。
許可するにはキーチェーン "ログイン" のパスワードを入力してください。
```

このダイアログが毎回出る場合、Keychain 項目のパーティションリストから `apple-tool:` が失われています。「常に許可」を押しても直りません（信頼アプリのリストとは別のゲートなので）。一度だけ次を実行してください。

```bash
security set-generic-password-partition-list -S apple-tool:,apple: -s "Claude Code-credentials" -a "$USER"
```

ログイン Keychain のパスワードを求められます（2 回聞かれることがあります）。

原因は本アプリの以前のバージョンです。`SecItemUpdate` で Keychain 項目を直接書き換えており、その際にパーティションリストがアプリ自身の署名ハッシュ（`cdhash:`）だけに狭められ、同じ項目を `/usr/bin/security` 経由で読む Claude Code が弾かれていました。ad-hoc 署名でビルドごとに `cdhash` が変わるため、再ビルドするたびに再発していました。

現在は `/usr/bin/security` 経由でしか Keychain を読まず、書き込みも行いません。**`./build.sh` で再ビルドしても再発しません。**

### その他

| 症状 | 対処 |
|---|---|
| `Claude auth not found. Run claude auth login first.` | `claude auth login` を実行する |
| `Claude CLI setup required. Run claude once in Terminal and complete the setup.` | ターミナルで `claude` を一度起動し、テーマやログイン方法などの初回設定を完了する。完了後は毎回の手動起動は不要 |
| `Claude login required. Run claude auth login in Terminal.` | refresh token の失効・取り消しなどで再ログインが必要。ターミナルで `claude auth login` を実行する。本アプリはブラウザ認証を自動開始しない |
| `Claude CLI needs interactive attention. ...` | ターミナルで `claude` を起動し、表示された案内を確認する。本アプリは内容を推測して Enter を送らない |
| `Claude auth expired. Use manual refresh, or run claude auth login.` | `⌘R` で公式 CLI への更新委譲を実行する。自動化する場合は詳細設定をオン。それでも直らなければ `claude auth login` |
| `Claude CLI auth refresh failed: ...` | ターミナルで `claude` が起動できるか確認し、直らなければ `claude auth login` |
| `Codex auth expired. Run codex login again.` | `codex login` を再実行する |
| 「Codex auth not found」 | `codex login` を実行して `~/.codex/auth.json` を作る |
| `Auth rejected (HTTP 401).` | 通常は表示されない内部エラー。出た場合は不具合として報告してください |
| `HTTP 403: ...` | 権限・プラン起因。Codex のリセットクレジットなど、契約プランで使えない機能を叩いた場合に出る |
| 「自動更新は JST 09:30-21:00 のみ」 | 仕様。手動更新したいときは ⌘R |
| weekly limit 通知が出ない | **システム設定 > 通知 > ClaudeCodexUsageBar** がONか確認。画面共有・ミラーリング中は **「画面をミラーリングまたは共有しているときに通知を許可」** もONにする |

## ライセンス

個人利用想定。再配布前に Claude および ChatGPT/Codex の利用規約を確認してください。
