document.addEventListener("DOMContentLoaded", () => {
    // --- Translation helper (defined in index.html) ---
    const t = (key) => (window.i18n ? window.i18n.t(key) : key);

    // --- State Variables ---
    let messagesHistory = [];
    let selectedFaceFile = null;
    let apiBaseUrl = localStorage.getItem("apiBaseUrl") || "";

    // --- DOM Elements ---
    const tokenBudget = document.getElementById("tokenBudget");
    const tokenBarFill = document.getElementById("tokenBarFill");
    const statusText = document.getElementById("statusText");

    function updateTokenDisplay(remaining, limit) {
        if (tokenBudget) {
            tokenBudget.innerText = `${t("tokensLeft")}: ${remaining} / ${limit}`;
        }
        if (tokenBarFill && limit > 0) {
            const pct = Math.max(0, Math.min(100, (remaining / limit) * 100));
            tokenBarFill.style.width = `${pct}%`;
        }
    }

    // Settings
    const settingsBtn = document.getElementById("settingsBtn");
    const settingsPanel = document.getElementById("settingsPanel");
    const apiBaseInput = document.getElementById("apiBaseInput");
    const saveApiBaseBtn = document.getElementById("saveApiBaseBtn");
    const clearBtn = document.getElementById("clearBtn");

    // Tabs
    const tabs = document.querySelectorAll(".tab");
    const tabContents = document.querySelectorAll(".tab-content");

    // Chat UI
    const chatForm = document.getElementById("chatForm");
    const chatInput = document.getElementById("chatInput");
    const log = document.getElementById("log");

    // Face UI
    const faceUpload = document.getElementById("faceUpload");
    const uploadBtn = document.getElementById("uploadBtn");
    const analyzeBtn = document.getElementById("analyzeBtn");
    const facePreview = document.getElementById("facePreview");
    const analysisResult = document.getElementById("analysisResult");

    // Initialize any saved API URL
    if (apiBaseInput) apiBaseInput.value = apiBaseUrl;

    function getApiUrl(endpoint) {
        const base = apiBaseUrl.trim().replace(/\/+$/, "");
        return base ? `${base}${endpoint}` : endpoint;
    }

    // --- Queue helper: start a task and poll until it is done ---
    class TaskError extends Error {}

    const sleep = (ms) => new Promise(r => setTimeout(r, ms));

    async function runQueuedTask(startRes, onStatus) {
        const first = await startRes.json();
        if (!startRes.ok || first.error) {
            const msg = startRes.status === 503 ? t("queueBusy") : (first.error || t("serverError"));
            throw new TaskError(msg);
        }
        onStatus("in_queue", first.position);

        const deadline = Date.now() + 5 * 60 * 1000; // give up after 5 minutes
        let failures = 0;

        while (Date.now() < deadline) {
            await sleep(2000);
            let data;
            try {
                const res = await fetch(getApiUrl(`/api/task/${first.task_id}`));
                data = await res.json();
                failures = 0;
            } catch (err) {
                if (++failures >= 3) throw err; // network problem
                continue;
            }

            if (data.status === "completed") return data;
            if (data.status === "failed") throw new TaskError(data.error || t("serverError"));
            if (data.error) throw new TaskError(data.error); // e.g. task expired (404)
            onStatus(data.status, data.position);
        }
        throw new TaskError(t("serverError"));
    }

    function statusText_(status, position) {
        if (status === "in_queue") return t("queuePosition").replace("{n}", position || 1);
        return t("processing");
    }

    // --- 1. Fetch Token Budget ---
    async function fetchUsage() {
        try {
            const res = await fetch(getApiUrl("/api/usage"));
            if (res.ok) {
                const data = await res.json();
                if (data.remaining_tokens !== undefined) {
                    updateTokenDisplay(data.remaining_tokens, data.daily_limit);
                }
            }
        } catch (err) {
            console.error("Failed to fetch usage:", err);
        }
    }
    fetchUsage();

    // --- 2. Settings & Clear Chat Button ---
    if (settingsBtn && settingsPanel) {
        settingsBtn.addEventListener("click", () => {
            settingsPanel.style.display = settingsPanel.style.display === "none" ? "block" : "none";
        });
    }

    if (saveApiBaseBtn && apiBaseInput) {
        saveApiBaseBtn.addEventListener("click", () => {
            apiBaseUrl = apiBaseInput.value.trim();
            localStorage.setItem("apiBaseUrl", apiBaseUrl);
            if (settingsPanel) settingsPanel.style.display = "none";
            fetchUsage();
        });
    }

    if (clearBtn) {
        clearBtn.addEventListener("click", () => {
            messagesHistory = [];
            if (log) {
                log.innerHTML = `
                    <div class="message system">
                        <span class="time">${new Date().toLocaleTimeString()}</span>
                        <span class="badge sys">SYS</span>
                        <span>${t("cleared")}</span>
                    </div>
                `;
            }
        });
    }

    // --- 3. Tab Switching ---
    tabs.forEach(tab => {
        tab.addEventListener("click", () => {
            tabs.forEach(t => t.classList.remove("active"));
            tabContents.forEach(c => c.classList.remove("active"));

            tab.classList.add("active");
            const targetTab = tab.getAttribute("data-tab");
            const targetContent = document.getElementById(`${targetTab}Tab`);
            if (targetContent) targetContent.classList.add("active");
        });
    });

    // --- 4. Chat Functionality ---
    if (chatForm) {
        chatForm.addEventListener("submit", async (e) => {
            e.preventDefault();
            const text = chatInput.value.trim();
            if (!text) return;

            appendMessage("user", text);
            chatInput.value = "";

            messagesHistory.push({ role: "user", content: text });
            const loadingElement = appendMessage("sys", t("thinking"));

            const sendBtn = document.getElementById("sendBtn");
            if (sendBtn) sendBtn.disabled = true;

            try {
                const res = await fetch(getApiUrl("/api/chat"), {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ messages: messagesHistory })
                });

                const data = await runQueuedTask(res, (status, position) => {
                    const span = loadingElement.querySelector("span:last-child");
                    if (span) span.textContent = statusText_(status, position);
                });

                loadingElement.remove();
                appendMessage("ai", data.reply);
                messagesHistory.push({ role: "assistant", content: data.reply });
                if (data.remaining_tokens !== undefined) {
                    updateTokenDisplay(data.remaining_tokens, 2000);
                }
            } catch (err) {
                loadingElement.remove();
                messagesHistory.pop(); // remove the unanswered user message
                if (err instanceof TaskError) {
                    appendMessage("sys", t("errorPrefix") + err.message);
                } else {
                    appendMessage("sys", t("connectionError"));
                    console.error("Chat error:", err);
                }
            } finally {
                if (sendBtn) sendBtn.disabled = false;
            }
        });
    }

    function appendMessage(type, text) {
        if (!log) return;
        const div = document.createElement("div");
        div.className = `message ${type}`;
        const time = new Date().toLocaleTimeString();

        if (type === "system" || type === "sys") {
            const badge = type === "sys" ? '<span class="badge sys">SYS</span>' : '';
            div.innerHTML = `<span class="time">${time}</span> ${badge} <span>${text}</span>`;
        } else {
            div.innerHTML = `<span class="time">${time}</span><span class="content"></span>`;
            div.querySelector(".content").textContent = text;
        }

        log.appendChild(div);
        log.scrollTop = log.scrollHeight;
        return div;
    }

    // --- 5. Face Recognition Functionality ---
    if (uploadBtn && faceUpload) {
        uploadBtn.addEventListener("click", () => faceUpload.click());

        faceUpload.addEventListener("change", (e) => {
            const file = e.target.files[0];
            if (file) {
                selectedFaceFile = file;
                if (analyzeBtn) analyzeBtn.disabled = false;

                const reader = new FileReader();
                reader.onload = (event) => {
                    if (facePreview) {
                        facePreview.innerHTML = `<img src="${event.target.result}" style="max-width:100%; max-height:220px; border-radius:8px;">`;
                    }
                };
                reader.readAsDataURL(file);
            }
        });
    }

    if (analyzeBtn) {
        analyzeBtn.addEventListener("click", async () => {
            if (!selectedFaceFile) return;

            analyzeBtn.disabled = true;
            if (analysisResult) analysisResult.innerText = t("analyzing");

            const formData = new FormData();
            formData.append("image", selectedFaceFile);

            try {
                const res = await fetch(getApiUrl("/api/analyze-face"), {
                    method: "POST",
                    body: formData
                });

                const data = await runQueuedTask(res, (status, position) => {
                    if (analysisResult) analysisResult.innerText = statusText_(status, position);
                });

                if (analysisResult) analysisResult.innerText = data.analysis;
                if (data.remaining_tokens !== undefined) {
                    updateTokenDisplay(data.remaining_tokens, 2000);
                }
            } catch (err) {
                if (err instanceof TaskError) {
                    if (analysisResult) analysisResult.innerText = t("errorPrefix") + err.message;
                } else {
                    if (analysisResult) analysisResult.innerText = t("visionConnectionError");
                    console.error("Vision error:", err);
                }
            } finally {
                analyzeBtn.disabled = false;
            }
        });
    }
});
