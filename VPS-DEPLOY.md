# Abel123 AI — Backend deployen op je VPS

Dit maakt je Flask-backend (`app.py`) publiek bereikbaar op een vaste URL, zodat de Web2APK-app (en elke andere frontend) er verbinding mee kan maken — ongeacht of Termux open staat.

Gebaseerd op dezelfde aanpak als je VetPulse AI-backend.

---

## 1. Bestanden naar de VPS

Vanaf je telefoon of PC, upload de backend-bestanden naar je VPS (bijv. via `scp` of SFTP):

```bash
scp app.py requirements.txt .env root@jouw-vps-ip:/home/abel123ai/
```

Of clone je repo direct op de VPS als de backend daar (zonder API key) op staat:

```bash
ssh root@jouw-vps-ip
git clone https://github.com/Abelsoftware1233/Abel123-AI-.git /home/abel123ai
cd /home/abel123ai
nano .env   # vul hier je ANTHROPIC_API_KEY in
```

---

## 2. Python-omgeving opzetten

```bash
cd /home/abel123ai
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
pip install gunicorn
```

---

## 3. Testen met gunicorn

```bash
gunicorn --bind 0.0.0.0:5000 app:app
```

Check vanaf je telefoon of PC: `http://jouw-vps-ip:5000` — als de chat werkt, ga door naar stap 4 om dit permanent en veilig te maken.

Stop de test met `Ctrl+C`.

---

## 4. Systemd-service (zodat de app altijd blijft draaien)

```bash
nano /etc/systemd/system/abel123ai.service
```

Inhoud:

```ini
[Unit]
Description=Abel123 AI Backend
After=network.target

[Service]
User=root
WorkingDirectory=/home/abel123ai
Environment="PATH=/home/abel123ai/venv/bin"
ExecStart=/home/abel123ai/venv/bin/gunicorn --workers 2 --bind 127.0.0.1:5000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
```

Activeren:

```bash
systemctl daemon-reload
systemctl enable abel123ai
systemctl start abel123ai
systemctl status abel123ai
```

De app draait nu intern op `127.0.0.1:5000` (niet direct publiek — dat regelt Nginx in de volgende stap, met HTTPS).

---

## 5. Nginx reverse proxy + HTTPS

```bash
nano /etc/nginx/sites-available/abel123ai
```

Inhoud:

```nginx
server {
    listen 80;
    server_name abel123ai.abelsoftware123.nl;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    client_max_body_size 10M;
}
```

`client_max_body_size` staat op 10M zodat foto-uploads voor gezichtsherkenning niet worden geweigerd.

Activeren:

```bash
ln -s /etc/nginx/sites-available/abel123ai /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx
```

HTTPS met Let's Encrypt:

```bash
certbot --nginx -d abel123ai.abelsoftware123.nl
```

---

## 6. CORS controleren

Je `app.py` gebruikt al `flask-cors` met open CORS (`CORS(app)`), dus verzoeken vanaf de Web2APK-app en GitHub Pages worden geaccepteerd. Wil je dit later beperken tot alleen jouw eigen domeinen, pas dan in `app.py` aan:

```python
CORS(app, origins=["https://abelsoftware123.nl", "https://abelsoftware1233.github.io"])
```

---

## 7. Frontend koppelen

In de Abel123 AI-app (browser of Web2APK), open het ⚙-instellingenpaneel en vul in:

```
https://abel123ai.abelsoftware123.nl
```

Opslaan — vanaf nu gaat elk chat- en gezichtsherkenning-verzoek naar je VPS, en werkt de app overal, ook zonder dat Termux open staat.

---

## Checken of alles draait

```bash
systemctl status abel123ai
curl -I https://abel123ai.abelsoftware123.nl
journalctl -u abel123ai -f    # live logs bekijken
```
