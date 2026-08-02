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
- Claude 機能を使う場合: Claude Code / Claude CLI でログイン済み
- Codex 機能を使う場合: Codex CLI でログイン済み

なお本アプリはアクセストークンの更新を行わないため、CLI 側を時々起動しておく必要があります。Claude については、これを回避する [長期トークン](#長期トークンを使う-claude-のみ) の設定も用意しています。詳細は [認証情報の扱い](#認証情報の扱い) を参照してください。

## 事前準備
Claude, Codex が保存する OAuth 認証情報を利用するため、以下のコマンドで事前にログインしてください。

1. Claude の認証

```bash
# Claude CLI 側でログイン
claude auth login
```

2. Codex の認証

```bash
# Codex CLI 側でログイン
codex login
```

## 認証情報の扱い

本アプリは Claude Code / Codex CLI が保存した OAuth 認証情報を **読むだけ** です。書き込みも更新も行いません。

| サービス | 読み取り元 | 方法 |
|---|---|---|
| Claude | 長期トークン（後述）→ `~/.claude/.credentials.json` → Keychain の `Claude Code-credentials` | `/usr/bin/security` をサブプロセスとして実行 |
| Codex | `~/.codex/auth.json` | ファイル読み取り |

アクセストークンの更新は Claude Code / Codex CLI に任せています。第三者アプリがリフレッシュトークンを使うと、サーバ側でトークンがローテーションされた際に CLI 側に古いトークンが残り、**CLI をログアウトさせてしまう**ためです。

この設計上の帰結として、**Claude Code / Codex CLI を長時間起動していないとアクセストークンが更新されず、使用量を表示できません**。Claude のアクセストークンの寿命は **8 時間** なので、夜間放置すると翌朝は失効した状態から始まります。その場合はメニューバーに `⚠︎` が付き、次のように表示されます。

- `Claude auth expired. Start Claude Code, or run claude auth login.`
- `Codex auth expired. Run codex login again.`

Claude Code / Codex CLI を起動すればトークンが更新され、次の自動更新（認証切れ中は 10 分間隔）で自動的に復帰します。⌘R を押せばその場で再試行します。

### 長期トークンを使う (Claude のみ)

`claude setup-token` が発行する **1 年有効の OAuth トークン** を本アプリに持たせると、上記の 8 時間問題を回避できます。Claude Code の起動状況から独立するため、8 時間ごとの更新は不要で、通常は最大 1 年間利用できます。ただし、途中で取り消された場合は再発行が必要です。

```bash
# 1. トークンを発行（ブラウザ認証が開きます）
claude setup-token

# 2. 表示されたトークンをキーチェーンに保存
#    -w を値なしで渡すと伏せ字入力になり、シェル履歴に残りません
security add-generic-password -U \
  -s "com.example.ClaudeCodexUsageBar" \
  -a "claude.oauth.longLivedToken" -w
```

保存後、メニューの「Claude/Codexの残量を手動で更新」を実行してください。メニュー先頭が `Claude · 長期トークン` になれば有効です。

やめる場合は項目を削除し、メニューの「Claude/Codexの残量を手動で更新」を実行するか、アプリを再起動してください。Claude Code 認証へ戻ります。

```bash
security delete-generic-password \
  -s "com.example.ClaudeCodexUsageBar" -a "claude.oauth.longLivedToken"
```

補足として、この経路でもトークンは **読むだけ** です。発行も保存も更新も行いません。トークンが拒否された場合は理由（401 かスコープ不足か）を表示し、以後は入れ替えられるまで API を呼びません。トークンを入れ替えれば、手動更新を待たずに次の自動更新で復帰します。

プラン名は長期トークンには付随しないため、`/api/oauth/profile` から 1 回だけ引いて保持します（トークンが入れ替わるまで再取得しません）。この問い合わせが失敗しても利用量の表示は妨げず、プラン名の表示だけが省略されます。

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
| 認証切れ時 | **10 分間隔** | API は呼ばず、認証情報の読み直しだけ行う。CLI 側がトークンを更新したら自動復帰 |
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
| Claude/Codexの残量を手動で更新 | 即座に両方を再取得 (`⌘R`)。認証切れで自動更新が通信を止めている場合も、認証情報を読み直して 1 回だけ強制的に再試行する |
| Codex 使用量をリセット: 残りN回 | 確認後、Codex のリセット可能回数を1回消費して使用量をリセット。残り0回の場合は押せません |
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
| `Claude auth expired. Start Claude Code, or run claude auth login.` | Claude Code を起動する（アクセストークンが更新される）。それでも直らなければ `claude auth login` を再実行 |
| `Codex auth expired. Run codex login again.` | `codex login` を再実行する |
| 「Codex auth not found」 | `codex login` を実行して `~/.codex/auth.json` を作る |
| `Auth rejected (HTTP 401).` | 通常は表示されない内部エラー。出た場合は不具合として報告してください |
| `HTTP 403: ...` | 権限・プラン起因。Codex のリセットクレジットなど、契約プランで使えない機能を叩いた場合に出る |
| 「自動更新は JST 09:30-21:00 のみ」 | 仕様。手動更新したいときは ⌘R |
| weekly limit 通知が出ない | **システム設定 > 通知 > ClaudeCodexUsageBar** がONか確認。画面共有・ミラーリング中は **「画面をミラーリングまたは共有しているときに通知を許可」** もONにする |

## ライセンス

個人利用想定。再配布前に Claude および ChatGPT/Codex の利用規約を確認してください。
