# Abel123 AI (Ollama-editie — 100% gratis & open source)

Een AI-assistent die volledig lokaal draait via **Ollama**. Geen API-key, geen kosten, geen data die naar een externe partij gaat.

- **Chat** — via een lokaal taalmodel: `llama3` of `mistral`
- **Gezichtsherkenning / afbeeldingsanalyse** — via een lokaal vision-model: `llama3.2-vision` (of `llava`)

---

## Belangrijk: kies de juiste modellen

Niet elk Ollama-model kan afbeeldingen verwerken. Voor `/api/analyze-face` heb je een **vision-model** nodig:

| Doel | Geschikte modellen |
|---|---|
| Chat (tekst) | `llama3`, `mistral`, `llama3.1` |
| Afbeeldingen/gezichten | `llama3.2-vision`, `llava` |

Gebruik je alleen tekst-modellen zoals `llama3` of `mistral` voor `/api/analyze-face`, dan krijg je een foutmelding — die modellen kunnen geen afbeeldingen lezen.

---

## Vereisten

- Een computer of server met minimaal 8GB RAM (16GB aanbevolen voor vision-modellen)
- [Ollama](https://ollama.com) geïnstalleerd
- Python 3.10+

---

## Installatie — Linux / macOS / VPS

### 1. Ollama installeren

    curl -fsSL https://ollama.com/install.sh | sh

### 2. Ollama starten

    ollama serve

(Laat dit in een apart terminalvenster draaien, of gebruik de systemd-service die de installer aanmaakt.)

### 3. Modellen downloaden

In een nieuw terminalvenster:

    ollama pull llama3
    ollama pull llama3.2-vision

Wil je Mistral in plaats van Llama3 voor chat:

    ollama pull mistral

### 4. Project uitpakken en configureren

    unzip Abel123-AI-the-App-main.zip
    cd Abel123-AI-the-App-main
    cp .env.example .env

Open `.env` en zet de gewenste modellen:

    OLLAMA_URL=http://localhost:11434
    CHAT_MODEL=llama3
    VISION_MODEL=llama3.2-vision

### 5. Dependencies installeren

    pip install -r requirements.txt --break-system-packages

### 6. App starten

    python3 app.py

### 7. Openen in browser

    http://localhost:7878

---

## Installatie — Android (Termux)

Let op: lokale LLM's zoals llama3 en zeker llama3.2-vision zijn zwaar. Op een telefoon werkt dit alleen met voldoende RAM (8GB+) en kan het traag zijn.

### 1. Termux voorbereiden

    termux-setup-storage
    pkg update && pkg upgrade -y
    pkg install proot-distro nano unzip -y

### 2. Ubuntu installeren (eenmalig)

    proot-distro install ubuntu
    proot-distro login ubuntu

### 3. In Ubuntu: Ollama, Python en de app installeren

    apt update && apt install python3 python3-pip curl -y
    curl -fsSL https://ollama.com/install.sh | sh

### 4. Ollama starten (in Ubuntu, aparte sessie/achtergrond)

    ollama serve &

### 5. Modellen pullen

    ollama pull llama3
    ollama pull llama3.2-vision

### 6. Project uitpakken

    cd ~/storage/downloads
    unzip Abel123-AI-the-App-main.zip
    cd Abel123-AI-the-App-main
    cp .env.example .env

### 7. Dependencies en app starten

    pip install -r requirements.txt --break-system-packages
    python3 app.py

### 8. Openen in browser

    http://localhost:7878

---

## Elke volgende keer opstarten (kort)

    ollama serve &
    proot-distro login ubuntu   # (alleen nodig op Termux/Android)
    cd Abel123-AI-the-App-main
    python3 app.py

---

## Status controleren

De app heeft een ingebouwde statuscheck om te zien of Ollama bereikbaar is en of je modellen geïnstalleerd zijn:

    curl http://localhost:7878/api/status

Dit toont onder andere of `chat_model_installed` en `vision_model_installed` `true` zijn.

---

## Projectstructuur

    Abel123-AI-the-App-main/
    ├── app.py                    # Flask backend (praat met Ollama via HTTP)
    ├── index.html                # Frontend UI
    ├── script.js                 # Frontend logica
    ├── style.css                 # Cyberpunk-styling
    ├── requirements.txt          # Python dependencies
    ├── .env.example               # Voorbeeldconfiguratie
    ├── deploy.sh                  # Installatiescript voor een Linux-server/VPS
    ├── abel123ai-service.txt      # systemd service-bestand voor de Flask-app
    ├── abel123ai-nginx.conf       # Nginx reverse-proxy config
    └── README.md

---

## Kosten

Geen. Alles draait lokaal op je eigen hardware. Je enige "kosten" zijn stroom en rekenkracht (CPU/GPU) van je eigen apparaat/server.

---

## Problemen oplossen

**"Kan Ollama niet bereiken"**
-> Ollama draait niet. Start het met: `ollama serve`

**"Model niet gevonden"**
-> Het model is niet gedownload. Draai: `ollama pull llama3` (of het model dat de foutmelding noemt)

**Analyse van afbeeldingen geeft een fout, chat werkt wel**
-> Je `VISION_MODEL` in `.env` is geen vision-model. Zet dit op `llama3.2-vision` of `llava`.

**Alles is erg traag**
-> Lokale modellen zijn zwaar. Zonder GPU kan een antwoord tientallen seconden tot enkele minuten duren, zeker bij vision-modellen. Overweeg een kleiner model (bv. `mistral` in plaats van `llama3`, of `llava:7b` in plaats van grotere varianten) als je geen GPU hebt.

**"Out of memory" foutmeldingen**
-> Het model past niet in je beschikbare RAM/VRAM. Kies een kleiner modelformaat, bijvoorbeeld `ollama pull llama3:8b` in plaats van een groter model.

---

## Veiligheid

- Er is geen API-key nodig — er gaat geen data naar externe servers.
- De ingebouwde daglimiet (2000 "tokens" per IP) voorkomt dat één gebruiker je lokale server (CPU/GPU) volledig blokkeert voor anderen.
- Zet je `.env` in `.gitignore` als je dit project op GitHub host (ook al bevat het bij Ollama geen geheime sleutels, het is nette gewoonte).