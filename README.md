# ClaudeCodexUsageBar

macOS のメニューバーに **Claude.ai** と **Codex (ChatGPT 内の Codex)** の残り使用量と次のリセット時刻を常時表示する、Swift 製の軽量アプリです。

```
┌─────────────────────────────────────────────────────────────────────┐
│  ...   Claude 5h 90%·14:00 | Codex 5h 67%·11:00    🔋 Wi-Fi 🔍 🔔 │
└─────────────────────────────────────────────────────────────────────┘
```

メニューを開くと、Claude / Codex それぞれの 5h・7d 各枠の残量と直近のリセット時刻、現在のプランが見られます。

## ⚠️ 重要な制約

- **Claude.ai には公式の使用量取得 API がありません**。ブラウザの `sessionKey` Cookie を使って内部エンドポイント (`/api/bootstrap/{org}/statsig`) を叩いて取得しています。`sessionKey` が失効すると 401 になるため、再ログインして貼り直してください。
- **Codex の使用量取得も非公開エンドポイント** (`https://chatgpt.com/backend-api/codex/usage`) を利用しています。認証は Codex CLI が管理する `~/.codex/auth.json` の OAuth トークンを読み、401 時は `refresh_token` で自動再取得します。
- 上記いずれも内部仕様変更で動かなくなる可能性があります。各サービスの利用規約と整合する個人利用の範囲でお使いください。

## 必要環境

- macOS 12 (Monterey) 以降
- Xcode Command Line Tools (`xcode-select --install`) もしくは Xcode 本体
- Codex 機能を使う場合: [Codex CLI](https://github.com/openai/codex) で `codex login` 済み（= `~/.codex/auth.json` が存在）

## ビルド & 起動

```bash
cd /path/to/ClaudeCodexUsageBar  # アプリの置き場所に移動
chmod +x build.sh
./build.sh
open build/ClaudeCodexUsageBar.app
```

初回起動時に Claude の sessionKey を求めるダイアログが出ます。Codex 側は `~/.codex/auth.json` が存在すれば自動で取得が始まります（存在しない場合は Codex 行に「Codex auth not found. Run `codex login` first.」と表示されますが、アプリ自体は Claude だけで動作します）。

## 更新ポリシー

| 項目 | 値 | 説明 |
|---|---|---|
| 通常時の自動更新間隔 | **JST 11:00–16:00 は 3 分、それ以外は 5 分** | 5h / 7d 枠ともに残量がある間 |
| 自動更新の時間帯 | **JST 09:30–21:00** | 深夜〜朝はサーバー負荷とレートリミットを避けるため停止 |
| 5h 枯渇時 | **次のリセット時刻まで待機**（取れない場合 1 時間後にリトライ） | 0% に張り付いている間に無駄打ちしない |
| 時間帯外 | メニューバーに「自動更新は JST 09:30-21:00 のみ」と表示 | 手動更新（⌘R）はいつでも可能 |

### 取得間隔を変更したい場合

自動更新の間隔は `Sources/ClaudeCodexUsageBar/AppDelegate.swift` の先頭付近にある定数で変更できます。

```swift
private let peakRefreshInterval: TimeInterval = 3 * 60      // peaktime (JST 11:00-16:00) の取得間隔
private let normalRefreshInterval: TimeInterval = 5 * 60    // それ以外の取得間隔
private let depletedFallbackRefreshInterval: TimeInterval = 60 * 60
private let autoRefreshStartHour = 9
private let autoRefreshStartMinute = 30
private let autoRefreshEndHour = 21
private let autoRefreshEndMinute = 0
private let peakRefreshStartHour = 11
private let peakRefreshEndHour = 16
```

例: 通常時 10 分間隔にしたい場合は、以下のように変更します。

```swift
private let normalRefreshInterval: TimeInterval = 10 * 60
```

変更後は再ビルドしてください。

```bash
./build.sh
open build/ClaudeCodexUsageBar.app
```

## Claude の sessionKey の取り方

1. ブラウザで <https://claude.ai> にログイン
2. DevTools を開く（macOS: `⌥⌘I`）
3. **Application** タブ → **Storage** → **Cookies** → `https://claude.ai`
4. `sessionKey` Cookie の **Value** をコピー（`sk-ant-sid01-...` のような文字列）
5. メニューバーアプリのダイアログに貼り付け → 「保存」

保存先は macOS Keychain (service: `com.example.ClaudeCodexUsageBar`)。

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
| Claude sessionKey を設定… | Cookie を更新 (`⌘,`) |
| Claude デバッグJSONをFinderで開く | `~/Library/Application Support/ClaudeCodexUsageBar/last_response.json` を Finder で表示 (`⌘J`) |
| Codex デバッグJSONをFinderで開く | `~/Library/Application Support/ClaudeCodexUsageBar/codex_usage_response.json` を表示 (`⌘K`) |
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
├── scripts/
│   └── discover.sh                     # Claude エンドポイント観察ツール
└── Sources/ClaudeCodexUsageBar/
    ├── main.swift                      # 起動
    ├── AppDelegate.swift               # NSStatusItem + メニュー + タイマー
    ├── UsageFetcher.swift              # Claude.ai 用クライアント
    ├── CodexUsageFetcher.swift         # Codex (ChatGPT) 用クライアント
    ├── KeychainHelper.swift            # sessionKey の Keychain 永続化
    └── Models.swift                    # UsageTrack / UsageSnapshot
                                        # CodexUsageTrack / CodexUsageSnapshot
```

## エンドポイントが変わった時の直し方

### Claude

1. メニューバー → **「Claude デバッグJSONをFinderで開く」** (`⌘J`) で `last_response.json` を確認
2. または discovery スクリプトで複数候補を一度に観察:
   ```bash
   ./scripts/discover.sh "$(security find-generic-password -s com.example.ClaudeCodexUsageBar -w)"
   ```
3. 必要に応じて `Sources/ClaudeCodexUsageBar/UsageFetcher.swift` を編集:
   - `candidateUsageURLs(…)` に新しい URL を追加
   - `extractTracks(…)` の `knownKeys` に新しい枠キーを追加
   - `buildTrack(…)` の数値抽出ロジック（`utilization` / `remaining` / `used+total` の組み合わせ）

現在サポートしているレスポンス構造（実観測ベース）:

```json
{
  "five_hour":          { "utilization": 90.0, "resets_at": "2026-05-22T10:00:00.379497+00:00" },
  "seven_day":          { "utilization": 8.0,  "resets_at": "2026-05-28T23:00:00.379519+00:00" },
  "seven_day_sonnet":   null,
  "seven_day_omelette": { "utilization": 0.0,  "resets_at": null },   // 無視される（Statsigコードネーム）
  "extra_usage":        { "is_enabled": false }                       // 無視される
}
```

ポイント:
- `utilization` は **0〜100 のパーセント値**として返ってくる（1.0 を超える値は自動的に `/100` する）
- `resets_at` はマイクロ秒精度 ISO8601 (`.379497+00:00`) → アプリ側でミリ秒に丸めて解釈
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
| 「sessionKey が未設定です」 | メニューから「Claude sessionKey を設定…」を選び、claude.ai の Cookie を貼り付け |
| 「認証エラー (401)」 | sessionKey が失効。claude.ai に再ログインして貼り直し |
| 「Codex auth not found」 | `codex login` を実行して `~/.codex/auth.json` を作る |
| 「usage tracks not found」 | claude.ai 側の仕様変更の可能性。⌘J で生 JSON を確認して `UsageFetcher.swift` を更新 |
| 「自動更新は JST 09:30-21:00 のみ」 | 仕様。手動更新したいときは ⌘R |

## ライセンス

個人利用想定。再配布前に Claude.ai および ChatGPT/Codex の利用規約を確認してください。
