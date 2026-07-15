# ClaudeCodexUsageBar

macOS のメニューバーに **Claude.ai** と **Codex (ChatGPT 内の Codex)** の残り使用量と次のリセット時刻を常時表示する、Swift 製の軽量アプリです。

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
- Claude 機能を使う場合: Claude Code / Claude CLI でログイン済み（macOS では Keychain の `Claude Code-credentials` が存在）
- Codex 機能を使う場合: [Codex CLI](https://github.com/openai/codex) で `codex login` 済み（= `~/.codex/auth.json` が存在）

## ビルド & 起動

```bash
git clone https://github.com/shutoinagaki01-agoop/ClaudeCodexUsageBar.git # もしくは GitHub の Code > Download ZIP からダウンロード
cd ClaudeCodexUsageBar  # アプリの置き場所に移動
chmod +x build.sh
./build.sh
open build/ClaudeCodexUsageBar.app
```

- Claude 側は Claude Code / Claude CLI の OAuth 認証情報が存在すれば自動で取得が始まります。OAuth 認証情報が見つからない場合、Claude 行にログイン案内が表示されます。
- Codex 側は `~/.codex/auth.json` が存在すれば自動で取得が始まります（存在しない場合は Codex 行に「Codex auth not found. Run `codex login` first.」と表示されますが、アプリ自体は Claude だけで動作します）。

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

### weekly limit 通知

Claude / Codex の 7d 枠（weekly limit）が **50%以下**、**20%以下** になったタイミングで macOS 通知を出します。

- 手動更新、自動更新のどちらでも通知判定します
- Claude は `7d` と `7d Fable` を個別に通知判定します
- 同じ weekly limit のリセット時刻内では、同じ閾値の通知は1回だけです
- 例: 50%通知後、さらに20%以下になった場合は20%通知も出ます
- macOS の通知設定で `ClaudeCodexUsageBar` の通知を許可してください
- 画面共有・ミラーリング中に通知を表示したい場合は、macOS の **「画面をミラーリングまたは共有しているときに通知を許可」** も有効にしてください

## Claude の認証

Claude Code / Claude CLI が保存する OAuth 認証情報だけを再利用します。ブラウザ Cookie の `sessionKey` 認証は使いません。

```bash
# Claude CLI 側でログイン
claude auth login
```

macOS では Claude Code の OAuth 認証情報は `~/.claude/.credentials.json` ではなく、macOS Keychain に `Claude Code-credentials` として保存されます。Keychain Access.app で `Claude Code-credentials` を検索すると確認できます。

`accessToken` が期限切れの場合は、可能な範囲で `refreshToken` による更新を試します。

## Codex の認証

Codex CLI が `~/.codex/auth.json` に書き出す OAuth トークンを再利用します。アプリ側に追加で設定は不要です。

```bash
# Codex CLI 側でログイン済みであることを確認
ls -l ~/.codex/auth.json
```

`access_token` が期限切れになると自動的に `refresh_token` で更新します。

## ログイン時に自動起動

ビルドした `.app` を `/Applications` に入れたら:

1. **システム設定** → **一般** → **ログイン項目** を開く
2. `+` で `ClaudeCodexUsageBar.app` を追加

これで毎回 Mac 起動時にメニューバーへ常駐します。

## メニューの操作

ドロップダウン上部:

```
Claude: pro              ← 現在のプラン（取得できれば）
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
| 詳細設定 > 取得データをFinderで開く > Claude | `~/Library/Application Support/ClaudeCodexUsageBar/last_response.json` を Finder で表示 (`⌘J`) |
| 詳細設定 > 取得データをFinderで開く > Codex | `~/Library/Application Support/ClaudeCodexUsageBar/codex_usage_response.json` を表示 (`⌘K`) |
| 詳細設定 > 時間設定を変更… | 起動時間、ピーク時間、更新間隔を変更 |
| claude.ai を開く | ブラウザで開く (`⌘O`) |
| 終了 | アプリ停止 (`⌘Q`) |

## ファイル構成

```
ClaudeCodexUsageBar/
├── Package.swift                       # SwiftPM 定義
├── build.sh                            # .app バンドル組み立て
├── README.md
├── Resources/
│   └── Info.plist                      # LSUIElement=true（Dock 非表示）
└── Sources/ClaudeCodexUsageBar/
    ├── main.swift                      # 起動
    ├── AppDelegate.swift               # NSStatusItem + メニュー + タイマー
    ├── AppConfig.swift                 # 時間設定の UserDefaults 永続化
    ├── UsageFetcher.swift              # Claude OAuth 用クライアント
    ├── CodexUsageFetcher.swift         # Codex (ChatGPT) 用クライアント
    └── Models.swift                    # UsageTrack / UsageSnapshot
                                        # CodexUsageTrack / CodexUsageSnapshot
```

## ⚠️ 重要な制約

- **Claude は Claude Code / Claude CLI の OAuth 認証情報だけを利用します**。OAuth では `https://api.anthropic.com/api/oauth/usage` を利用します。ブラウザ Cookie の `sessionKey` 認証は使いません。
- **Codex の使用量取得も非公開エンドポイント** (`https://chatgpt.com/backend-api/codex/usage`) を利用しています。認証は Codex CLI が管理する `~/.codex/auth.json` の OAuth トークンを読み、401 時は `refresh_token` で自動再取得します。
- 上記いずれも内部仕様変更で動かなくなる可能性があります。各サービスの利用規約と整合する個人利用の範囲でお使いください。

## エンドポイントが変わった時の直し方

### Claude

1. メニューバー → **「詳細設定 > 取得データをFinderで開く > Claude」** (`⌘J`) で `last_response.json` を確認
2. 必要に応じて `Sources/ClaudeCodexUsageBar/UsageFetcher.swift` を編集:
   - OAuth usage URL / ヘッダー
   - `extractTracks(…)` の `knownKeys` に新しい枠キーを追加
   - `buildTrack(…)` の数値抽出ロジック（`utilization` / `remaining` / `used+total` の組み合わせ）

現在サポートしているレスポンス構造（実観測ベース）:

```json
{
  "five_hour":          { "utilization": 90.0, "resets_at": "2026-05-22T10:00:00.379497+00:00" },
  "seven_day":          { "utilization": 8.0,  "resets_at": "2026-05-28T23:00:00.379519+00:00" },
  "seven_day_sonnet":   null,
  "seven_day_omelette": { "utilization": 0.0,  "resets_at": null },   // 無視される（Statsigコードネーム）
  "limits": [
    {
      "group": "weekly",
      "percent": 3,
      "resets_at": "2026-05-28T23:00:00.379519+00:00",
      "scope": { "model": { "display_name": "Fable" } }
    }
  ],
  "extra_usage":        { "is_enabled": false }                       // 無視される
}
```

ポイント:
- `utilization` は **0〜100 のパーセント値**として返ってくる（1.0 を超える値は自動的に `/100` する）
- `resets_at` はマイクロ秒精度 ISO8601 (`.379497+00:00`) → アプリ側でミリ秒に丸めて解釈
- `limits` 配列の `group: "weekly"` は weekly limit として採用。`scope.model.display_name` があれば `7d Fable` のように表示
- 許可リスト（`five_hour`, `seven_day`, `seven_day_sonnet/opus/haiku`, `extra_usage` 等）のキーだけ採用。`omelette`, `tangelo`, `iguana_necktie` 等の Statsig コードネームは無視

### Codex

`Sources/ClaudeCodexUsageBar/CodexUsageFetcher.swift` を編集:

- `usageURL` (`https://chatgpt.com/backend-api/codex/usage`) を変更
- `decodeUsage(…)` が読む `primary_window` / `secondary_window` のキー名
- `buildTrack(…)` の `used_percent` / `reset_at` のキー名

サポートしているレスポンス構造:

```json
{
  "plan_type": "plus",
  "rate_limit": {
    "primary_window":   { "used_percent": 33, "reset_at": 1716468000 },
    "secondary_window": { "used_percent": 16, "reset_at": 1716998400 }
  }
}
```

`used_percent` は 0〜100、`reset_at` は UNIX 秒。

## 既知の制限

- **Claude Code (CLI) の使用量は未対応**（ローカルログから集計する別仕組みのため）
- **Anthropic API（Console）の使用量も未対応**（Admin API キーが必要）
- 公式 API ではないため、Claude.ai / ChatGPT 側の仕様変更で動作しなくなる可能性あり
- `~/.codex/auth.json` が無い場合、Codex 行はエラー表示になりますが、Claude 単独で動作します

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| 起動時に「Keychainログイン」のパスワードを聞かれる | macOS が ad-hoc 署名アプリの Keychain アクセスを確認している正常動作。「**常に許可**」を押す。`./build.sh` で再ビルドすると署名ハッシュが変わるためまた聞かれる |
| `Claude auth not found. Run \`claude auth login\` first.` | `claude auth login` を実行する |
| `Claude auth expired. Run \`claude auth login\` again.` | `claude auth login` を再実行する |
| 「Codex auth not found」 | `codex login` を実行して `~/.codex/auth.json` を作る |
| 「usage tracks not found」 | claude.ai 側の仕様変更の可能性。⌘J で生 JSON を確認して `UsageFetcher.swift` を更新 |
| 「自動更新は JST 09:30-21:00 のみ」 | 仕様。手動更新したいときは ⌘R |
| weekly limit 通知が出ない | **システム設定 > 通知 > ClaudeCodexUsageBar** がONか確認。画面共有・ミラーリング中は **「画面をミラーリングまたは共有しているときに通知を許可」** もONにする |

## ライセンス

個人利用想定。再配布前に Claude.ai および ChatGPT/Codex の利用規約を確認してください。
