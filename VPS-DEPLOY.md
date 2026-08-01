# Abel123 AI — Backend deployen op je VPS

Dit maakt je Flask-backend (`app.py`) publiek bereikbaar op een vaste URL, zodat de Web2APK-app (en elke andere frontend) er verbinding mee kan maken — ongeacht of Termux open staat.

Gebaseerd op dezelfde aanpak als je VetPulse AI-backend. Deze versie is toegespitst op **Strato VPS**.

---

## 0. Strato-specifieke voorbereiding

Strato's nieuwere VPS-lijn (herkenbaar aan "VC" in de pakketnaam, besteld na maart 2022) accepteert **alleen SSH-key login, geen wachtwoord**. Je moet dus eerst een sleutelpaar aanmaken vóórdat je kunt installeren.

**Op Windows (met PuTTYgen):**
1. Open PuTTYgen, klik op "Generate", beweeg de muis tot de key is gegenereerd
2. Sla de private key lokaal op ("Save private key") — bewaar deze goed, je hebt 'm nodig om in te loggen
3. Kopieer de public key uit het veld bovenin

**Op macOS/Linux (met ssh-keygen):**
```bash
ssh-keygen -t ed25519 -C "abel123ai-vps"
cat ~/.ssh/id_ed25519.pub
```
Kopieer de output.

**Server installeren:**
1. Log in op de Strato klantenlogin
2. Ga naar je VPS-pakket → "Opnieuw installeren"
3. Kies **Ubuntu** (22.04 of 24.04 LTS)
4. Plak je public key in het daarvoor bestemde veld
5. Wacht tot de installatie voltooid is (meestal enkele minuten, soms iets langer)

**Inloggen:**
```bash
ssh root@jouw-vps-ip -i ~/.ssh/id_ed25519
```
(Windows/PuTTY: gebruik de opgeslagen private key in PuTTY's sessie-instellingen onder Connection → SSH → Auth.)

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

Eerst installeren (staat niet standaard op een verse Ubuntu-installatie):

```bash
apt update
apt install nginx certbot python3-certbot-nginx -y
```

Configuratie aanmaken:

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

HTTPS met Let's Encrypt — zorg eerst dat je domein (bijv. `abel123ai.abelsoftware123.nl`) een **A-record** heeft dat naar het IP-adres van je Strato VPS wijst. Dit stel je in bij je domeinbeheer (als je domein ook bij Strato loopt: klantenlogin → domeininstellingen → DNS). Wacht een paar minuten tot enkele uren tot de DNS is doorgevoerd, check met:

```bash
nslookup abel123ai.abelsoftware123.nl
```

Zodra dat het juiste IP teruggeeft:

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

---

## Strato firewall

Strato biedt een firewall aan in de klantenlogin (Mijn server → Firewall). Als je VPS van buitenaf niet bereikbaar is ondanks dat alles lokaal goed draait, controleer daar of poort **80** (HTTP) en **443** (HTTPS) open staan. Poort 22 (SSH) moet ook open blijven staan, anders kun je niet meer inloggen.
