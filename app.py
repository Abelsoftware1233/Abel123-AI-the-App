import os
import base64
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
# 1. CHAT (Anthropic)
# ========================
@app.route("/api/chat", methods=["POST"])
def chat():
    if not anthropic_client:
        return jsonify({"error": "Anthropic API-key ontbreekt"}), 500

    data = request.get_json()
    messages = data.get("messages", [])

    try:
        response = anthropic_client.messages.create(
            model="claude-sonnet-4-6",
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            messages=messages
        )
        reply = "".join(block.text for block in response.content if block.type == "text")
        return jsonify({"reply": reply})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

# ========================
# 2. GEZICHTSHERKENNING (Anthropic Vision)
# ========================
@app.route("/api/analyze-face", methods=["POST"])
def analyze_face():
    if not anthropic_client:
        return jsonify({"error": "Anthropic API-key ontbreekt"}), 500

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
            model="claude-sonnet-4-6",
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
        return jsonify({"analysis": analysis})
    except Exception as e:
        return jsonify({"error": f"Analyse mislukt: {str(e)}"}), 500

# ========================
# 3. STATISCHE BESTANDEN
# ========================
@app.route("/")
def index():
    return send_from_directory(".", "index.html")

@app.route("/<path:path>")
def static_files(path):
    return send_from_directory(".", path)

if __name__ == "__main__":
    app.run(debug=True, port=5000)
