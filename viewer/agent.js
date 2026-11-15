/* ── Campus Pulse — assistant agent (OpenRouter tool-calling) ─────
 * Bottom-right chat. By default only the most recent exchange is
 * visible; the full history expands on demand. The model can call
 * campus tools (run in analytics.js) that draw ranked "tooltip"
 * pins on the map for points in want of improvement.
 *
 * CONFIG: set OPENROUTER_API_KEY below (or window.CP_OPENROUTER_KEY)
 * to enable live inference. Until then the agent runs in offline
 * mode: questions are pattern-matched onto the analytics tools so
 * the UI is fully demoable without a key.
 *
 * Databricks swap-in: ANALYTICS.runTool() is the single seam — see
 * ANALYTICS.md. This file never touches raw pings.
 * ───────────────────────────────────────────────────────────────── */

const AGENT = (() => {
  /* ── configuration (fill in later) ─────────────────────────── */
  const CONFIG = {
    // 1) create a key at https://openrouter.ai/keys
    // 2) paste it here, or set window.CP_OPENROUTER_KEY before this script loads
    apiKey: "",
    // OpenRouter model id — GLM 4.6 / 5.x family (update when 5.3 flash ships):
    model: "z-ai/glm-4.6",
    endpoint: "https://openrouter.ai/api/v1/chat/completions",
  };

  const SYSTEM_PROMPT = `You are the Campus Pulse assistant for University of Wisconsin–Madison facilities and safety staff. You answer questions about pedestrian activity on campus using analytics tools.

Rules:
- ALWAYS answer by calling a tool first. Never invent statistics.
- Available tools: snow_priority (snow-clearing order before morning wave), lighting (busy-by-day/empty-by-night corridors needing lights), deadzones (night foot traffic with no daytime surveillance), congestion (morning crush points), hotspots (all-day centers of gravity), peaks (per-building peak occupancy hours).
- After a tool call, give a concise operational summary (2-4 sentences): what the ranked locations mean and what staff should do. Reference the map pins that were placed.
- Match the user's phrasing to the right tool. "where to clear snow" → snow_priority; "add lights", "safe at night", "walk home" → lighting or deadzones; "crowded", "busy mornings" → congestion; "peak", "when busy" → peaks; "hotspot", "most busy overall" → hotspots.
- If the question matches no tool, briefly explain what you can analyze and list the tools.`;

  /* Tool schema exposed to the model */
  const TOOL_SCHEMA = [
    {
      type: "function",
      function: {
        name: "run_analytics",
        description: "Run a campus analytics view and place its ranked pins on the map.",
        parameters: {
          type: "object",
          properties: {
            tool: {
              type: "string",
              enum: Object.keys(ANALYTICS.TOOLS),
              description: "Which analytics view to run.",
            },
          },
          required: ["tool"],
        },
      },
    },
  ];

  /* ── offline fallback: route phrasing → tool ────────────────── */
  const KEYWORDS = [
    ["snow_priority", /snow|salt|ice|plow|clear.*(path|walk|sidewalk)|winter/i],
    ["lighting", /light|lamp|dark|safe|safety|walk.*home|night.*walk|well.?lit/i],
    ["deadzones", /dead.?zone|deserted|isolated|alone|solo|surveillance/i],
    ["congestion", /congest|crowd|crush|jam|bottleneck|morning.*busy|busy.*morning/i],
    ["peaks", /peak|when.*busy|busiest.*time|hours|occupanc/i],
    ["hotspots", /hotspot|most.*busy|busiest.*place|popular|center of gravit/i],
  ];
  function offlineRoute(q) {
    for (const [tool, re] of KEYWORDS) if (re.test(q)) return tool;
    return null;
  }

  /* ── chat state & DOM ───────────────────────────────────────── */
  const chat = document.getElementById("chat");
  const launch = document.getElementById("chat-launch");
  const history = document.getElementById("chat-history");
  const form = document.getElementById("chat-form");
  const input = document.getElementById("chat-input");
  const collapseBtn = document.getElementById("chat-collapse");

  const LS_KEY = "campuspulse_chat_v1"; // persisted history

  /* transcript: {role, content, toolCard?, toolRun?}; persisted so past
   * analyses survive reloads — tool cards re-run live against the
   * currently loaded dataset. */
  let transcript = [];
  try {
    const saved = JSON.parse(localStorage.getItem(LS_KEY) || "null");
    if (Array.isArray(saved)) transcript = saved.slice(-30);
  } catch (_) { /* fresh start */ }
  let expanded = false;   // show full history, not just the latest exchange
  let busy = false;

  function persist() {
    try { localStorage.setItem(LS_KEY, JSON.stringify(transcript.slice(-30))); } catch (_) {}
  }

  function open() {
    chat.hidden = false;
    launch.hidden = true;
    input.focus();
  }
  function close() {
    chat.hidden = true;
    launch.hidden = false;
  }
  launch.addEventListener("click", open);
  collapseBtn.addEventListener("click", close);

  /* History rendering: collapsed → only the latest user bubble +
   * latest answer; expanded → everything. */
  /* History rendering: default → only the most recent exchange;
   * expanded → the whole persisted transcript. Tool cards re-run
   * their tool live against the currently loaded dataset. */
  function syncCompact() {
    // card stays a compact input bar until the first exchange exists
    chat.classList.toggle("has-exchange", transcript.length > 0);
  }
  function render() {
    history.innerHTML = "";
    const items = expanded ? transcript : lastSlice();
    for (const m of items) {
      if (m.role === "user") {
        const b = document.createElement("div");
        b.className = "chat-bubble chat-user";
        b.textContent = m.content;
        history.appendChild(b);
      } else if (m.role === "assistant") {
        const b = document.createElement("div");
        b.className = "chat-bubble chat-bot";
        b.textContent = m.content;
        history.appendChild(b);
        if (m.toolCard) {
          const c = document.createElement("button");
          c.className = "chat-toolcard";
          c.innerHTML = `<span class="chat-toolcard-dot"></span>${m.toolCard}`;
          c.addEventListener("click", () => ANALYTICS.runTool(m.toolRun));
          history.appendChild(c);
        }
      }
    }
    history.scrollTop = history.scrollHeight;
    expandBar.textContent = expanded ? "▲ less" : `▼ ${Math.max(0, transcript.length - 2)} earlier`;
    expandBar.hidden = !expanded && transcript.length <= 2;
    syncCompact();
  }
  function lastSlice() {
    // latest user question + everything after it
    for (let i = transcript.length - 1; i >= 0; i--) {
      if (transcript[i].role === "user") return transcript.slice(i);
    }
    return transcript.slice(-2);
  }

  /* expand affordance sits above the input */
  const expandBar = document.createElement("button");
  expandBar.id = "chat-expand";
  expandBar.className = "chat-expand";
  expandBar.hidden = true;
  expandBar.addEventListener("click", () => { expanded = !expanded; render(); });
  chat.insertBefore(expandBar, form);

  /* ── tool-call card + answer pipeline ───────────────────────── */
  async function callTool(name) {
    const result = await ANALYTICS.runTool(name);
    return result; // {title, summary, pins} | null (toggle-off)
  }

  async function handle(q) {
    transcript.push({ role: "user", content: q });
    expanded = false;
    render();
    setBusy(true);

    try {
      let toolName = null;
      let text = null;

      if (live()) {
        const messages = [
          { role: "system", content: SYSTEM_PROMPT },
          ...transcript.map(({ role, content }) => ({ role, content })),
        ];
        const r = await fetch(CONFIG.endpoint, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${CONFIG.apiKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            model: CONFIG.model,
            messages,
            tools: TOOL_SCHEMA,
            tool_choice: "auto",
            max_tokens: 500,
          }),
        });
        if (!r.ok) throw new Error(`OpenRouter ${r.status}`);
        const j = await r.json();
        const msg = j.choices[0].message;

        // execute tool calls (loop supports a second hop if the model asks)
        if (msg.tool_calls) {
          messages.push(msg);
          for (const tc of msg.tool_calls) {
            if (tc.function.name === "run_analytics") {
              const args = JSON.parse(tc.function.arguments || "{}");
              toolName = args.tool;
              const result = await callTool(toolName);
              messages.push({
                role: "tool",
                tool_call_id: tc.id,
                content: result
                  ? JSON.stringify({ title: result.title, summary: result.summary, top_pins: result.pins.slice(0, 5).map((p) => `${p.title} — ${p.metric}`) })
                  : JSON.stringify({ note: "tool toggled off / no data" }),
              });
            }
          }
          const r2 = await fetch(CONFIG.endpoint, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${CONFIG.apiKey}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ model: CONFIG.model, messages, max_tokens: 500 }),
          });
          if (r2.ok) text = (await r2.json()).choices[0].message.content;
          else text = result ? "" : "Tool ran — see the map.";
        } else {
          text = msg.content;
        }
      } else {
        // offline stand-in routing
        toolName = offlineRoute(q);
        if (toolName) {
          const result = await callTool(toolName);
          text = result
            ? result.summary
            : "Cleared the overlay — ask again to re-run the view.";
        } else {
          text =
            "I can analyze campus foot traffic. Try: \"where should we clear snow first\", " +
            "\"where to add lighting for night walks\", \"night dead zones\", \"morning congestion\", " +
            "\"building peak hours\", or \"all-day hotspots\".";
        }
      }

      transcript.push({ role: "assistant", content: text, toolCard: toolName ? ANALYTICS.TOOLS[toolName].label : null, toolRun: toolName });
      persist();
      render();
    } catch (err) {
      transcript.push({ role: "assistant", content: `Assistant error: ${err.message}. The dock tools still work directly.` });
      render();
    } finally {
      setBusy(false);
    }
  }

  function live() {
    return !!CONFIG.apiKey || !!window.CP_OPENROUTER_KEY;
  }

  function setBusy(b) {
    busy = b;
    input.disabled = b;
    document.getElementById("chat-send").disabled = b;
    if (b) {
      const wait = document.createElement("div");
      wait.className = "chat-bubble chat-bot chat-waiting";
      wait.id = "chat-waiting";
      wait.textContent = "Analyzing campus data…";
      history.appendChild(wait);
      history.scrollTop = history.scrollHeight;
    } else {
      const w = document.getElementById("chat-waiting");
      if (w) w.remove();
    }
  }

  form.addEventListener("submit", (e) => {
    e.preventDefault();
    const q = input.value.trim();
    if (!q || busy) return;
    input.value = "";
    handle(q);
  });

  /* On open: render persisted history (collapsed → latest exchange).
   * Past tool cards stay clickable and re-run live. */
  render();

  return { open, close, CONFIG };
})();
