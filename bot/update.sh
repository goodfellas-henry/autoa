#!/usr/bin/env bash
# =====================================================================
# AutoA ロボットの自動更新（1時間ごとにサーバーが自分で実行）
#   GitHub の main に新しい版があれば取り込み、問題がなければロボットを再起動します。
#   新しい版のプログラムに書き間違いがあれば、取り込まずに元の版に戻します。
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
REPO_DIR="$(pwd)"
SERVICE=autoa-keeper
WEBHOOK="$(grep -E '^DISCORD_WEBHOOK_URL=' bot/.env 2>/dev/null | cut -d= -f2-)"

say() {
  echo "$1"
  [ -n "$WEBHOOK" ] && curl -fsS -m 10 -H "content-type: application/json" \
    -d "$(printf '{"username":"AutoA","content":"%s"}' "$1")" "$WEBHOOK" >/dev/null 2>&1 || true
}

git fetch -q origin main || exit 0
OLD="$(git rev-parse HEAD)"
NEW="$(git rev-parse origin/main)"
[ "$OLD" = "$NEW" ] && exit 0

# 部品の一覧（package-lock.json）は設置時に自動で書き換わることがあるので元に戻しておく
git checkout -q -- bot/package-lock.json 2>/dev/null || true
# 手で書き換えた所があると取り込めないので、その場合は何もしない
if ! git merge -q --ff-only origin/main; then
  say "⚠️ ロボットの自動更新を見送りました（サーバー側のファイルが書き換えられています）。"
  exit 0
fi

cd bot
if [ "$(git -C "$REPO_DIR" diff --name-only "$OLD" "$NEW" -- bot/package.json bot/package-lock.json)" != "" ]; then
  npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1
fi
if ! node --check keeper.js; then
  git -C "$REPO_DIR" reset -q --hard "$OLD"
  say "⚠️ 新しい版のロボットに問題があったため、更新を取りやめて元の版のまま動かしています。"
  exit 0
fi

systemctl restart "$SERVICE"
say "🔄 ロボットを最新の版に更新しました（$(git -C "$REPO_DIR" log -1 --format=%s | head -c 80)）。"
