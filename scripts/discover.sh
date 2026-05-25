#!/usr/bin/env bash
#
# claude.ai の使用量レスポンスを観察するための簡易ツール。
# パーサが合わなくなった時に、何が返ってきているかを確認するために使う。
#
# 使い方:
#   ./scripts/discover.sh "$(security find-generic-password -s com.example.ClaudeCodexUsageBar -w)"
# もしくは sessionKey を直接渡す:
#   ./scripts/discover.sh sk-ant-sid01-...
#
set -euo pipefail

SK="${1:-}"
if [[ -z "$SK" ]]; then
  echo "usage: $0 <sessionKey>"
  echo "  Keychain から取り出す例:"
  echo "    security find-generic-password -s com.example.ClaudeCodexUsageBar -w"
  exit 1
fi

UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) ClaudeCodexUsageBar/1.0'
COMMON_HEADERS=(-H "Cookie: sessionKey=${SK}" -H "Accept: application/json" -H "User-Agent: ${UA}")

echo "==> GET /api/organizations"
ORG_JSON="$(curl -sS "${COMMON_HEADERS[@]}" https://claude.ai/api/organizations)"
echo "$ORG_JSON" | head -c 400; echo
ORG_UUID="$(echo "$ORG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["uuid"])')"
echo "    org uuid = $ORG_UUID"
echo

ENDPOINTS=(
  "https://claude.ai/api/bootstrap/${ORG_UUID}/statsig"
  "https://claude.ai/api/organizations/${ORG_UUID}/usage"
  "https://claude.ai/api/account"
)

OUT_DIR="${TMPDIR:-/tmp}/claude-codex-usage-bar-discover"
mkdir -p "$OUT_DIR"

for url in "${ENDPOINTS[@]}"; do
  fname="$(echo "$url" | sed 's#[^a-zA-Z0-9]#_#g').json"
  out="$OUT_DIR/$fname"
  echo "==> $url"
  http_code="$(curl -sS -o "$out" -w '%{http_code}' "${COMMON_HEADERS[@]}" "$url" || true)"
  echo "    HTTP $http_code  saved=$out"
  if [[ "$http_code" =~ ^2 ]]; then
    echo "    top-level keys:"
    python3 -c "
import json
d = json.load(open('$out'))
if isinstance(d, dict):
    for k in sorted(d.keys()):
        v = d[k]
        sample = json.dumps(v)[:80]
        print(f'      {k:30s} -> {sample}')
elif isinstance(d, list):
    print(f'      [list of {len(d)}]')
"
  fi
  echo
done

echo "全レスポンスは $OUT_DIR に保存されています。"
