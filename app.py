import os
import base64
import threading
import requests
from datetime import date
from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__, static_folder=".", static_url_path="")
CORS(app)

# ========================
# OLLAMA CONFIGURATIE (lokaal, gratis, open source)
# ========================
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434")

# Tekst-chatmodel (bv. llama3, mistral)
CHAT_MODEL = os.getenv("CHAT_MODEL", "llama3")

# Visie-model voor afbeeldingen/gezichtsanalyse (moet een vision-model zijn!)
VISION_MODEL = os.getenv("VISION_MODEL", "llama3.2-vision")

# --- Systeemprompt ---
SYSTEM_PROMPT = (
    "Je bent Abel123 AI, een geavanceerde AI-assistent die lokaal draait via Ollama. "
    "Je antwoordt helder, direct en behulpzaam in dezelfde taal als de gebruiker. "
    "Je kunt tekst genereren en gezichten/afbeeldingen analyseren."
)

# ========================
# TOKENBUDGET PER GEBRUIKER (max 2000 "tokens"/woorden per dag)
# Lokale modellen zijn gratis, maar dit voorkomt dat 1 gebruiker
# de lokale server (CPU/GPU) helemaal opeist.
# ========================
DAILY_TOKEN_LIMIT = 2000

# In-memory teller: { ip: {"date": "2026-08-03", "tokens": 1234} }
_usage_lock = threading.Lock()
_usage = {}

def _get_client_ip():
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.remote_addr

def get_remaining_tokens(ip):
    today = str(date.today())
    with _usage_lock:
        record = _usage.get(ip)
        if not record or record["date"] != today:
            return DAILY_TOKEN_LIMIT
        return max(0, DAILY_TOKEN_LIMIT - record["tokens"])

def add_token_usage(ip, tokens_used):
    today = str(date.today())
    with _usage_lock:
        record = _usage.get(ip)
        if not record or record["date"] != today:
            _usage[ip] = {"date": today, "tokens": tokens_used}
        else:
            record["tokens"] += tokens_used

def check_budget_or_error(ip):
    """Geeft None terug als er budget is, anders een (response, statuscode) tuple."""
    remaining = get_remaining_tokens(ip)
    if remaining <= 0:
        return jsonify({
            "error": f"Je hebt je dagelijkse limiet van {DAILY_TOKEN_LIMIT} tokens bereikt. Probeer het morgen weer.",
            "remaining_tokens": 0
        }), 429
    return None

def _estimate_tokens(text):
    """Ollama geeft tokentelling terug via eval_count/prompt_eval_count,
    maar als vangnet schatten we hier ruw (1 token ~ 4 tekens)."""
    if not text:
        return 0
    return max(1, len(text) // 4)

def _check_ollama_reachable():
    try:
        r = requests.get(f"{OLLAMA_URL}/api/tags", timeout=5)
        return r.status_code == 200
    except requests.exceptions.RequestException:
        return False

# ========================
# 1. CHAT (Ollama - lokaal model, bv. llama3 of mistral)
# ========================
@app.route("/api/chat", methods=["POST"])
def chat():
    ip = _get_client_ip()
    budget_error = check_budget_or_error(ip)
    if budget_error:
        return budget_error

    if not _check_ollama_reachable():
        return jsonify({
            "error": f"Kan Ollama niet bereiken op {OLLAMA_URL}. Zorg dat Ollama draait: 'ollama serve'."
        }), 503

    data = request.get_json(silent=True) or {}
    messages = data.get("messages", [])

    if not messages:
        return jsonify({"error": "Geen berichten meegegeven"}), 400

    ollama_messages = [{"role": "system", "content": SYSTEM_PROMPT}] + messages

    try:
        response = requests.post(
            f"{OLLAMA_URL}/api/chat",
            json={
                "model": CHAT_MODEL,
                "messages": ollama_messages,
                "stream": False
            },
            timeout=180
        )
        response.raise_for_status()
        result = response.json()

        reply = result.get("message", {}).get("content", "")

        # Ollama geeft prompt_eval_count (input) en eval_count (output) terug
        tokens_used = result.get("prompt_eval_count", 0) + result.get("eval_count", 0)
        if tokens_used == 0:
            tokens_used = _estimate_tokens(reply)

        add_token_usage(ip, tokens_used)

        return jsonify({
            "reply": reply,
            "remaining_tokens": get_remaining_tokens(ip)
        })

    except requests.exceptions.ConnectionError:
        return jsonify({"error": f"Kan geen verbinding maken met Ollama op {OLLAMA_URL}."}), 503
    except requests.exceptions.Timeout:
        return jsonify({"error": "Ollama deed er te lang over om te antwoorden (timeout)."}), 504
    except requests.exceptions.HTTPError as e:
        detail = ""
        try:
            detail = e.response.json().get("error", "")
        except Exception:
            detail = str(e)
        if "not found" in detail.lower():
            return jsonify({
                "error": f"Model '{CHAT_MODEL}' niet gevonden. Download het met: ollama pull {CHAT_MODEL}"
            }), 500
        return jsonify({"error": f"Ollama-fout: {detail}"}), 500
    except Exception as e:
        return jsonify({"error": f"Onverwachte fout: {str(e)}"}), 500

# ========================
# 2. GEZICHTSHERKENNING / AFBEELDINGSANALYSE (Ollama vision-model)
# ========================
@app.route("/api/analyze-face", methods=["POST"])
def analyze_face():
    ip = _get_client_ip()
    budget_error = check_budget_or_error(ip)
    if budget_error:
        return budget_error

    if not _check_ollama_reachable():
        return jsonify({
            "error": f"Kan Ollama niet bereiken op {OLLAMA_URL}. Zorg dat Ollama draait: 'ollama serve'."
        }), 503

    if 'image' not in request.files:
        return jsonify({"error": "Geen afbeelding geüpload"}), 400

    file = request.files['image']
    if file.filename == '':
        return jsonify({"error": "Geen bestand geselecteerd"}), 400

    try:
        img_bytes = file.read()
        if len(img_bytes) == 0:
            return jsonify({"error": "Lege afbeelding ontvangen"}), 400

        img_base64 = base64.b64encode(img_bytes).decode()

        prompt = (
            "Analyseer deze afbeelding. Beschrijf: "
            "1) Geschatte leeftijdscategorie "
            "2) Zichtbare emotie/expressie "
            "3) Algemene opvallende kenmerken. "
            "Wees beknopt en respectvol."
        )

        response = requests.post(
            f"{OLLAMA_URL}/api/generate",
            json={
                "model": VISION_MODEL,
                "prompt": prompt,
                "images": [img_base64],
                "stream": False
            },
            timeout=180
        )
        response.raise_for_status()
        result = response.json()

        analysis = result.get("response", "")

        tokens_used = result.get("prompt_eval_count", 0) + result.get("eval_count", 0)
        if tokens_used == 0:
            tokens_used = _estimate_tokens(analysis)

        add_token_usage(ip, tokens_used)

        return jsonify({
            "analysis": analysis,
            "remaining_tokens": get_remaining_tokens(ip)
        })

    except requests.exceptions.ConnectionError:
        return jsonify({"error": f"Kan geen verbinding maken met Ollama op {OLLAMA_URL}."}), 503
    except requests.exceptions.Timeout:
        return jsonify({"error": "Ollama deed er te lang over (timeout) — vision-modellen zijn traag op CPU."}), 504
    except requests.exceptions.HTTPError as e:
        detail = ""
        try:
            detail = e.response.json().get("error", "")
        except Exception:
            detail = str(e)
        if "not found" in detail.lower():
            return jsonify({
                "error": f"Vision-model '{VISION_MODEL}' niet gevonden. Download het met: ollama pull {VISION_MODEL}"
            }), 500
        return jsonify({"error": f"Ollama-fout: {detail}"}), 500
    except Exception as e:
        return jsonify({"error": f"Analyse mislukt: {str(e)}"}), 500

# ========================
# 3. STATUS / GEZONDHEIDSCHECK
# ========================
@app.route("/api/status", methods=["GET"])
def status():
    ollama_ok = _check_ollama_reachable()
    installed_models = []
    if ollama_ok:
        try:
            r = requests.get(f"{OLLAMA_URL}/api/tags", timeout=5)
            installed_models = [m["name"] for m in r.json().get("models", [])]
        except Exception:
            pass

    return jsonify({
        "ollama_reachable": ollama_ok,
        "ollama_url": OLLAMA_URL,
        "chat_model": CHAT_MODEL,
        "vision_model": VISION_MODEL,
        "chat_model_installed": any(CHAT_MODEL in m for m in installed_models),
        "vision_model_installed": any(VISION_MODEL in m for m in installed_models),
        "installed_models": installed_models
    })

# ========================
# 4. RESTEREND BUDGET OPVRAGEN
# ========================
@app.route("/api/usage", methods=["GET"])
def usage():
    ip = _get_client_ip()
    return jsonify({
        "daily_limit": DAILY_TOKEN_LIMIT,
        "remaining_tokens": get_remaining_tokens(ip)
    })

# ========================
# 5. STATISCHE BESTANDEN
# ========================
@app.route("/")
def index():
    return send_from_directory(".", "index.html")

ALLOWED_STATIC = {"index.html", "style.css", "script.js"}

@app.route("/<path:path>")
def static_files(path):
    if path not in ALLOWED_STATIC:
        return "Niet gevonden", 404
    return send_from_directory(".", path)

if __name__ == "__main__":
    print(f"Chat-model: {CHAT_MODEL}")
    print(f"Vision-model: {VISION_MODEL}")
    print(f"Ollama URL: {OLLAMA_URL}")
    print(f"Ollama bereikbaar: {_check_ollama_reachable()}")
    app.run(debug=False, host="0.0.0.0", port=7878)
