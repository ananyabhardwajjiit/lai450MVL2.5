// lfm-vision status page client
// Polls /api/status every 2s, updates DOM. No framework, no build step.

const $ = (id) => document.getElementById(id);
let lastData = null;
let startedAt = Date.now();

function fmtUptime(seconds) {
  if (seconds == null) return "—";
  const s = Math.floor(seconds);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m ${sec}s`;
  if (m > 0) return `${m}m ${sec}s`;
  return `${sec}s`;
}

function fmtNumber(n) {
  if (n == null) return "—";
  if (n >= 1e9) return (n / 1e9).toFixed(2) + "B";
  if (n >= 1e6) return (n / 1e6).toFixed(2) + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "K";
  return String(n);
}

function setStatus(level, text) {
  const dot = $("status-dot");
  const label = $("status-text");
  dot.className = "dot " + level;
  label.textContent = text;
  $("hero-status").textContent = text.toLowerCase();
}

function applyData(d) {
  lastData = d;

  if (!d.api_reachable) {
    setStatus("warn", "model offline");
    return;
  }
  if (!d.model_loaded) {
    setStatus("warn", "loading model…");
    return;
  }
  setStatus("ok", "online");

  $("card-model").textContent    = d.model?.id || "—";
  $("card-arch").textContent     = d.system?.arch || "—";
  $("card-ctx").textContent      = d.model?.context ? `${d.model.context.toLocaleString()} tokens` : "—";
  $("card-threads").textContent  = d.model?.threads ?? "—";
  $("card-parallel").textContent = d.model?.parallel ?? "—";

  $("card-host").textContent     = d.system?.hostname || window.location.hostname;
  $("card-cpu").textContent      = d.system?.cpu || "—";
  $("card-ram").textContent      = d.system?.ram_mb ? `${d.system.ram_mb.toLocaleString()} MB` : "—";
  $("card-gpu").textContent      = d.system?.gpu || "none";
  $("card-uptime").textContent   = fmtUptime(d.uptime_seconds);

  $("card-requests").textContent = fmtNumber(d.traffic?.total_requests);
  $("card-tps").textContent      = d.traffic?.tokens_per_sec_avg?.toFixed(1) || "—";
  $("card-active").textContent   = d.traffic?.active_requests ?? "—";
  $("card-last").textContent     = d.traffic?.last_request_at
    ? new Date(d.traffic.last_request_at).toLocaleString()
    : "never";

  // Show OpenWebUI link if installed
  if (d.services?.webui_port) {
    const link = $("openwebui-link");
    link.href = `http://${window.location.hostname}:${d.services.webui_port}`;
    link.style.display = "inline-block";
  }

  $("svc-api").textContent    = d.services?.api    || "lfm-vision-api";
  $("svc-status").textContent = d.services?.status || "lfm-vision-status";
  $("svc-webui").textContent  = d.services?.webui  || "lfm-vision-webui";
}

async function tick() {
  try {
    const r = await fetch("/api/status", { cache: "no-store" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    const d = await r.json();
    applyData(d);
  } catch (e) {
    setStatus("err", "status server unreachable");
  }
}

// Try-it form: send a text-only chat completion
$("try-form")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const prompt = $("try-prompt").value.trim();
  if (!prompt) return;
  const out = $("try-output");
  const status = $("try-status");
  out.classList.add("active");
  out.textContent = "…thinking…";
  status.textContent = "request in flight";
  try {
    const r = await fetch("/api/chat", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ prompt }),
    });
    const j = await r.json();
    if (!r.ok) {
      out.textContent = "Error: " + (j.error || r.statusText);
      status.textContent = "failed";
      return;
    }
    out.textContent = j.text || "(empty response)";
    status.textContent = `done · ${j.elapsed_ms}ms`;
  } catch (err) {
    out.textContent = "Network error: " + err.message;
    status.textContent = "failed";
  }
});

tick();
setInterval(tick, 2000);
