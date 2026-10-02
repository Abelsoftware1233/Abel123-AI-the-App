#!/bin/bash
# =====================================================================
# Abel123 AI - ALLES-IN-EEN deploy.sh
# Bevat zelf alle app-bestanden. Je hoeft alleen dit ene bestand te draaien:
#     bash deploy.sh
# Optioneel: CHAT_MODEL=llama3 VISION_MODEL=llava bash deploy.sh
# =====================================================================
set -e

APP_DIR="/root/Abel123-AI-the-App"
DOMAIN="abel123ai.abelsoftware123.com"
PORT=7878
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/abel123-backup-$STAMP"
SELF="$(readlink -f "$0")"

say()  { echo; echo ">> $*"; }
warn() { echo "!! $*"; }

[ "$(id -u)" -eq 0 ] || { echo "Draai dit als root (bijv. sudo bash deploy.sh)"; exit 1; }
mkdir -p "$BACKUP" "$APP_DIR"
echo ">> Backup van alles wat ik aanpas: $BACKUP"

# ---------------------------------------------------------------
# 1. Juiste app-bestanden neerzetten (overschrijft Andromeda/oude bestanden)
# ---------------------------------------------------------------
say "1/8 App-bestanden neerzetten"
for f in app.py index.html script.js style.css requirements.txt abel123ai-service.txt abel123ai-nginx.conf; do
    [ -f "$APP_DIR/$f" ] && cp -a "$APP_DIR/$f" "$BACKUP/" || true
done
sed '1,/^__PAYLOAD__$/d' "$SELF" | base64 -d | tar xz -C "$APP_DIR"
cp -n "$APP_DIR/.env.example" "$APP_DIR/.env.example" 2>/dev/null || true

if [ ! -f "$APP_DIR/.env" ]; then
    echo ">> Geen .env, maak standaard aan"
    cat > "$APP_DIR/.env" <<ENVEOF
OLLAMA_URL=http://localhost:11434
CHAT_MODEL=${CHAT_MODEL:-llama3}
VISION_MODEL=${VISION_MODEL:-llama3.2-vision}
ENVEOF
fi
set -a; . "$APP_DIR/.env"; set +a
CHAT_MODEL="${CHAT_MODEL:-llama3}"
VISION_MODEL="${VISION_MODEL:-llama3.2-vision}"
echo "   chatmodel: $CHAT_MODEL | visiemodel: $VISION_MODEL"

# ---------------------------------------------------------------
# 2. Pakketten
# ---------------------------------------------------------------
say "2/8 Systeempakketten"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx python3-venv python3-pip curl psmisc procps

# ---------------------------------------------------------------
# 3. Ollama + modellen
# ---------------------------------------------------------------
say "3/8 Ollama en modellen"
if ! command -v ollama >/dev/null 2>&1; then
    curl -fsSL https://ollama.com/install.sh | sh
fi
systemctl enable ollama >/dev/null 2>&1 || true
systemctl restart ollama || true
sleep 3
ollama pull "$CHAT_MODEL"   || warn "Chatmodel $CHAT_MODEL ophalen mislukt (site start wel, chat nog niet)"
ollama pull "$VISION_MODEL" || warn "Visiemodel $VISION_MODEL ophalen mislukt (zie 'ollama list')"

# ---------------------------------------------------------------
# 4. Python venv
# ---------------------------------------------------------------
say "4/8 Python venv"
[ -x "$APP_DIR/venv/bin/python" ] || { rm -rf "$APP_DIR/venv"; python3 -m venv "$APP_DIR/venv"; }
"$APP_DIR/venv/bin/pip" install -q --upgrade pip
"$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements.txt" gunicorn

# ---------------------------------------------------------------
# 5. Poort vrijmaken (als Andromeda of iets anders poort 7878 bezet)
# ---------------------------------------------------------------
say "5/8 Poort $PORT vrijmaken en service starten"
systemctl stop abel123ai 2>/dev/null || true
sleep 1
PIDS="$(ss -tlnpH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)"
for pid in $PIDS; do
    UNIT="$(ps -o unit= -p "$pid" 2>/dev/null | tr -d ' ')"
    CMD="$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-120)"
    warn "Poort $PORT bezet door pid $pid ($CMD) unit='${UNIT:-geen}'"
    case "$UNIT" in
        nginx*|ssh*|sshd*|ollama*|"") ;;
        abel123ai.service) ;;
        *) warn "Stop en schakel uit: $UNIT"; systemctl disable --now "$UNIT" 2>/dev/null || true ;;
    esac
    kill "$pid" 2>/dev/null || true
done
sleep 1
fuser -k "$PORT"/tcp 2>/dev/null || true

cp "$APP_DIR/abel123ai-service.txt" /etc/systemd/system/abel123ai.service
systemctl daemon-reload
systemctl enable abel123ai >/dev/null 2>&1
systemctl restart abel123ai
sleep 3
if ! systemctl is-active --quiet abel123ai; then
    warn "Service draait niet. Log:"
    journalctl -u abel123ai --no-pager -n 30
    exit 1
fi

# ---------------------------------------------------------------
# 6. Nginx: onze site, conflicten weg
# ---------------------------------------------------------------
say "6/8 Nginx"
ESC="${DOMAIN//./\\.}"
mkdir -p "$BACKUP/nginx"

# Alles wat het domein claimt of de standaard-site is: uitzetten (symlink weg, origineel blijft)
for f in /etc/nginx/sites-enabled/*; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    [ "$name" = "$DOMAIN" ] && continue
    if [ "$name" = "default" ] || grep -qE "server_name[^;]*${ESC}" "$f" 2>/dev/null; then
        warn "Zet uit: $f"
        cp -L "$f" "$BACKUP/nginx/$name" 2>/dev/null || true
        rm -f "$f"
    fi
done
for f in /etc/nginx/conf.d/*.conf; do
    [ -e "$f" ] || continue
    if grep -qE "server_name[^;]*${ESC}" "$f" 2>/dev/null; then
        warn "Zet uit (hernoemd naar .uit): $f"
        cp "$f" "$BACKUP/nginx/"
        mv "$f" "$f.uit"
    fi
done

cp "$APP_DIR/abel123ai-nginx.conf" "/etc/nginx/sites-available/$DOMAIN"
ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

# ---------------------------------------------------------------
# 7. HTTPS (anders pakt https:// de andere site op deze server)
# ---------------------------------------------------------------
say "7/8 HTTPS"
PUB_IP="$(curl -s -m 8 https://api.ipify.org || true)"
DNS_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')"
echo "   Publiek IP server : ${PUB_IP:-onbekend}"
echo "   DNS A-record      : ${DNS_IP:-niet gevonden}"
DNS_OK=0
if [ -n "$PUB_IP" ] && [ "$PUB_IP" = "$DNS_IP" ]; then DNS_OK=1; else
    warn "DNS wijst NIET naar deze server. Zet het A-record van $DOMAIN op ${PUB_IP:-het IP van deze server}."
    warn "Tot dan zie je de software van een andere server, wat ik ook doe."
fi
if [ "$DNS_OK" = "1" ]; then
    apt-get install -y -qq certbot python3-certbot-nginx
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect --reinstall \
        && echo "   HTTPS ingesteld" || warn "Certbot mislukt (site werkt wel op http://)"
    nginx -t && systemctl reload nginx
fi

# ---------------------------------------------------------------
# 8. Controle
# ---------------------------------------------------------------
say "8/8 Controle"
sleep 1
OK=1
T1="$(curl -s -m 10 http://127.0.0.1:$PORT/ | grep -io '<title>.*</title>' || true)"
T2="$(curl -s -m 10 -H "Host: $DOMAIN" http://127.0.0.1/ | grep -io '<title>.*</title>' || true)"
echo "   Direct uit app (:$PORT): ${T1:-GEEN ANTWOORD}"
echo "   Via nginx (poort 80)   : ${T2:-GEEN ANTWOORD}"
echo "$T1" | grep -qi "Abel AI" || { OK=0; warn "App geeft niet de Abel-pagina"; }
echo "$T2" | grep -qi "Abel AI" || { OK=0; warn "Nginx geeft niet de Abel-pagina"; }
if grep -qi "THREE" "$APP_DIR/script.js"; then OK=0; warn "script.js bevat nog THREE"; fi
CODE_ENV="$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/.env || true)"
echo "   /.env opvragen        : HTTP $CODE_ENV (hoort 404)"
echo "   API-status:"; curl -s -m 10 http://127.0.0.1:$PORT/api/status || true; echo
if [ "$DNS_OK" = "1" ]; then
    TS="$(curl -sk -m 10 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" | grep -io '<title>.*</title>' || true)"
    echo "   Via HTTPS             : ${TS:-geen HTTPS}"
    if [ -n "$TS" ] && ! echo "$TS" | grep -qi "Abel AI"; then OK=0; warn "HTTPS toont een andere site"; fi
fi
echo; echo ">> Nog steeds Andromeda in nginx/systemd? (leeg = goed)"
grep -ril andromeda /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ /etc/systemd/system/ 2>/dev/null || true

echo
if [ "$OK" = "1" ]; then
    echo "=================== KLAAR: het werkt ==================="
    echo "Open https://$DOMAIN in een privevenster (of Ctrl+Shift+R)."
else
    echo "=================== NOG NIET GOED ====================="
    echo "Plak de volledige uitvoer hierboven in de chat."
fi
echo "Backup van oude bestanden: $BACKUP"
exit 0
__PAYLOAD__
H4sIAAAAAAAAA+w8247jRnbz3F9Ry4F3R0ZTYlEkpZZbvdsz7rEHGI/Hc8nCWewDJZYk7lCkQlJ9sWEgeUmegiDJAkHykH1ZIC/7EuQtn+Mv2E/IOXWhikVSrZ5t28iuZfeILFadOrc6tyqqP3jwnX8c+Ix8n3/Dx/zm19R3A8ehXjCk0D4aOaMHxP/uUXvwYFuUYU7IgzzLyn39bnv+//TTH+Tsb7ZxztYsLYt+ef0dEIkCDjyvU/7U9evyp0M6og+Ic/+oND9/4fJfJGHxbjod9p3+8Ijf2PMsL6ZTD1roESoHK0q4d/tD+P9oc1OustSOspKll9Mp5b2W2zSGUSn0QkDfi9x+/NzLpz8IZyyh7jCM7YLll/Gc3bsRuG39B9Qz17/vuz+u/+/j86u3aVz++uhjVszzeFPGWTo9FwpBzp8RmzxFk0DONxvyaJNleUlG49G4d3S+KFk+TVl5leXv+sDBJStJliThOuxLNTr6ZQgeZWo0Hv3qtbj69dGbmw2bFvF6k7Cjt/B8iiw++iUAjNPlx+CS5mWW30wH2DyQSNnnz+xyxWxA6OgivYzzLEXH9TROWGfHQR9M1dHFNZu/BkTL7n6X0G8wi9OBsmfEviIuse0yXrNsW5Kh4xB7Rqg7QivXpxNkBgk3mwn8Hb1iBYcfJlfhTaFuX7P51Aeyn6VwmyS/5mxh0eOb6XqblLG9BcolA38I+fcHRXmTsP68KL6zOfav/+HQ9Yz4j1I/GP64/r+PzwTpIl8fEVDz2dKOGNtMyEMndCLqfqRaN2HKEmimLg1oVG+2XXwwonPXFw/WDPTcptg6d113rrdiXzdwo+FYb2XRkk1IvpyFj1zfPya7f2CVBT05X5ZHLJfdqDc+JnR8At1cD7tRt9bNnuXxclV29XbHsvf8JkwBpeEiGi+cXVM1/OFosXAWC+1JFK8l1GAI8GgA/3gOAh36EmjJrnHoPIrGbLhrEkMfBtEoHIdaczXXwl2MFjPxJArTJVL7cLEIZiPF8u1sljBuMSYkiVMW5vYyD6MYLOAj6vsRWx6Th+yERQtKnA/gej6aA2nE9/EmDGfe3CHUcT7oNQAqrKlHx3RRexzGLbMFjpiNMtdzmZiN+jR0XX0C7L4tJoQGm2u9xS6AFdTBxm+Ojj7k+rcGGxiDNLgcNmEUgReQd7Ps2i7ir3iDEnAmxs6y6IYPn4Xzd8s826bRhFyG+aNKnTkq8yzJcvUASeWtiywt7UW4jpObCfnZM7DL+c+OSRGmBcZCMWfDOk7tFRMiAsouV3zaPhh8CJTTMgTG5BL/a/sqjsrVhASeI+itaCLhtsw6wBESxcUmCQGHRcL4OPwGfUEXCB55guhv1ylnTFbEoi1nSVjGl+yjOvFwRwhyGRZWJS6WJPGmYOTEAcSIz/8NS0L9D4hNUXatGg1r75iUObBjE+YAhgQg2OO9E4w4aK+aAICD11QTUBfgUgSuVrdnzACaKmdoyjC7ZPkiya4mZBVHEUu5IAYfkqcgg5LM43y+jWE5ZWEeERTxNmdkxlZxGhEGQyFxAQUiHw4M4U0mM7bIoO/XXE9ACVKQjWXVuR3OCpBBybkdpwUrlaJmMaqNDTNAtDMhaZbyPl/ZMC+7lr2yTTiPSxAwkOzXBWbH6xDMH6fZXGUnYpEJVqD56RG6ua5zDBokx8zRBw420IF1BsbYc1GMrtJiyAoFmp2Cx0WP+oFS9+ELZT5LACy/0ucc+WgdmmvojAg70K7hFT+pEvunF+cfX7wiA/Lp24+5VFfbiANorKbfgI+PFzd2JVxAZc7sGUSvjPFVFSbxMrXjkq0LMczmsVvNEtExsMRFxVbWrDJFZZmhPYNHoCRxpHSXP+61rc+GOR0LYVU+UP2BvgyNJeJVi7ABxfM1kUuP2+MC0JtoTzoE8PGUjnb2mpvZVRjhEnM4OU5tIPrpntB+WLyE88ODfzjWzjH/T7hBlC6Iw07YomyXyR6OL0MIQagnnUN/rtZmu2JIk+t5QibKtqr7/RPPGS7eVh3ZPZJiVr4MtNsQaWNRoC1KGC6FoS/t30M3HLpDdqyCKLCUTaZz1gJnHcl+XY9knADKoHrxJWqy3+8di+Fj9QSsOhp1tOkQJ4kgRTB8lcfpO26hFJ+xrsN5LblKaZ2r6v5eWLKzTDvadGvVxiFOmluxhncUBO80sUaw0kZOXY4OoK5Kul1XIaa5kFXg1+smXTPwvjFhP6fka8XQIQYGFTvF3Te1zu6uM7e/O43md9pEEHATNVMfnRvmzcSgNEzBcAtSi02cEtr3Cmk4QJEWMWT/jCP8i3fsZpGHa1aIjjh4kWdrQIdbH3CRGPlmZVgy7lp6ODshZdbaYxhUfQD4igp4tXjr83wWl5DAN0Iu3k34Idp3c7auGq8kLyDMwLaEleh70ZwLE933hX42wj2lYfiQ3+sKxY16m+kdK1MGYxMcL2MEDbiuvq3A0Vk09QihgsErt8WOMYJipz8aS5L3TiRCS7vMwFhKW1djkS9YdKj940bXVzZXoNZneZ7lTZpFciKpWGcRJIGzEHxD3dLHKaqZfci8gR4tC5JkU+V9h+h3nVbrc3JyIts1+9PlG1tMottrd7xur7fPKtTN8kemFIOgTXGDdsV1WhW3LnKT2X3DVgd1Ux0caqnb1cs0unUt7nIiEJa9yd6xlGzybJmzooCZch6cldgMmEOimWNUqDuZE+cQ1FvF/NCZOYwOuxwpysw1XWTQWD9jAbiZYNwmfSmWHXGLOEk4bVqO98GhxORsw8BWp0vb1F4e7lHKVVjLjoSfBO6ZjUqSyMrmAHSg0NjuXJ02c0WEhZc+k8sNdBY8CQsLtgv38spGNswOX+eSz23Rx6xM7eUqK8pGMt9VeqhHuWaIe8DS3VMYMKQlnlali54Wdw7Hdd1V9/NtXiBgmR+abk3ahjr3XR5x13TV0+K9joDclI7EnROGlTG/OCbajcHuyQq1XjBdGzgxF/sthikBl2AXV3E5X0lo7dF6u3eoIABafxHy15x8W1xzSF3qXhKb+9A+XXj3qU1rlm7rtkTVVtqjdxEJSd8ha6pOu7Pb1a7v6OEP0Is2J1IVL4YcIawBKt/nVzFNLfdGYQwbnsv37yQQ5GA/27C0zsZZks3fad0yvu13QJpuRG0qHFOkSE+3K5gghtRr+jmtmqGzX4l3T61WrZ6xr0Lk5jLjETjHG2wHW5QNSnUl1b1vIzJ0xgcrq4DcD+do6G7PEpoxoQieXl+8efPsxSevycvzFxfPeeAEwsaQoBAaK0xrxWFPlqT2q7muugcUq+5Qjdb04JsGqgmeLGimN63Zjdog6bUBitPNthkX1EK/W+38ASt3x1ZHU9y9qWTNUMcp+L647IpFW8s1XjfBk0U2l+lhti3RC+6WyB7jKqPw88evRdwNJrJ9ab9X9bKpWTz+DWdCzoms0OrMDP50A1BFoTVFOmktDci8t8UwGAS7FcEGOnow1QicgNSDV3ltwg5P2KwXuF31AphaefF2v6ixv3vJ6htQTgOwTpuhMUKxnnx6/oY8//wTrlxJtuyUuzJLyh/aAEhtgt3ZwlTF4DXklKFZabgdirY3N3a5l9LqYuti+Szl9TQtn9HKYeI5p1PUw3Y1uI/0yhe/hFCXffkowH2VXXmsGkC7BjiqUlZR2MdDJ00d614OQS2ivG1XU2S/ai1U/N3Vceqw91XhdiIHzR21lx1Ea2fZQ6KTa/l/hU2/uAEL1nTVuKuPm/q4py8OAHRxCiusAhTudLfBatTI9yzsHbQwvj9YstTWBIfFKOqMjqnrt8JTxTgiI4ibAoI1IrUIWA9LJE6PeSQkojkWHYPFIGJzny9j2RkZjWO/ri8YFdcdqIYyNPumAVYqtJkCfmQI31GUPFmFpcSyqKEphFgFpwVLFnILiaVRI2jdPdBWl4DRl0bv2Gg/ww3CdJKERWnPV3ESdR0w2B2faAaK5tkKI8Rwm/uI1WEJ3Lrh/3jyotv18SS6qjX1Pb+ZS6jKaWObzkwlWmqgfj0glEm7lkAovuFSaJNItanXud9nQGmRCbTeUSJh3J7b6875jqJQ8jhYFF2SaCR1B5Z4DohxO+QEGdoKGM/NLqC8yZl9lYebOuu5kTUkuMv37rb26zmYgiJW9bMXL9++IeevLs75muaRrg2hV7inbKgSzeZWvCYynv7fwxa8Fgwe1wUFttc8m6IHwRopu4RFi4zuLXepasc7fgw1Q/FeCUu7SnelMUFDh/0OJrxnEnO3qY/llvmwK3JuYDUBLZuzVZZErGV/q5aM1kbPthAvHVCi9H3j7E37Dncgjs0tThazcW2RGywydm/U9rCx46PuJS0P8Vw9DQ3pUlDj7tqJWZk3LZgnE+OWSKdpxjr9iZ5gVeEwP8RZdHB8oqUlWgBdzMOEPQKF9bpENQGLEoJLEA6jvku/40CaobWCJIVF1aGy8ycXmEVzK7XA40KVkdrFu65mhu6c02ibIepUU58fsrLBQl/G7EoEYlq65no1k/e+9Y67FnnuXljWkraWjPA2S9yww/xsR9vWreP3iOt3HoA7eW9IbfUz84gcduf/6Flufeuw3YQ1QwA9FoNF5rQuMEcsnrZ9Fb7/BqseNCWMalurvrG1Cl5Oql2clKhCUZ5tJJaPePmhfXVDuNgz0mac8GmSQZAu9wFtUFV8S6J2rETgVVwua2jJlMLcJN1x8TIuYli2GgjpPoRX7UB+qHCn7ogjLqxO0OtpgJY5rJcKVIOgeP4OfMKw7+4hSisO7LiA0NCe85OQX+/N8wk/ItnVx1bVg7aZBHrGXLpd8/UJtAdDBXHNojgkj8DILFhe2DmLtnMW2etMaRXe9/gUulLpnOLuiU/TYGlbt6Zli9fLrjQTm6rNNK/9xAd1VYWgDrZ/qFs3Ax6Zsh71txuQZXRYQKr2UTc5YJHfHBN+VzAwiBHcd1dEh61EtZWkzXigPdpuO2HStf/YEvvtccfHcqmZW8eS5PsLhHwjEGrGMAcHIodntgY1al+oMi8C1RQypEeUbwbxco02QEUlrTGJ6H/UohQ//O72fe371mgT/JtAMPWoCrt6WNLqjPP3V8ZM8F2hnLcvlOuHaZjcFDEaumKbNLeROrfK/qTwqpaqdtibRskg8LtlpseBgYysOtL6PZFHWxlIRbyvLl6//PzF62d/dYExr3ITmoX2MHaQjsEIVOuvtZzIY63g4PHoay37cLjREr6jcSasHrZwz/FDvx/35/7pD/jRhP6qXCff1Rz73/90A4+65vufI/rj7z98L5/Tn3z8+ZM3X768IKgBZ0en+EXwTMPUYqmFDRD+wRfafjJfhTmYk6n19s1Te2yp5hQC1KmFpmCT5aWl3qKaWnw9TyOGL3wLM4KOBWINcCPcUeIPSBxjzBevt2u9idfN8R5N/jTNcK4yLhN2hi9u47vp3/7tb8nTbZKQ11swg6cD8fToFIzqO8yNphaYJ8AkhYzWIisId6fWqiw3xWQwQJNU9JdZtkxYuImL/jxbW2rs7V0H86Jwfy5Cqak6xj65Auv3C9x+xn2xE8f5qezAd+DEUw+eYI9A9PqpDC+nxVW4sQTS/HXsYsVYadWI0dolhtWL29hxIMWE70OeHR2dRvElmSdhUUyt2mtW0BdM7+lPbFu9QGXbZ9iC4yH6kWNW28g646mwDkm90iMf1R/iewcWiSN5pbpAJ6zd673E2wk5tc5OB/js9q7uIV2jrDS7nQ4AQR1ZbfyKnp0/vniOv3RQg1Ud9rfOzp9JcMBeqg3dqL7inLygWly/AYdtkSgsQzum4xRR4xrIgJ/f/ts/kSfq9nSw0SBqfNTOeGtMNAhuobXqc/YZQiCfvHxLxv1xg2+DOhtaaeGe+fEWUABiuJ5NrZ0bd/oj4cVVEIa5yEf6iWoMehC/DhINx18ns7UfnqvWUQvzp7xF4ibiBp5C4rR1Cms6sLvRLw0dz4X4W5S8ds5V13FZGUYMsc/jMrVqY2bYwE3U1HoODVvc4x+QN2GYWGcXL04HAoDBLwXuM5Zu6/DwbF+dbxIDvZM4lSbVcWfThZb88Xf/8Af4+y+pIOQiXSZxsWpicjDsNNFg/w/8/beC/YKBbYFOUdFCaId86kxVJ6R0xlaHmGFp/ce/m5D10XOw3XnX0L//3/rQCgdhVFm+M5nG+TxpOpWkFI4vMZOopqqf7apUVlUWeGqvbK04MgeJJFrt+HFYsGdY0a4ZFExeWBq9zZPn2Ns6eywayNtXz8kjtt6UN2RKkgx8JygY/0ZCe6cDDl3OJLaoSvwJFqvkNgspqE+qVVN2/vAm2+b8l4JYzr3mDjW71n+H5stds6JTF2x4yc7FtKaAZJpdox67W2ev4V9daFJkSkz89JsmHGVOwllhYLB7QkQyLyeDBtCaVQj68cff/csfpPHVzTo8exPOrDM8plB5iZoaNabQYeOWAsL+5983YeMzDvspXLTANqjlR7Jwq8JQR4WihkF1fkwS2zR/SbYUqoAXbRZQnU8Spzq63Dye9bDOHGfC/9/ru8WRIwAHYv3ydXtXjTkZ39v+rADstB8qEq19cl68IyHhv1mG53E7owH9kpe7JDK7DSSr4uFTeL5jRfvCwX7mUq2vBxzxmeCdsbLwd5AAabUT3+9b/KAcLK5NwkqYJlssLNOqCQSK7WwdSxQKWG24gs6+/c/fmwYNSWzRnGqTy9AcpYAtmtOiMtXuWKu+1CoFVgX+pWxoDxCqurMRAV0uCY56nF1PLfHmJr7461i1cdCrNgxBs0VRb0Jjy0tvn8jKG8cMx2ODRa4pzPCBRW7k97Ur7+Eb4wzLBIfoQehDQFg8Q8LO2CDqXlNL/pSMbJSRE3Trn/jW4DZgfMY6OPGbNU1wfgs4MP01WhvPxdvaTVYkGYhsDsz2cf45TODhBcwf+O/Bgi6c3XtlQRv9dQIbz+dJvHkZlitBOejdE2hoo2+DnaDPZ4AOGZMnhHpj+KYjj3gB/zpxsRUuKIX2AP6G8OfjX4BPfBdaR1jigl6B+B6PyXO8cKlHnvALN8DfSSHu0MONEf79hATiQj6X/Z9LAE8kQG/M4XuunHDocgwQIOVfHEH4BnwBlzERlPx1G9cUW4zVNBDLqd6I9iRcz7j+LEFvpE3ReqifCkF9gkmFPlEKF/m1usAWFy4w3p9a2zx59FApYg8xbM7Jd6eKGGKcLZ4uVcdMmtNz0el2Qva0DLL/PKVrECn4i7EnLp8cciqd27BMeqpdlG1ALH2vXQDV5l9BUF82LMJDz0Isq3DTIokl72ijQNSscsn16pYcQTdWIQxXGGsWQEfV6QcWqZvElqXMtYSbeWHlUe3Qyruomjf8otUqmeM8c5x32LjAHBccNm5sjhsfNo4vudpAbDloZIM19EDe0AZz6IHcoQ320AP5QxsMogdyyG1wyD2QQ25TeW7jkCuHVgPluNv449XHeYeOC+rjgkPHjevjxoeO4+qmDaTOwSMN1tCDeUMN5tCDuUMN9tCD+UMNBtG9HDodLE1numwzqhAiQ7xCFizkP2MmzGurId1ZS9m52Fn0h9FiMRMxZ92UD62aB9Cj0aa9RXzYTcv8hk8f+dKlO2Pl0oVHD1r4UAsG3LuMlL8k1JwRWA4+ShJmkC4p3QvNQOO9wElezfLsqpVfVfwYuOQkIF+MfHICDnoMNy3QdtEmFd0BReyPLr91AE6fZkXT55qhK5BInp9A+AGRxBe8ASMLB+MStwPuGuKl1V7AIxESCXh4gz8GGYw74P0mvOIbRdk23wsVERs65AseWvlk5OIGc92/72UdjsPxnEIAQN3x7RCMdXo6gKSyu4aulzO01L5WuBIni2q1MF79ecvbIf/HrJhsVlmZ3bKHoWbSzirpabReoADlZbucW0xlkXA+Z5tSpuaDDy15ZrG9mi1m6SrNAQ3/+nfNIo0kFomxziSFOmktVWBtSn5k46tGObA6CWIRdRQEpv/tPzanlwCss3Nx0TFrJ2eNMyPWDitofCXaztqqSaq+Un3/X3vP2t22jeV3/QqUk63JrUzLj2S7yqgdx1YcTx3bx4/Mtl4fhpYgmTFF6lCUHdej/WX7bf/Y3nsBkABJUXLT1+4ReuqIIJ4X940LUNyqja82NlinJokSF2e7x+dHuxeHJ8fnzO4esw3WPYc/x0fOUk0AgCYpO9z89ph1KFCDMR615S96LTaf2swyNqOspiwBgC0W2teysnIFJzQUXdILXdGCRhPQzjw/s6qHDmAohh7gLE96OiEbvbFZtnRjQTY6UrPszIMILxa7ELNqmgMPKpaddqpcidCh9DxKL1bCPCiuU0xWRCI1DlqidzYyefcbDkv+1AdEO2aTIz7Aa03peqYJHQfMwYe7I7TedObuNpjgxesqGyCSAymYMGA3/ce8dTq4eJrwQfAZGujiE/ybrRYtoMo9pydRhcW93jRJNJySWAZAV+Xp3yw/GqJhmd5y2apbAI2AwK76zYi96YBQFPzWB7bYV2UhA1YEc7KCGH0cR3vPHg9Vn4lWonA+3X3gyQ2wMh7V0d1xwFN2Xyo5l/LWifJCzodEeHf+L6W8T/H0QVFeFBYJ72Q8CX0/Wp72DvjPQe82XZb8zlMeMs4jdp/4/rCG/KjQDU+w8efQH1YbijFNBgtpcFBDghMOUryCCHdBGt3C4sGyAaAXkSIGTc4hxSGf9G4DDu0Ajg75AxBmkRqHPOFAo3PI8S3obAuocYDR7fF4yNOE63hWpkZsjN0EnwgpMWosAvaHs6ynx8EN5yEGQ0r6gwFHS1AlZ6NgEk7v0oVUuXhcgi7h7+x1Q8jRfZ5CI4TTfYp2wv34JtQZ+BgkCnQtt8MbdGqdEauKUty5V2LtHJgkMhiA3GHKRzbG2eB7y2H//CfDjXYMxQwGzP4KBfKV1sS1U2hQlIbig2lEc2OpfccfHclBEg6GXcTsUjvs669ZKfMKal7TIPCVyyPKwGf4F8c0M3qCYYePF/L4AWRMbNVtP+5N8esarvrRDekzUXTlDYxa6/R1w6wB4jN5POchfcNjNwxt6yrTz64txx3ESdfv3dpA653vdD4J6guMEhrnIUJ2N02TALQ2bltZfYsCYgnZQxe34PbkpmZHQk28njnPGZS+WfelA9TbMgY7McrrpZpy6MWxiw5lRAl0ms0Fupar8ebxsG9nQSeyAUQ7meWo6gVYaavnpvHleMyTPX/C7SXApt95pMEKb2/TgAWPLinUR8i30ng4DGHWcue5Sa8rABgKEgJ9Vh+hBpci/gJQVUANTVlhb055oSA5QUWioQI9EwZjvkHZkyJlN6mkHEsF3bzW1oyuL1uwYBTWo60Y1nGopga4hI9ARNgWXuRl5fPPGvb7/S5ePo+FecQT29o/eS+X+QhEGOo1DGg6W5nKgX8RtuX13j9j1kVERWam3jsZFinkLU+zh4ehcG7c0dEOKM3FHcHTBAz8Ic3QzoiQZT1UoGYOYYMGfwVSEMRQM4XCDJiB1bWUok1tVjv25XuvAFEZCfUOSbQ6SrZ2P4/RBXXLQ2ApuBd444fhI5vETFjD7qcJ64GKNIVC2bG3PnrWMEyqgacEo3784CIrRTOWpU2Gn5fCYaFsUuJQFz9shrId7HxpbyvLm02SXsfK+qWYSVnkrxsiVvavGyLy+Y+OxP5jkv79t2gYRJ/xAo7Br9vHgu+/bW63tovff9ve/rdV/P/vkYSKLIk/JNbAvm291h+v2u3rtsoT5T2M+GcZ5rj4axIP0gcwXiAHHTZKpIQYEeCN/M8ekpuHAcRss/VevkZ5S1J8Q+M/4yT+/OiNgfcwtEnBJDW/uPa6UBILeTAqNA/wgoPie+Clngxvf4c3DL9Ae7im0H+sn3E/XD88ZS+Q76XcA96Z1FZ4Gycwd5C1+Iu9ECWglvfZG6hX+GvJRkB2gQnyAqw/kJ01dS7HeHCQw4wQBFPxVFM+N56YJUtbr/Ptp7+wo/jOD8H0wgjyENbevo9BFwql7eWwuyk0ECHb9ofs5+BThKyZD1gyxcud5HfyJoUBoMfI076hNymOUNqatWUwvK2iwKwx+6NJ6P90cjcy4fib9bHg/Ffr5avi9383X75anf/6XdIvNyNA01vHWOvckFAqn93ngyAClS6IWH660MHimrmANqhwckCTtq7zfa9rgK70hLSZMO31vs/xUyPsg58EPt0SpzpAj426Ae+d9GZ32NX16+zthHR43seNAfx4KLyOpmGYF5CR8JdJWOPvUUWky8cyRwfwY9L4mRTnnp+vqbOW9GM4hqmlH4JZ3IA8LGO0kJ9WqquvnWlSoM/s7ukYrBBOTsx9cZbBBmnpBxFo8WAoB6MgdTShjoaeNh/HsHaYDhE3AGmQyKF9fPGUynmQ39RyZm324inraQaaw4sn6m32UTOFKvqV4EIrE4uz71irOAoBm3EPe37vp7cu6C12qyl/B5G92YKnfJ7oYBcT/VeMtNONsXxSol9XHNcT306geUE3s38pjXmW4dC5PDiir1p+CqZ22bTDMuaq6ydUlmlBHGUx2tDPiNQ1YZwlMUdhHPmoHYZ5OMRoRZ3pqaufnfvRGMeFf6ODlC5I7tSa+Hh0wyQ//0ZyxiWqZpHz2hhon+3yUJ+NPGhQOxt1GMGEgzp6sKhqxUrgBb513pp4qI8amaU56jyqoK4ZLfbA6D0LLairnMcfmFiYxQjU4mAeSWDU1k4gLBq4OqhQ7j2LBVg4gjxqQIPmoTgHjfaQHz3KrYjd00PcQc9cYzoROQbpufd+OEW5lYuhIodGn9E4gBc26M50EYzO78RMbqCq0YibJsHIdtyEk3/a3vjPjW9ebDRBumnMTXpgqPL3yMvw1+zFk+pn9hHktXp4XeBrKBs3XfaWp71b+bkgKQqVkPQnj1Evn8cAS16iNLf1CaTyOpUi+044UqX/4AOPp6p2DghrA2a6MaVTOEVujfCGum58VxQLedvoeMsax8KfJqZ7UW8MC7uZrPCEEGNfdTpsGkkVqaonTBXCtbK1Jo3I7ftB+OgJUVQey6xR/TRjYHzDGtg8SaokYRzKe4ltS2zO4b4YQZQRBNugEWLVsgjDv/qqmYrRlpvJNvY120MeLTjiGxEDpNAAYahLPJDchlzSx6yVe5aflZlNSiktD2fCSte+hZWUEZTfM4tuW7UA70VW2S07yz3eBQkIEzMJXZuXUfKZUzOU2DLzkKRuIsy8HZBM121qzVZQUGGF6qFbBFUZb2qAqIS7wdRk3jMBNd9Y0KcG4rCKXiFbqKzvLt4foWpXSdFLnaEsVSqfqXzxFIHQ2sdvLDpuGh/hcvELeHVO/nPbmZWvBahptP70ZWXV70gll5EKVn1/hUhJlT6+nseSnCppse2i1sbO6dw9qt2KQ6Dylu254CFeY2XpWw3PwgOzPXyfVmyCyC3Mkrafa4VZGz1so1ffRrERrTSMPi9q9qY00QSEGwKnQ1Urtok07bWqbr4hPE+HQRNMdTOD/z9WUL3RlmM2vXg+2aoXBMWOK+TCW6kJgLaUPhriQanEBg+QeRVrL8/LNqWGUdo5xMRdPKwK1fZFMEiRQUrgCfM006trOCptRNNFXtkWdIFLj0FVkrFNoPBORDyAuvlL69nsDPmnVWirwMjc8XRyaz+xBEQ5CCbZdHZjK01iVjk/VLqB0iQekPgwRokcA4MWLBX3VIHKJf0sb36xjkaH753mHP1oxNPbGIOFTk/OL7IIITMJn/ekzZ6YJVFxHcM2LaiGe+CB2HrYQBXOUmF7xYSbFm329/OTY1dsUAaDRwBo/n2FouiYOWX9qwiZHA5L65Pmeig2UtUwoZvQY9ErRfohaXHzdM15K6uFklkO+0bqsyJ4ExpO0UuQxZPB8ldpnoyHE75cv35gSW0WTY/HitYw1SM48BnI96NUx/K8zRKu6zD7Am0d0/Ia+1ar1ZozjlkZgqagrNHYMc3FkgWwz9a8EPVXknGYCqYBcWj6XbYHzBkUhLsegaYNBgM9JfsruA+/IgVMD+NRwwFCAu1KE2G9hMNqSDiAIAzudXkDj0IoHeM2JmhsSiEDSQe9645Eye0DKrdA89KIkWQihoiTjSD1PKIaPdOq9j8KnaxTKAs2xtpi1W0NDJC1NXMFcLqGglqpVuK/SpdjaNFD67Nc44P1UG91n2UVgT+/v8JlXvKmiXJ3qnXD02ZbbuZiK8YDwpNunWY/UWcXaLeHnxOxoVE9RgjeTnrAU8KLeEz+f/X8ju64LDlCoHqV3vrSFT6zM96LhxFdsVujy+TuMLAHc5+ZjiNZkYV6bV7fpRe2IZ61txUN3eInhaoCq3IUHYg9E1B4SNNz8Xly1aowmvBNFauq2IHBotWelNyP52iePze7ERbq+iF+uWuuukHb34KCsbczyqjijKKoG0fSq2mTLlgBCGOSuaOwTkZoxQoEghdiU6jSiyfqT8FVHECaZbdG5dex0mVn+m3ZW3S/fuFmWnER28elpc1ceOA/uxNgfv7l2ZFY1CXZfHH9cvBoKzkfnaWmXrEAJBKKaDRPx65EmjSZ8jLGmi5bp+DsNXanUuViJgW40KekFLBE9oWWR8gnH4uop4pJrmSLw3kw/9IEf1UtW8Jlna6j+iJtWyjKahq/ig785art85dzsdJrnleo1JBq1d5njon6V+//f2uvz1+tyiMhRW8HpoLO+oHq1WqtII0iilstj7NWAlVPP+eJ+OuPDvrQkrvh8uje5Z99vG3st+ljQfxna3NrsxD/s7W5tbOK//k90snR0e77XQ+EekfGWmYnBtubmzvbOw28XtB7f7LfPeqEoT/ytxsfDs8PT46NPHdrXdDinwm3V2lxckENGLvjx9+yjwXxf9ubr0r3v7d2Xq7o//dIwQivbGfxpCF/4U7+qx31lN6i4g/yX2UknE7GTxr0LWRUGsg3It/is3gzAFv+TmW/xYemqttkqOAFg0dUbqO+h+U98eWxOHnUqnu9OJmoNvZOzs5lpzGYCPcqH800T2Q1GtqD7TQagNogmKl326OYdc9rUuhb0PMG8vpN18qypknoiVvJLKeBHdrQArTzl7n3LsArwUFhfMdvDw8uz3YvDru4VYjnr5tsmEDDoDXhuRk2iadJjzt1zeXsGAYeT3ArBudi5fkwWquaU1s00gt+Rx9J9VMK4mb2zb3LBJNu4pHaNPFDR2PqZj95PvYjqol2UWXi66JNDApnfnawl0cb6kC1POLL7FHMU3GMm8SCrIgR4185hgAx+9ff5CPIpIsYCoV+okuNj8aAEGMROHL+4/lF9713enby/vQCDXdSuKy/c3aDzqD82HRTHgH37/2oxzmYy5C5LlzHWLIfcHV+vp/4aJTcBz47oaG4zMqa9aP0AQDRTzHuFVCpyQQSMzqXfjsNxz/7/giDYPv8Zx4OoJ8UGwU9EQ8nD/lNMg3uwLbW2rybRri3BEsI70HVxcPSLD+wDpDWwa6fqLYaixD14uSH7vGby/2D7gU77Z6xg+6bs8vDH+AXfuWFFHsmIy2tDZoZ9IDxvH1/iEhbPBuAi5kh+MgHLtpHWEHFu3hEvIBt5rOEBvoCrqE6mM3svdPLjYPTSwchCJYGAAcIBTcK62ayv3t49KNHs/GODt8f4mLj4HH6h4BpfIT7MCkOMsHNn2AMf3EvlHZ+tlpbr9Zb3663thG/5HTxk2LbOzNQzz2KbPEwlgNNDMX+3KMYfWjyNZ5KmzUaYFcxDzDXk4dcgrHtiE8aZmc+oKTkeq7cjkJUt63CiRHLUa6SrGa76GPM3rhgnwXQRtNyrlrXtC0FHTe0oqpL7fSKGC0OtmjS2cFYjjqN+yLmJU3Q+uMuZdiOaPshSG+ZBh59gMCocariLc0QGtWd4VGcqmLAOsSvK7Em12Cliq7bhvEk51Ja7SJcZIhuGSvWs37kKl87Agp4LoeyxHhhrE15MwNkgJ38Z4SGaOwqGF8j8ilspoI6GmvTyI1PdEYUYWsChn3T0asKMPVuee/Ou6HQPC9OPGE7Z9hiWdYBx6/KH8cRcDaeTIfE2oCuRR2GfMGPEOmJ42Jw3RjscN6U0ec94CQOS6dgeLrQmsRgFVrdmYutilbysn/tsFaJYKSWYZsGvPDwAKgGyG9v+U3KPnFkcTwMPt1NOAV0480rfsSeSkg1k2DCi0d4cJe67DSJgSEndOEHMB7kyg9cvwxDdlucCIygpbkHmmxn6991GkaoShaDNxGNYMEVCGhvLFsEIZjoGJY8GICsj26noTVB4cXv/RC0KRAuG0JienmOGCfxb1w+mPcwwhMSqEKkNBt2G8AEk+kDszdFD+y/2A6KKRiNky2dRGwcXWktWvrUkGI3mwxkiJgKbpfsSNr0BNbFNCk8OQbDuAm5YqxpotFFknNXwVYH1lOuKM3IwZn6Q9raFAfHOi+d4sgSVyCjh9gIQgdFCZXhn/GWtLwD8Yzn5d0zkddVOaXpvkVf0AJxvOmKm/ttuYDrSukgAdtkud7G4kGuudW0+Tc05ZKYQn/yGIqmdN9OOlfCfwtsUJC3nyqwBqgnF0UZvZHkLxygnfk8QWGAXr4EFv1lQ8eZBav+HKL+AehWQjRCOhaECigbj5mOHS77CaiVtBRZXCh7bbYmhiGUlDXXMqj0ZWtbXo8hvNZK1OK8yG89CUL89NVFMgXeBjB7EnxYxS0ojy5pASoT1ugKhZMGkSzAZC4AsjkjG85uQqLLb/gQ/rvnkUV8BTUjbEBCVxvJ1ZOFgRPYhtyiBlmi9lLbzNCoZyAkslE1KohRMnedJsdgm9jmNkeZQnv6tVEi4Rw7Zb+r+DQSDCy3Usp7ETlQ28UZVxQGouL+CIoKitXfFQKCFAfZ/DZn205p9m7iBxOOJ309wVZso4w4LJAVFhsdDa0EBql0ZEkDR2BlnmaOyFIrREH5+uldQxSUGD2zAxFdjCaFlguzomwSF1lrmjpQGFGpYRhIC/dK9EKFt7r2Y7RsCO5yvyXZJ2KD8kkv0uUaSzIQatdqiyVYLLprVRPCHtlzjRQp3mS1mNIFdxuSWS3uukIxP/Lv5JVXcv2LnM5SjGvBgC4Eii/DchTL5LBKoBuknG7noLvMWDzCZ2Udo+InacdRI9lZNJJ3Fxen4rI9H3THfEB9nvpBSIGPOaImBVU5K8TdAqVJ1KRJCOJRdeRYKiS60SLaAtxAZguZ9QA/JWsJSx9Luvj92USXXgsRkBAtX2fxCbe1p5zTzdaEPAPGThcCumw/fhBBCqR68lTxOzbGryLqVc3b/8UatJZBN7HM6wO6Ru5JTG5m6Q0UAVdYsLq2I0CWBx9lFpMdCPDmHdQrUFsuO+j+dLj37uL8XfcMVPTjw+MDtsF2377pdo/28Ttdu8e7Rz+edzMdS3dGPU+VMjbK56lUspCHhVaq1S9WrWDkaxT+sEYzCHKHBoUZLa0S5a4yoJr/+W9xAtFQiWQYk9H8lez7OnPJQC69oktPQGKtrT1DK8Nw1D70L+M4eFIYgsG+gtHQu3lMSTmjbtH9ZBsMB62mrJhTIUDnj+gItEIdKKBGoLVX1BOzgdBOAIxE/HBvXu3wCK0krX+3zylHk7PSJascsBkeZVdmkjtUG4fL3uA9l0nwadBmJquyNh12wKUpClMHvSb41J/0QCEYxknAi8W3HPYTasE3fsIZOr8CvsE/j0EMTMqFtx22Gw4xQpQDBoO+AqAFExAQesQTvLizWOEfnKPhfxfFY3LyonSBNb2PQw2TDY3jF6rE5PpFD8/z1GLdeV6h64qFsdpyhSpKEOKjenOVr//1n15rViEiBTVVlS+qyX9SxVbN4jfQbVXTsGDq50rDXTCQWg03U2jpI9S6UpHti4gbkmCce6eXK7V3WbX3g75ZuPakM7Rn679G5T+lBly46PjZCvC2y84vdi8u8QsBoAmfHO+/6x7un++96+798CzlVn76WVdrD7qZVqtYclv3IsW4PTZXtxSqUwQ1gSL6Hq0nOZwypSprpj0fo7/MvztvCKMrCxU56xp31BjtzyYGoYiiwid3vSSp4GV1gh3ORXerCKbcQRXfNUvFpgmK9Hy6WglUh7w6X5iMi/TqFQOtHS8DFMmIR1uLDwD4jHJQFSHqzOm11KKx5798m8V30FoxqyFIegGx7LjsrHt+0T3rHu8zuQt+cvrhbPege/wsYplKd1wlrQhBvdD0m48k2k0OMNXS/pMGmefK7IUQeinYySEyEPYGYLV7vP8M2FgCAnThl4KAnGdFmI9NcTdWfj0Yqmi7R0cn/+juezSMPdro1Ao0UfHE+wN6kwk9ZLe6zhrmUOjrP238852V8zCM+UEDz8YXaokGjL4UJO1McwAlJm4d6xLIQptpZ6l5Uo+NBvSmwpBQQbQ8D9fK8yzR0zgJImRyeKJOyMC26cZxjGK6sGwX5Z1ZVCozwEbahuJUXUzY9Te+j+ETc3m8qkyAn0Z2n99Mhx2yCJoMo5Lww0r0HwIgTtIO3t3prAJEV2mVVmmVVmmVVmmVVmmVVmmVVmmVVmmVVmmVVmmVVmmVVmmVVmmVVmmVVmmVVmmVVmmVVmmVfpX0v0RjAycA8AAA
