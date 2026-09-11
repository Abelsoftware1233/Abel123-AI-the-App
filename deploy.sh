#!/bin/bash
set -e

APP_DIR="/root/Abel123-AI-the-App-main"
NGINX_CONF_NAME="abel123ai.abelsoftware123.com"

echo ">> Abel123 AI deploy script"

# 1. Check dat de app-map bestaat
if [ ! -d "$APP_DIR" ]; then
    echo "FOUT: $APP_DIR bestaat niet. Zet de app-bestanden eerst op deze locatie."
    exit 1
fi

# 2. Check .env
if [ ! -f "$APP_DIR/.env" ]; then
    echo "LET OP: geen .env gevonden in $APP_DIR"
    echo "Maak deze aan met minimaal:"
    echo "  ANTHROPIC_API_KEY=jouw_key_hier"
    exit 1
fi

cd "$APP_DIR"

# 3. Python dependencies installeren
echo ">> Installeren van dependencies..."
pip3 install -r requirements.txt --break-system-packages
pip3 install gunicorn --break-system-packages

# 4. Systemd service installeren
echo ">> Systemd service installeren..."
cp /root/abel123ai.service /etc/systemd/system/abel123ai.service
systemctl daemon-reload
systemctl enable abel123ai
systemctl restart abel123ai

# 5. Nginx config koppelen
echo ">> Nginx configureren..."
cp /root/$NGINX_CONF_NAME /etc/nginx/sites-available/$NGINX_CONF_NAME
ln -sf /etc/nginx/sites-available/$NGINX_CONF_NAME /etc/nginx/sites-enabled/$NGINX_CONF_NAME

nginx -t
systemctl reload nginx

echo ">> Klaar. Status:"
systemctl status abel123ai --no-pager -l | head -15

echo ""
echo ">> Check: curl -I http://127.0.0.1:7878"
echo ">> Vergeet niet: DNS A-record voor abel123ai.abelsoftware123.com moet naar dit IP wijzen."
echo ">> Voor HTTPS later: certbot --nginx -d $NGINX_CONF_NAME"
