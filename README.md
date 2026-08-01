# Abel123 AI

Een AI-assistent gebouwd op Anthropic Claude, met twee functies:
- **Chat** — gesprekken met Claude
- **Gezichtsherkenning** — analyse van geüploade foto's via Claude Vision

Draait volledig op de Anthropic API. Geen Google/Gemini-afhankelijkheden.

---

## Vereisten

- Android telefoon met Termux geïnstalleerd
- Een Anthropic API key (console.anthropic.com)
- De project-zip (Abel123-AI--main.zip) gedownload naar je Downloads-map

---

## Installatie — stap voor stap

### 1. Termux voorbereiden

Open Termux en geef toegang tot je opslag:

    termux-setup-storage

Installeer de benodigde pakketten:

    pkg update && pkg upgrade -y
    pkg install proot-distro nano unzip -y

### 2. Zip uitpakken

    cd ~/storage/downloads
    unzip Abel123-AI--main.zip
    cd Abel123-AI--main

### 3. .env aanmaken met je API key

    nano .env

Typ hierin:

    ANTHROPIC_API_KEY=jouw_eigen_anthropic_key

Opslaan: Ctrl+O -> Enter -> Ctrl+X.

### 4. Ubuntu (proot-distro) installeren

Dit is nodig omdat Termux zelf geen prebuilt Python-wheels heeft voor sommige dependencies (zoals anthropic's jiter-package). Ubuntu via proot-distro lost dat op.

    proot-distro install ubuntu

(Dit hoef je maar één keer te doen — niet elke keer opnieuw.)

### 5. Inloggen in Ubuntu en naar de projectmap

    proot-distro login ubuntu

Let op: je bent nu in Ubuntu, met een ander pad. Ga naar de projectmap:

    cd /data/data/com.termux/files/home/storage/downloads/Abel123-AI--main

### 6. Python en pip installeren (eerste keer in Ubuntu)

    apt update && apt install python3 python3-pip -y

### 7. Dependencies installeren

    pip install -r requirements.txt --break-system-packages

### 8. App starten

    python3 app.py

### 9. Openen in browser

Ga naar:

    http://localhost:5000

---

## Elke volgende keer opstarten (kort)

Zodra alles hierboven eenmalig is gedaan, hoef je alleen dit te doen:

    proot-distro login ubuntu
    cd /data/data/com.termux/files/home/storage/downloads/Abel123-AI--main
    python3 app.py

Daarna browser naar http://localhost:5000.

Om te stoppen: Ctrl+C in Termux.

---

## Projectstructuur

    Abel123-AI--main/
    ├── app.py              # Flask backend (Anthropic Chat + Vision)
    ├── index.html          # Frontend UI
    ├── script.js           # Frontend logica
    ├── style.css           # Cyberpunk-styling
    ├── requirements.txt    # Python dependencies
    ├── .env                # Jouw API key (niet delen!)
    └── README.md

---

## Problemen oplossen

**ModuleNotFoundError bij het starten**
-> Je zit niet in Ubuntu, of dependencies zijn niet geïnstalleerd. Herhaal stap 5 en 7.

**TypeError: Metaclasses with custom tp_new are not supported**
-> Dit kwam door een oude Google/Gemini-dependency. De huidige app.py en requirements.txt bevatten dit niet meer — zorg dat je de laatste versie van beide bestanden gebruikt.

**Pagina laadt niet in browser**
-> Check of python3 app.py nog actief draait in Termux (geen foutmelding, en de terminal "hangt" met de server actief).

**API-foutmeldingen in de chat**
-> Check of je .env bestand een geldige ANTHROPIC_API_KEY bevat, zonder spaties of aanhalingstekens.

---

## Veiligheid

- Deel je .env bestand nooit — het bevat je persoonlijke API key.
- Zet .env in .gitignore als je dit project op GitHub host.
- Deel geen screenshots waarin je API key zichtbaar is.
