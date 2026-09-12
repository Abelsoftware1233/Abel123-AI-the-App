#!/bin/bash
set -e

APP_DIR="/root/Abel123-AI-the-App"
REPO_DIR="$APP_DIR"
NGINX_SERVER_NAME="abel123ai.abelsoftware123.com"

# Modellen die gebruikt worden (moeten overeenkomen met .env, of laat leeg voor defaults)
CHAT_MODEL="${CHAT_MODEL:-llama3}"
VISION_MODEL="${VISION_MODEL:-llama3.2-vision}"

echo ">> Abel123 AI deploy script (Ollama - lokaal, open source)"

# 1. Check dat de app-map bestaat
if [ ! -d "$APP_DIR" ]; then
    echo "FOUT: $APP_DIR bestaat niet. Zet de app-bestanden eerst op deze locatie."
    exit 1
fi

# 2. Check .env (optioneel bij Ollama, maar we maken 'm aan als die ontbreekt)
if [ ! -f "$APP_DIR/.env" ]; then
    echo ">> Geen .env gevonden, ik maak er een aan met standaardwaarden..."
    cat > "$APP_DIR/.env" << ENVEOF
OLLAMA_URL=http://localhost:11434
CHAT_MODEL=$CHAT_MODEL
VISION_MODEL=$VISION_MODEL
ENVEOF
fi

cd "$APP_DIR"

# 3. Ollama installeren als het nog niet aanwezig is
if ! command -v ollama &> /dev/null; then
    echo ">> Ollama niet gevonden, installeren..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    echo ">> Ollama is al geïnstalleerd."
fi

# 4. Ollama-service starten (systemd-service wordt door de installer aangemaakt)
echo ">> Ollama-service starten..."
systemctl enable ollama || true
systemctl restart ollama || true
sleep 3

# 5. Benodigde modellen downloaden (eenmalig, wordt overgeslagen als al aanwezig)
echo ">> Chatmodel ophalen: $CHAT_MODEL (dit kan even duren)..."
ollama pull "$CHAT_MODEL"

echo ">> Visiemodel ophalen: $VISION_MODEL (dit kan een tijd duren, groot bestand)..."
ollama pull "$VISION_MODEL"

# 6. Python dependencies installeren
echo ">> Installeren van Python dependencies..."
pip3 install -r requirements.txt --break-system-packages
pip3 install gunicorn --break-system-packages

# 7. Systemd service voor de Flask-app installeren
echo ">> Systemd service voor Abel123 AI installeren..."
cp "$REPO_DIR/abel123ai-service.txt" /etc/systemd/system/abel123ai.service
systemctl daemon-reload
systemctl enable abel123ai
systemctl restart abel123ai

# 8. Nginx config koppelen
echo ">> Nginx configureren..."
cp "$REPO_DIR/abel123ai-nginx.conf" /etc/nginx/sites-available/$NGINX_SERVER_NAME
ln -sf /etc/nginx/sites-available/$NGINX_SERVER_NAME /etc/nginx/sites-enabled/$NGINX_SERVER_NAME

nginx -t
systemctl reload nginx

echo ">> Klaar. Status:"
systemctl status abel123ai --no-pager -l | head -15

echo ""
echo ">> Ollama-modellen geïnstalleerd:"
ollama list

echo ""
echo ">> Check: curl -I http://127.0.0.1:7878"
echo ">> Check Ollama: curl http://127.0.0.1:11434/api/tags"
echo ">> Vergeet niet: DNS A-record voor abel123ai.abelsoftware123.com moet naar dit IP wijzen."
echo ">> Voor HTTPS later: certbot --nginx -d $NGINX_SERVER_NAME"
echo ">> LET OP: llama3.2-vision en soortgelijke vision-modellen zijn zwaar."
echo ">>         Zorg voor voldoende RAM/VRAM (minimaal 8GB vrij aanbevolen)."