import os
import base64
import threading
from datetime import date
from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
from dotenv import load_dotenv
import anthropic

load_dotenv()

app = Flask(__name__, static_folder=".", static_url_path="")
CORS(app)

# --- API Key ---
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")

# --- Client ---
anthropic_client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY) if ANTHROPIC_API_KEY else None

# --- Systeemprompt ---
SYSTEM_PROMPT = (
    "Je bent Abel123 AI, een geavanceerde AI-assistent gebouwd door Abel. "
    "Je antwoordt helder, direct en behulpzaam in dezelfde taal als de gebruiker. "
    "Je kunt tekst genereren en gezichten/afbeeldingen analyseren."
)

# ========================
# TOKENBUDGET PER GEBRUIKER (per IP-adres, per dag)
# ========================
DAILY_TOKEN_LIMIT = 20000

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

# ========================
# 1. CHAT (Anthropic)
# ========================
@app.route("/api/chat", methods=["POST"])
def chat():
    if not anthropic_client:
        return jsonify({"error": "Anthropic API-key ontbreekt"}), 500

    ip = _get_client_ip()
    budget_error = check_budget_or_error(ip)
    if budget_error:
        return budget_error

    data = request.get_json()
    messages = data.get("messages", [])

    try:
        response = anthropic_client.messages.create(
            model="claude-3-5-sonnet-20241022",
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            messages=messages
        )
        reply = "".join(block.text for block in response.content if block.type == "text")

        tokens_used = response.usage.input_tokens + response.usage.output_tokens
        add_token_usage(ip, tokens_used)

        return jsonify({
            "reply": reply,
            "remaining_tokens": get_remaining_tokens(ip)
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500

# ========================
# 2. GEZICHTSHERKENNING (Anthropic Vision)
# ========================
@app.route("/api/analyze-face", methods=["POST"])
def analyze_face():
    if not anthropic_client:
        return jsonify({"error": "Anthropic API-key ontbreekt"}), 500

    ip = _get_client_ip()
    budget_error = check_budget_or_error(ip)
    if budget_error:
        return budget_error

    if 'image' not in request.files:
        return jsonify({"error": "Geen afbeelding geüpload"}), 400

    file = request.files['image']
    if file.filename == '':
        return jsonify({"error": "Geen bestand geselecteerd"}), 400

    try:
        img_bytes = file.read()
        img_base64 = base64.b64encode(img_bytes).decode()

        media_type = file.mimetype if file.mimetype in (
            "image/jpeg", "image/png", "image/gif", "image/webp"
        ) else "image/jpeg"

        response = anthropic_client.messages.create(
            model="claude-3-5-sonnet-20241022",
            max_tokens=300,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": media_type,
                                "data": img_base64
                            }
                        },
                        {
                            "type": "text",
                            "text": "Analyseer deze afbeelding. Beschrijf: 1) Geschatte leeftijdscategorie 2) Zichtbare emotie/expressie 3) Algemene opvallende kenmerken. Wees beknopt en respectvol."
                        }
                    ]
                }
            ]
        )

        analysis = "".join(block.text for block in response.content if block.type == "text")

        tokens_used = response.usage.input_tokens + response.usage.output_tokens
        add_token_usage(ip, tokens_used)

        return jsonify({
            "analysis": analysis,
            "remaining_tokens": get_remaining_tokens(ip)
        })
    except Exception as e:
        return jsonify({"error": f"Analyse mislukt: {str(e)}"}), 500

# ========================
# 3. RESTEREND BUDGET OPVRAGEN
# ========================
@app.route("/api/usage", methods=["GET"])
def usage():
    ip = _get_client_ip()
    return jsonify({
        "daily_limit": DAILY_TOKEN_LIMIT,
        "remaining_tokens": get_remaining_tokens(ip)
    })

# ========================
# 4. STATISCHE BESTANDEN
# ========================
@app.route("/")
def index():
    return send_from_directory(".", "index.html")

@app.route("/<path:path>")
def static_files(path):
    return send_from_directory(".", path)

if __name__ == "__main__":
    app.run(debug=True, port=5000)
