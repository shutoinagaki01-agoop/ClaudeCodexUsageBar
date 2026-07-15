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
- Codex 機能を使う場合: [Codex CLI](https://github.com/openai/codex) で `codex login` 済み

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
| 時間帯外 | メニューバーに「自動更新は JST 09:30-21:00 のみ」と表示 | 手動更新（⌘R）はいつでも可能 |

### 取得間隔・時刻を変更したい場合

メニューバーのドロップダウンから **詳細設定 > 時間設定を変更…** を開くと、以下を変更できます。

- 起動時間（自動更新する時間帯）
- ピーク時間
- ピーク時の更新間隔
- 通常時の更新間隔

設定は macOS の `UserDefaults` に保存されるため、変更後の再ビルドは不要です。

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
| Claude/Codexの残量を手動で更新 | 即座に両方を再取得 (`⌘R`) |
| Codex 使用量をリセット: 残りN回 | 確認後、Codex のリセット可能回数を1回消費して使用量をリセット。残り0回の場合は押せません |
| 詳細設定 > 時間設定を変更… | 起動時間、ピーク時間、更新間隔を変更 |
| 終了 | アプリ停止 (`⌘Q`) |


## トラブルシューティング

| 症状 | 対処 |
|---|---|
| 起動時に「Keychainログイン」のパスワードを聞かれる | macOS が ad-hoc 署名アプリの Keychain アクセスを確認している正常動作。「**常に許可**」を押す。`./build.sh` で再ビルドすると署名ハッシュが変わるためまた聞かれる |
| `Claude auth not found. Run \`claude auth login\` first.` | `claude auth login` を実行する |
| `Claude auth expired. Run \`claude auth login\` again.` | `claude auth login` を再実行する |
| 「Codex auth not found」 | `codex login` を実行して `~/.codex/auth.json` を作る |
| 「自動更新は JST 09:30-21:00 のみ」 | 仕様。手動更新したいときは ⌘R |
| weekly limit 通知が出ない | **システム設定 > 通知 > ClaudeCodexUsageBar** がONか確認。画面共有・ミラーリング中は **「画面をミラーリングまたは共有しているときに通知を許可」** もONにする |

## ライセンス

個人利用想定。再配布前に Claude および ChatGPT/Codex の利用規約を確認してください。
