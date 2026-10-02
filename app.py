import os
import base64
import threading
import time
import uuid
from collections import deque
from datetime import date

import requests
from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__, static_folder=".", static_url_path="")
app.config["MAX_CONTENT_LENGTH"] = 8 * 1024 * 1024  # max 8 MB upload
CORS(app)

# ========================
# OLLAMA CONFIGURATIE
# ========================
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434")
CHAT_MODEL = os.getenv("CHAT_MODEL", "dolphin-llama3")
VISION_MODEL = os.getenv("VISION_MODEL", "llama3.2-vision")

SYSTEM_PROMPT = (
    "Je bent Abel123 AI, een geavanceerde AI-assistent die lokaal draait via Ollama. "
    "Je antwoordt helder, direct en behulpzaam in dezelfde taal als de gebruiker. "
    "Je kunt tekst genereren en gezichten/afbeeldingen analyseren."
)

# ========================
# WACHTRIJ INSTELLINGEN
# ========================
WORKER_COUNT = int(os.getenv("WORKER_COUNT", "2"))          # 2 = max twee gebruikers tegelijk
MAX_QUEUE_SIZE = int(os.getenv("MAX_QUEUE_SIZE", "20"))     # max wachtenden in totaal
MAX_ACTIVE_PER_IP = int(os.getenv("MAX_ACTIVE_PER_IP", "2"))  # max lopende taken per gebruiker
TASK_TTL_SECONDS = 15 * 60                                  # resultaten worden na 15 min gewist

# ========================
# TOKENBUDGET PER GEBRUIKER
# ========================
DAILY_TOKEN_LIMIT = 2000
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
    if get_remaining_tokens(ip) <= 0:
        return jsonify({
            "error": f"Je hebt je dagelijkse limiet van {DAILY_TOKEN_LIMIT} tokens bereikt. Probeer het morgen weer.",
            "remaining_tokens": 0
        }), 429
    return None


def _estimate_tokens(text):
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
# WACHTRIJ + WORKER
# ========================
_cond = threading.Condition()   # beschermt _pending en _tasks
_pending = deque()              # task_ids die wachten (volgorde = wachtrij)
_tasks = {}                     # task_id -> dict


def _ollama_error_message(e, model):
    """Zet een requests-fout om in een leesbare melding."""
    if isinstance(e, requests.exceptions.ConnectionError):
        return f"Kan geen verbinding maken met Ollama op {OLLAMA_URL}."
    if isinstance(e, requests.exceptions.Timeout):
        return "Ollama deed er te lang over om te antwoorden (timeout)."
    if isinstance(e, requests.exceptions.HTTPError):
        try:
            detail = e.response.json().get("error", "")
        except Exception:
            detail = str(e)
        if "not found" in detail.lower():
            return f"Model '{model}' niet gevonden. Download het met: ollama pull {model}"
        return f"Ollama-fout: {detail}"
    return f"Onverwachte fout: {e}"


def _run_chat(payload):
    response = requests.post(
        f"{OLLAMA_URL}/api/chat",
        json={"model": CHAT_MODEL, "messages": payload["messages"], "stream": False},
        timeout=180,
    )
    response.raise_for_status()
    result = response.json()
    reply = result.get("message", {}).get("content", "")
    tokens = result.get("prompt_eval_count", 0) + result.get("eval_count", 0)
    return {"reply": reply}, tokens or _estimate_tokens(reply), CHAT_MODEL


def _run_vision(payload):
    response = requests.post(
        f"{OLLAMA_URL}/api/generate",
        json={
            "model": VISION_MODEL,
            "prompt": payload["prompt"],
            "images": [payload["image_b64"]],
            "stream": False,
        },
        timeout=180,
    )
    response.raise_for_status()
    result = response.json()
    analysis = result.get("response", "")
    tokens = result.get("prompt_eval_count", 0) + result.get("eval_count", 0)
    return {"analysis": analysis}, tokens or _estimate_tokens(analysis), VISION_MODEL


_RUNNERS = {"chat": _run_chat, "vision": _run_vision}


def _worker_loop():
    while True:
        with _cond:
            while not _pending:
                _cond.wait()
            task_id = _pending.popleft()
            task = _tasks.get(task_id)
            if not task:
                continue
            task["status"] = "processing"
            task["started"] = time.time()

        model_used = CHAT_MODEL if task["kind"] == "chat" else VISION_MODEL
        try:
            result, tokens, model_used = _RUNNERS[task["kind"]](task["payload"])
            add_token_usage(task["ip"], tokens)
            with _cond:
                task["result"] = result
                task["status"] = "completed"
        except Exception as e:
            with _cond:
                task["error"] = _ollama_error_message(e, model_used)
                task["status"] = "failed"
        finally:
            with _cond:
                task["payload"] = None  # geheugen vrijgeven (vooral afbeeldingen)
                task["finished"] = time.time()


def _cleanup_loop():
    while True:
        time.sleep(60)
        cutoff = time.time() - TASK_TTL_SECONDS
        with _cond:
            old = [tid for tid, t in _tasks.items()
                   if t.get("finished") and t["finished"] < cutoff]
            for tid in old:
                del _tasks[tid]


_started = False
_start_lock = threading.Lock()


def start_workers():
    global _started
    with _start_lock:
        if _started:
            return
        for _ in range(WORKER_COUNT):
            threading.Thread(target=_worker_loop, daemon=True).start()
        threading.Thread(target=_cleanup_loop, daemon=True).start()
        _started = True


def _active_count_for_ip(ip):
    # aanroepen binnen `with _cond`
    return sum(1 for t in _tasks.values()
               if t["ip"] == ip and t["status"] in ("in_queue", "processing"))


def _enqueue(kind, payload, ip):
    """Zet een taak in de wachtrij. Geeft (response, statuscode) terug."""
    with _cond:
        if len(_pending) >= MAX_QUEUE_SIZE:
            return jsonify({
                "error": "De server is op dit moment erg druk. Probeer het over een minuutje opnieuw."
            }), 503
        if _active_count_for_ip(ip) >= MAX_ACTIVE_PER_IP:
            return jsonify({
                "error": "Je hebt al verzoeken in de wachtrij. Wacht tot die klaar zijn."
            }), 429

        task_id = uuid.uuid4().hex
        _tasks[task_id] = {
            "id": task_id,
            "kind": kind,
            "ip": ip,
            "payload": payload,
            "status": "in_queue",
            "result": None,
            "error": None,
            "created": time.time(),
            "started": None,
            "finished": None,
        }
        _pending.append(task_id)
        position = len(_pending)
        _cond.notify()

    return jsonify({
        "task_id": task_id,
        "status": "in_queue",
        "position": position
    }), 202


# ========================
# 1. CHAT
# ========================
@app.route("/api/chat", methods=["POST"])
def chat():
    ip = _get_client_ip()
    budget_error = check_budget_or_error(ip)
    if budget_error:
        return budget_error

    data = request.get_json(silent=True) or {}
    messages = data.get("messages", [])
    if not messages:
        return jsonify({"error": "Geen berichten meegegeven"}), 400

    ollama_messages = [{"role": "system", "content": SYSTEM_PROMPT}] + messages
    return _enqueue("chat", {"messages": ollama_messages}, ip)


# ========================
# 2. AFBEELDINGSANALYSE
# ========================
@app.route("/api/analyze-face", methods=["POST"])
def analyze_face():
    ip = _get_client_ip()
    budget_error = check_budget_or_error(ip)
    if budget_error:
        return budget_error

    if "image" not in request.files:
        return jsonify({"error": "Geen afbeelding geüpload"}), 400

    file = request.files["image"]
    if file.filename == "":
        return jsonify({"error": "Geen bestand geselecteerd"}), 400

    img_bytes = file.read()
    if len(img_bytes) == 0:
        return jsonify({"error": "Lege afbeelding ontvangen"}), 400

    prompt = (
        "Analyseer deze afbeelding. Beschrijf: "
        "1) Geschatte leeftijdscategorie "
        "2) Zichtbare emotie/expressie "
        "3) Algemene opvallende kenmerken. "
        "Wees beknopt en respectvol."
    )
    img_b64 = base64.b64encode(img_bytes).decode()
    return _enqueue("vision", {"prompt": prompt, "image_b64": img_b64}, ip)


# ========================
# 3. TAAKSTATUS (polling)
# ========================
@app.route("/api/task/<task_id>", methods=["GET"])
def task_status(task_id):
    ip = _get_client_ip()
    with _cond:
        task = _tasks.get(task_id)
        if not task or task["ip"] != ip:
            return jsonify({"error": "Taak niet gevonden (of verlopen)."}), 404

        status_ = task["status"]
        out = {"task_id": task_id, "status": status_}

        if status_ == "in_queue":
            try:
                out["position"] = list(_pending).index(task_id) + 1
            except ValueError:
                out["position"] = 1
            out["queue_length"] = len(_pending)
        elif status_ == "completed":
            out.update(task["result"])
            out["remaining_tokens"] = get_remaining_tokens(ip)
        elif status_ == "failed":
            out["error"] = task["error"]

    code = 500 if out["status"] == "failed" else 200
    return jsonify(out), code


# ========================
# 4. STATUS / GEZONDHEIDSCHECK
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

    with _cond:
        queue_length = len(_pending)

    return jsonify({
        "ollama_reachable": ollama_ok,
        "ollama_url": OLLAMA_URL,
        "chat_model": CHAT_MODEL,
        "vision_model": VISION_MODEL,
        "chat_model_installed": any(CHAT_MODEL in m for m in installed_models),
        "vision_model_installed": any(VISION_MODEL in m for m in installed_models),
        "installed_models": installed_models,
        "queue_length": queue_length,
        "workers": WORKER_COUNT,
    })


# ========================
# 5. RESTEREND BUDGET
# ========================
@app.route("/api/usage", methods=["GET"])
def usage():
    ip = _get_client_ip()
    return jsonify({
        "daily_limit": DAILY_TOKEN_LIMIT,
        "remaining_tokens": get_remaining_tokens(ip)
    })


# ========================
# 6. STATISCHE BESTANDEN
# ========================
@app.route("/")
def index():
    return send_from_directory(".", "index.html")


@app.route("/<path:path>")
def static_files(path):
    return send_from_directory(".", path)


# Workers starten (ook onder gunicorn)
start_workers()

if __name__ == "__main__":
    print(f"Chat-model: {CHAT_MODEL}")
    print(f"Vision-model: {VISION_MODEL}")
    print(f"Ollama URL: {OLLAMA_URL}")
    print(f"Workers: {WORKER_COUNT}, max wachtrij: {MAX_QUEUE_SIZE}")
    app.run(debug=False, host="0.0.0.0", port=7878, threaded=True)
