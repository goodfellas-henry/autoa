#!/usr/bin/env bash
# =====================================================================
# AutoA 運用ロボットの設置スクリプト（Ubuntu 用）
#   1回目:   bash setup.sh
#            → 必要なソフトを入れ、ロボット専用の鍵を作ります
#   通知:    bash setup.sh discord https://discord.com/api/webhooks/...
#            → Discord の通知先を登録します
#   金庫:    bash setup.sh 0x金庫1の住所 0x金庫2の住所
#            → 金庫の住所を登録し、ロボットを24時間動かし始めます
#              （金庫を増やすときも、全部の住所を並べてもう一度実行）
#   成績:    bash setup.sh start 0.01 0.01
#            → 各金庫に入れた ETH の量を登録し、毎朝の定期報告に成績を載せます
#   自動更新: bash setup.sh autoupdate
#            → GitHub の新しい版を1時間ごとに自動で取り込むようにします
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"
BOT_DIR="$(pwd)"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
SERVICE=autoa-keeper

restart_if_running() {
  if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    $SUDO systemctl restart "$SERVICE"; echo "ロボットを再起動して、新しい設定を反映しました。"
  fi
}

# ---------------------------------------------------------------- 1回目
if [ $# -eq 0 ]; then
  echo "=== 1/3 必要なソフトを入れています（数分かかります）==="
  if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 18 ]; then
    $SUDO apt-get update -y
    $SUDO apt-get install -y ca-certificates curl gnupg
    if [ -n "$SUDO" ]; then curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -; else curl -fsSL https://deb.nodesource.com/setup_22.x | bash -; fi
    $SUDO apt-get install -y nodejs
  fi
  echo "=== 2/3 ロボットの部品を入れています ==="
  npm install --omit=dev --no-audit --no-fund
  echo "=== 3/3 ロボット専用の鍵を作っています ==="
  [ -f .env ] || cp .env.example .env
  chmod 600 .env
  node new-keeper.js
  echo ""
  echo "ここまで完了です。手順書の次の手順に進んでください。"
  exit 0
fi

[ -f .env ] || { echo "先に bash setup.sh を実行してください"; exit 1; }

# ---------------------------------------------------------------- Discord
if [ "$1" = "discord" ]; then
  URL="${2:-}"
  if ! [[ "$URL" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/[A-Za-z0-9/_-]+$ ]]; then
    echo "Discord の通知用URLの形が正しくありません。https://discord.com/api/webhooks/ で始まるURLを貼ってください。"; exit 1
  fi
  sed -i "s|^DISCORD_WEBHOOK_URL=.*|DISCORD_WEBHOOK_URL=$URL|" .env
  chmod 600 .env
  curl -fsS -H "content-type: application/json" -d '{"username":"AutoA","content":"✅ AutoA の通知テストです。これが見えていれば設定完了です。"}' "$URL" >/dev/null \
    && echo "Discord にテスト通知を送りました。届いているか確認してください。" \
    || echo "テスト通知が送れませんでした。URLをもう一度確認してください。"
  restart_if_running
  exit 0
fi

# ---------------------------------------------------------------- 入れた ETH の量（成績の比べる相手）
if [ "$1" = "start" ]; then
  shift
  [ $# -ge 1 ] || { echo "使い方: bash setup.sh start 0.01 0.01 （金庫を登録した順に、入れた ETH の量を並べる）"; exit 1; }
  for N in "$@"; do
    [[ "$N" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "数字の形が正しくありません: $N（例 0.01）"; exit 1; }
  done
  LIST="$(IFS=,; echo "$*")"
  if grep -q '^START_ETH=' .env; then sed -i "s|^START_ETH=.*|START_ETH=$LIST|" .env; else echo "START_ETH=$LIST" >> .env; fi
  grep -q '^REPORT_HOUR_JST=' .env || echo "REPORT_HOUR_JST=9" >> .env
  chmod 600 .env
  echo "入れた ETH の量を登録しました: $LIST"
  restart_if_running
  exit 0
fi

# ---------------------------------------------------------------- 自動更新
if [ "$1" = "autoupdate" ]; then
  chmod +x "$BOT_DIR/update.sh"
  $SUDO tee /etc/systemd/system/autoa-update.service >/dev/null <<UNIT
[Unit]
Description=AutoA keeper auto update
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $BOT_DIR/update.sh
UNIT
  $SUDO tee /etc/systemd/system/autoa-update.timer >/dev/null <<UNIT
[Unit]
Description=AutoA keeper auto update (hourly)

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
UNIT
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now autoa-update.timer >/dev/null
  echo "自動更新を設定しました。GitHub が更新されると、1時間以内にロボットが自動で最新になります。"
  echo "  止めるとき: systemctl disable --now autoa-update.timer"
  exit 0
fi

# ---------------------------------------------------------------- 金庫の登録
for V in "$@"; do
  if ! [[ "$V" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "金庫の住所の形が正しくありません（0x で始まる42文字）: $V"; exit 1
  fi
done
LIST="$(IFS=,; echo "$*")"
sed -i "s|^VAULT_ADDRESS=.*|VAULT_ADDRESS=$LIST|" .env
chmod 600 .env

echo "=== 金庫の状態を確認しています ==="
node keeper.js --status

# 古い名前のロボットが動いていたら止める
if systemctl list-unit-files 2>/dev/null | grep -q '^lpvault-keeper'; then
  $SUDO systemctl disable --now lpvault-keeper || true
  $SUDO rm -f /etc/systemd/system/lpvault-keeper.service
fi

echo "=== 24時間動くように登録しています ==="
$SUDO tee /etc/systemd/system/$SERVICE.service >/dev/null <<UNIT
[Unit]
Description=AutoA keeper bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BOT_DIR
ExecStart=$(command -v node) $BOT_DIR/keeper.js
Restart=always
RestartSec=30
User=$(id -un)
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
UNIT
$SUDO systemctl daemon-reload
$SUDO systemctl enable "$SERVICE" >/dev/null
$SUDO systemctl restart "$SERVICE"
sleep 3
$SUDO systemctl --no-pager status "$SERVICE" | head -5
echo ""
echo "ロボットが動き始めました（金庫 $# 個）。"
echo "  動作の記録を見る:   sudo journalctl -u $SERVICE -f   （終わるときは Ctrl+C）"
echo "  今の状態を見る:     node keeper.js --status"
echo "  止める:             sudo systemctl stop $SERVICE"
echo "  再開する:           sudo systemctl start $SERVICE"
