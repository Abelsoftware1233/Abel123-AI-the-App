#!/bin/bash
set -e

APP_DIR="/root/Abel123-AI-the-App"
REPO_DIR="$APP_DIR"
NGINX_SERVER_NAME="abel123ai.abelsoftware123.com"
BACKUP_DIR="/root/nginx-backup-$(date +%Y%m%d-%H%M%S)"

CHAT_MODEL="${CHAT_MODEL:-llama3}"
VISION_MODEL="${VISION_MODEL:-llama3.2-vision}"
RUN_CERTBOT="${RUN_CERTBOT:-0}"   # zet op 1 om meteen HTTPS aan te vragen: RUN_CERTBOT=1 ./deploy.sh

echo ">> Abel123 AI deploy script (Ollama - lokaal, open source)"

# 1. App-map controleren
if [ ! -d "$APP_DIR" ]; then
    echo "FOUT: $APP_DIR bestaat niet. Zet de app-bestanden eerst op deze locatie."
    exit 1
fi

# 2. .env aanmaken als die ontbreekt
if [ ! -f "$APP_DIR/.env" ]; then
    echo ">> Geen .env gevonden, ik maak er een aan met standaardwaarden..."
    cat > "$APP_DIR/.env" << ENVEOF
OLLAMA_URL=http://localhost:11434
CHAT_MODEL=$CHAT_MODEL
VISION_MODEL=$VISION_MODEL
ENVEOF
fi

cd "$APP_DIR"

# 3. Systeempakketten (nginx, venv, curl)
echo ">> Systeempakketten controleren..."
apt-get update -qq
apt-get install -y -qq nginx python3-venv python3-pip curl

# 4. Ollama installeren als het nog niet aanwezig is
if ! command -v ollama &> /dev/null; then
    echo ">> Ollama niet gevonden, installeren..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    echo ">> Ollama is al geïnstalleerd."
fi

echo ">> Ollama-service starten..."
systemctl enable ollama || true
systemctl restart ollama || true
sleep 3

# 5. Modellen downloaden
echo ">> Chatmodel ophalen: $CHAT_MODEL ..."
ollama pull "$CHAT_MODEL"
echo ">> Visiemodel ophalen: $VISION_MODEL ..."
ollama pull "$VISION_MODEL"

# 6. Python virtualenv + dependencies (de service gebruikt venv/bin/gunicorn!)
echo ">> Python virtualenv en dependencies installeren..."
[ -d "$APP_DIR/venv" ] || python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip -q
"$APP_DIR/venv/bin/pip" install -r requirements.txt gunicorn -q

# 7. Systemd service
echo ">> Systemd service installeren..."
cp "$REPO_DIR/abel123ai-service.txt" /etc/systemd/system/abel123ai.service
systemctl daemon-reload
systemctl enable abel123ai
systemctl restart abel123ai
sleep 2
if ! systemctl is-active --quiet abel123ai; then
    echo "FOUT: abel123ai service draait niet. Log:"
    journalctl -u abel123ai --no-pager -n 30
    exit 1
fi

# 8. Nginx: onze site neerzetten en conflicterende sites uitzetten
echo ">> Nginx configureren..."
mkdir -p "$BACKUP_DIR"

# 8a. Standaardsite uitzetten (die toont anders de 'welkomstpagina' of andere software)
if [ -e /etc/nginx/sites-enabled/default ]; then
    echo ">> Standaard nginx-site uitgezet (backup in $BACKUP_DIR)"
    cp -L /etc/nginx/sites-enabled/default "$BACKUP_DIR/default" || true
    rm -f /etc/nginx/sites-enabled/default
fi

# 8b. Andere ingeschakelde sites die ook onze domeinnaam claimen uitzetten.
#     Alleen de symlink in sites-enabled wordt verwijderd, het origineel blijft in sites-available.
ESCAPED_NAME="${NGINX_SERVER_NAME//./\\.}"
for f in /etc/nginx/sites-enabled/*; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "$NGINX_SERVER_NAME" ] && continue
    if grep -qE "server_name[^;]*${ESCAPED_NAME}" "$f"; then
        echo ">> Conflict: $f claimt ook $NGINX_SERVER_NAME -> uitgezet (backup in $BACKUP_DIR)"
        cp -L "$f" "$BACKUP_DIR/$(basename "$f")"
        rm -f "$f"
    fi
done

# 8c. conf.d kan hetzelfde doen; die verwijderen we niet automatisch, alleen waarschuwen
for f in /etc/nginx/conf.d/*.conf; do
    [ -e "$f" ] || continue
    if grep -qE "server_name[^;]*${ESCAPED_NAME}" "$f"; then
        echo "!! WAARSCHUWING: $f claimt ook $NGINX_SERVER_NAME. Haal dit zelf weg of pas het aan."
    fi
done

cp "$REPO_DIR/abel123ai-nginx.conf" "/etc/nginx/sites-available/$NGINX_SERVER_NAME"
ln -sf "/etc/nginx/sites-available/$NGINX_SERVER_NAME" "/etc/nginx/sites-enabled/$NGINX_SERVER_NAME"

nginx -t
systemctl reload nginx

# 9. Optioneel HTTPS (zonder dit pakt https:// vaak de ANDERE site op deze server)
if [ "$RUN_CERTBOT" = "1" ]; then
    apt-get install -y -qq certbot python3-certbot-nginx
    certbot --nginx -d "$NGINX_SERVER_NAME" --non-interactive --agree-tos --register-unsafely-without-email --redirect
fi

# 10. Diagnose
echo ""
echo ">> ===== DIAGNOSE ====="
PUB_IP="$(curl -s https://api.ipify.org || true)"
DNS_IP="$(getent ahostsv4 "$NGINX_SERVER_NAME" | awk 'NR==1{print $1}')"
echo "Publiek IP van deze server : ${PUB_IP:-onbekend}"
echo "DNS A-record van het domein: ${DNS_IP:-niet gevonden}"
if [ -n "$PUB_IP" ] && [ "$PUB_IP" != "$DNS_IP" ]; then
    echo "!! DNS wijst NIET naar deze server. Je ziet dan software van een andere server."
    echo "!! Pas het A-record van $NGINX_SERVER_NAME aan naar $PUB_IP en wacht tot DNS bijgewerkt is."
fi

echo ""
echo "Direct uit de app (poort 7878):"
curl -s http://127.0.0.1:7878/ | grep -io "<title>.*</title>" || echo "(geen title gevonden)"
echo "Via nginx met jouw domein (poort 80):"
curl -s -H "Host: $NGINX_SERVER_NAME" http://127.0.0.1/ | grep -io "<title>.*</title>" || echo "(geen title gevonden)"

echo ""
echo ">> Alle nginx server_name's die actief zijn:"
nginx -T 2>/dev/null | grep -E "^\s*server_name|^\s*listen.*default_server" | sort | uniq -c

echo ""
echo ">> Ollama-modellen:"
ollama list
echo ""
echo ">> Klaar. Voor HTTPS: RUN_CERTBOT=1 ./deploy.sh  (of: certbot --nginx -d $NGINX_SERVER_NAME)"
