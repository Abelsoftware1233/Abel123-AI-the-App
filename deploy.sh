#!/bin/bash
set -e

APP_DIR="/root/Abel123-AI-the-App"
REPO_DIR="$APP_DIR"
NGINX_SERVER_NAME="abel123ai.abelsoftware123.com"

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
    echo "  OPENAI_API_KEY=jouw_key_hier"
    exit 1
fi

cd "$APP_DIR"

# 3. Python dependencies installeren
echo ">> Installeren van dependencies..."
pip3 install -r requirements.txt --break-system-packages
pip3 install gunicorn --break-system-packages

# 4. Systemd service installeren
# (bronbestand heet in de repo abel123ai-service.txt, maar systemd verwacht een .service bestand)
echo ">> Systemd service installeren..."
cp "$REPO_DIR/abel123ai-service.txt" /etc/systemd/system/abel123ai.service
systemctl daemon-reload
systemctl enable abel123ai
systemctl restart abel123ai

# 5. Nginx config koppelen
# (bronbestand heet in de repo abel123ai-nginx.conf, servernaam in de config zelf is abel123ai.abelsoftware123.com)
echo ">> Nginx configureren..."
cp "$REPO_DIR/abel123ai-nginx.conf" /etc/nginx/sites-available/$NGINX_SERVER_NAME
ln -sf /etc/nginx/sites-available/$NGINX_SERVER_NAME /etc/nginx/sites-enabled/$NGINX_SERVER_NAME

nginx -t
systemctl reload nginx

echo ">> Klaar. Status:"
systemctl status abel123ai --no-pager -l | head -15

echo ""
echo ">> Check: curl -I http://127.0.0.1:7878"
echo ">> Vergeet niet: DNS A-record voor abel123ai.abelsoftware123.com moet naar dit IP wijzen."
echo ">> Voor HTTPS later: certbot --nginx -d $NGINX_SERVER_NAME"
