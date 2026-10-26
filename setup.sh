#!/bin/bash
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "Запустите от root"; exit 1; }

echo "== 1/6 swap =="
if ! swapon --show | grep -q swapfile; then
  fallocate -l 1G /swapfile; chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
  grep -q swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "== 2/6 пакеты =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-pip nginx

echo "== 3/6 второй бот (/opt/multibot) =="
mkdir -p /opt/multibot /var/www/site
cp bot.py requirements.txt /opt/multibot/
if [ ! -f /opt/multibot/.env ]; then
  read -r -p "Токен ВТОРОГО бота (от @BotFather): " TOK
  read -r -p "Ваш Telegram ID (от @userinfobot): " AID
  cat > /opt/multibot/.env <<ENVEOF
BOT_TOKEN=$TOK
ADMIN_IDS=$AID
BOTS_DIRS=/opt/shop_bot
BACKUP_DIR=/opt/multibot/backups
KEEP_BACKUPS=10
SITE_DATA_FILE=/var/www/site/site_info.json
PUBLIC_PHOTO=false
ENVEOF
  chmod 600 /opt/multibot/.env
fi
python3 -m venv /opt/multibot/venv
/opt/multibot/venv/bin/pip install --no-cache-dir -r /opt/multibot/requirements.txt

echo "== 4/6 сайт =="
cp index.html /var/www/site/index.html
[ -f /var/www/site/site_info.json ] || cp site_info.json /var/www/site/site_info.json
chmod -R a+rX /var/www/site
cat > /etc/nginx/sites-available/site <<'NGX'
server {
    listen 80 default_server;
    root /var/www/site;
    index index.html;
    location / { try_files $uri =404; }
}
NGX
ln -sf /etc/nginx/sites-available/site /etc/nginx/sites-enabled/site
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx && systemctl reload nginx
command -v ufw >/dev/null && ufw status | grep -q active && { ufw allow 80/tcp; ufw allow 443/tcp; } || true

echo "== 5/6 служба магазина (/opt/shop_bot) =="
id shop >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin shop
chown -R shop:shop /opt/shop_bot
chmod 600 /opt/shop_bot/.env 2>/dev/null || true
if [ ! -d /opt/shop_bot/venv ]; then
  sudo -u shop python3 -m venv /opt/shop_bot/venv
  sudo -u shop /opt/shop_bot/venv/bin/pip install --no-cache-dir -r /opt/shop_bot/requirements.txt
fi
cat > /etc/systemd/system/shop-bot.service <<'UNIT'
[Unit]
Description=Shop bot
After=network-online.target
[Service]
User=shop
WorkingDirectory=/opt/shop_bot
EnvironmentFile=/opt/shop_bot/.env
ExecStart=/opt/shop_bot/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --no-access-log
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

echo "== 6/6 служба второго бота =="
for f in $(grep -l "/opt/multibot" /etc/systemd/system/*.service 2>/dev/null); do
  n=$(basename "$f"); systemctl disable --now "$n" 2>/dev/null || true; rm -f "$f"
done
cat > /etc/systemd/system/multibot.service <<'UNIT'
[Unit]
Description=Multibot (photo/backup/site)
After=network-online.target
[Service]
WorkingDirectory=/opt/multibot
ExecStart=/opt/multibot/venv/bin/python bot.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable shop-bot multibot
systemctl restart shop-bot multibot
sleep 4
echo; systemctl is-active shop-bot multibot
echo "Сайт: http://$(curl -s ifconfig.me 2>/dev/null)/"
echo "Логи: journalctl -u shop-bot -n 30 --no-pager ; journalctl -u multibot -n 30 --no-pager"
