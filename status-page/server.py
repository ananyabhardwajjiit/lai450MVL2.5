#!/usr/bin/env python3
"""lfm-vision status server.

Tiny stdlib HTTP server. Serves:
  GET  /                       Status landing page (index.html)
  GET  /style.css, /app.js     Static assets
  GET  /api/status             JSON snapshot of the system + model + traffic
  GET  /api/metrics            Pass-through to llama.cpp /metrics (Prometheus text)
  POST /api/chat               Proxy to llama.cpp /v1/chat/completions (text only)

All env vars are set by the systemd unit:
  LFM_API_PORT     - llama.cpp port (default 8000)
  LFM_STATUS_PORT  - this server's port (default 80)
  LFM_STATUS_DIR   - directory with index.html, style.css, app.js
  LFM_DATA_ROOT    - where state.json lives

No external dependencies. Python 3.7+.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

API_PORT    = int(os.environ.get("LFM_API_PORT", "8000"))
STATUS_PORT = int(os.environ.get("LFM_STATUS_PORT", "80"))
STATUS_DIR  = Path(os.environ.get("LFM_STATUS_DIR", "/opt/lfm-vision/status"))
DATA_ROOT   = Path(os.environ.get("LFM_DATA_ROOT", "/var/lib/lfm-vision"))
STATE_FILE  = DATA_ROOT / "state.json"

API_BASE = f"http://127.0.0.1:{API_PORT}"

# Where the system services live (used in /api/status response)
SERVICES = {
    "api":    "lfm-vision-api",
    "status": "lfm-vision-status",
    "webui":  "lfm-vision-webui",
}
WEBUI_PORT = int(os.environ.get("LFM_WEBUI_PORT", "8080"))

STARTED_AT = time.time()


# -----------------------------------------------------------------------------
# llama.cpp sidecar calls
# -----------------------------------------------------------------------------
def _http_get(url: str, timeout: float = 1.5) -> tuple[int, bytes]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read() or b""
    except Exception:
        return 0, b""


def _http_post_json(url: str, body: dict, timeout: float = 60.0) -> tuple[int, dict | str]:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(raw)
            except json.JSONDecodeError:
                return r.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw
    except Exception as e:
        return 0, str(e)


def _llama_health() -> bool:
    code, _ = _http_get(f"{API_BASE}/health")
    return code == 200


def _llama_models() -> list[dict]:
    code, body = _http_get(f"{API_BASE}/v1/models")
    if code != 200:
        return []
    try:
        return json.loads(body).get("data", [])
    except json.JSONDecodeError:
        return []


def _llama_metrics() -> str:
    code, body = _http_get(f"{API_BASE}/metrics", timeout=2.0)
    if code != 200:
        return ""
    return body.decode("utf-8", "replace")


_METRIC_VAL = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+([0-9eE+\-.]+)", re.M)


def _parse_metrics(text: str) -> dict:
    """Pull a few useful counters out of the Prometheus text."""
    out = {
        "total_requests": None,
        "tokens_prompt":  None,
        "tokens_gen":     None,
        "active_requests": None,
        "last_request_at": None,
    }
    if not text:
        return out

    n_prompt_sum = 0.0
    n_gen_sum = 0.0
    n_prompt_seen = False
    n_gen_seen = False

    for line in text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        m = _METRIC_VAL.match(line)
        if not m:
            continue
        name = m.group(1)
        try:
            val = float(m.group(3))
        except ValueError:
            continue

        if name == "llamacpp:n_requests":
            if out["total_requests"] is None or val > out["total_requests"]:
                out["total_requests"] = int(val)
        elif name == "llamacpp:n_ctx":
            pass  # not a counter we want
        elif name == "llamacpp:n_tokens_prompt_total":
            n_prompt_sum += val; n_prompt_seen = True
        elif name == "llamacpp:n_tokens_predicted_total":
            n_gen_sum += val; n_gen_seen = True
        elif name == "llamacpp:n_active_requests":
            out["active_requests"] = int(val)
        elif name == "llamacpp:tokens_per_second":
            # best-effort "current" tps
            out["tokens_per_second_current"] = val

    if n_prompt_seen:
        out["tokens_prompt"] = int(n_prompt_sum)
    if n_gen_seen:
        out["tokens_gen"] = int(n_gen_sum)

    # tokens/sec average (over uptime window) - rough but useful
    uptime = max(1.0, time.time() - STARTED_AT)
    if n_gen_seen and n_gen_sum > 0:
        out["tokens_per_sec_avg"] = round(n_gen_sum / uptime, 3)

    # last_request_at: assume last request was within the last n seconds
    # (we don't have a true timestamp from llama.cpp; show relative if 0)
    if out.get("total_requests", 0) and out["total_requests"] > 0:
        out["last_request_at"] = time.time()  # best effort
    return out


def _read_state() -> dict:
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


# -----------------------------------------------------------------------------
# HTTP handler
# -----------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "lfm-vision-status/1.0"

    # Quieter logs
    def log_message(self, fmt, *args):  # noqa: A003
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))

    def _send(self, status: int, body: bytes, content_type: str = "text/plain; charset=utf-8",
              extra_headers: dict | None = None):
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, obj, status: int = 200):
        body = json.dumps(obj).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8")

    def _send_file(self, path: Path, content_type: str):
        if not path.is_file():
            self._send(HTTPStatus.NOT_FOUND, b"not found")
            return
        try:
            body = path.read_bytes()
        except OSError:
            self._send(HTTPStatus.INTERNAL_SERVER_ERROR, b"read error")
            return
        self._send(HTTPStatus.OK, body, content_type)

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]

        if path in ("/", "/index.html"):
            self._send_file(STATUS_DIR / "index.html", "text/html; charset=utf-8")
            return
        if path == "/style.css":
            self._send_file(STATUS_DIR / "style.css", "text/css; charset=utf-8")
            return
        if path == "/app.js":
            self._send_file(STATUS_DIR / "app.js", "application/javascript; charset=utf-8")
            return

        if path == "/api/status":
            return self._handle_status()
        if path == "/api/metrics":
            return self._handle_metrics()
        if path == "/healthz":
            return self._send(HTTPStatus.OK, b"ok")

        self._send(HTTPStatus.NOT_FOUND, b"not found")

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/api/chat":
            return self._handle_chat()
        self._send(HTTPStatus.NOT_FOUND, b"not found")

    # ---- /api/status -----------------------------------------------------
    def _handle_status(self):
        state = _read_state()
        api_ok = _llama_health()

        # model info
        models = _llama_models() if api_ok else []
        model_block = {}
        if models:
            m = models[0]
            model_block = {
                "id":       m.get("id", "—"),
                "created":  m.get("created"),
            }
        if state:
            model_block.setdefault("context",  state.get("context_size"))
            model_block.setdefault("threads",  state.get("threads"))
            model_block.setdefault("parallel", state.get("parallel"))

        # system info - collected once at startup, cached
        sysinfo = _collect_system()

        # traffic from llama.cpp metrics
        metrics_text = _llama_metrics() if api_ok else ""
        traffic = _parse_metrics(metrics_text) if metrics_text else {}

        body = {
            "api_reachable":  api_ok,
            "model_loaded":   bool(models) and api_ok,
            "model":          model_block,
            "system":         sysinfo,
            "services": {
                "api":        SERVICES["api"],
                "status":     SERVICES["status"],
                "webui":      SERVICES["webui"],
                "webui_port": WEBUI_PORT if state.get("with_openwebui") else None,
            },
            "uptime_seconds": round(time.time() - STARTED_AT, 1),
            "traffic":        traffic,
            "config":         {
                "llama_release":     state.get("llama_release"),
                "model":             state.get("model"),
                "installed_at":      state.get("installed_at"),
                "with_status_page":  state.get("with_status_page"),
                "with_openwebui":    state.get("with_openwebui"),
            },
        }
        self._send_json(body)

    # ---- /api/metrics -----------------------------------------------------
    def _handle_metrics(self):
        text = _llama_metrics()
        if not text:
            self._send(HTTPStatus.SERVICE_UNAVAILABLE, b"# llama.cpp metrics unavailable\n",
                       "text/plain; version=0.0.4; charset=utf-8")
            return
        self._send(HTTPStatus.OK, text.encode("utf-8"),
                   "text/plain; version=0.0.4; charset=utf-8")

    # ---- /api/chat -------------------------------------------------------
    def _handle_chat(self):
        try:
            length = int(self.headers.get("content-length", "0"))
            raw = self.rfile.read(length) if length else b"{}"
            payload = json.loads(raw.decode("utf-8"))
        except (ValueError, json.JSONDecodeError):
            self._send_json({"error": "invalid JSON body"}, HTTPStatus.BAD_REQUEST)
            return

        prompt = (payload.get("prompt") or "").strip()
        if not prompt:
            self._send_json({"error": "prompt is required"}, HTTPStatus.BAD_REQUEST)
            return

        # Try-it form is text-only. Vision calls come from the real client (OpenWebUI / curl).
        body = {
            "model": "model.gguf",  # whatever the server has loaded
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
        }
        t0 = time.time()
        code, resp = _http_post_json(f"{API_BASE}/v1/chat/completions", body, timeout=120.0)
        elapsed_ms = int((time.time() - t0) * 1000)

        if code != 200:
            err = resp if isinstance(resp, str) else (resp.get("error") if isinstance(resp, dict) else "upstream error")
            self._send_json({"error": err, "elapsed_ms": elapsed_ms}, code or 502)
            return

        text = ""
        if isinstance(resp, dict):
            choices = resp.get("choices") or []
            if choices:
                msg = choices[0].get("message") or {}
                text = msg.get("content") or ""
        self._send_json({"text": text, "elapsed_ms": elapsed_ms, "elapsed_seconds": round(elapsed_ms / 1000, 2)})


# -----------------------------------------------------------------------------
# System info - collected lazily, cached for 5 minutes
# -----------------------------------------------------------------------------
_SYSINFO_CACHE: dict | None = None
_SYSINFO_TS: float = 0.0


def _collect_system() -> dict:
    global _SYSINFO_CACHE, _SYSINFO_TS
    if _SYSINFO_CACHE and (time.time() - _SYSINFO_TS) < 300:
        return _SYSINFO_CACHE

    info: dict = {
        "arch":      "",
        "hostname":  "",
        "cpu":       "",
        "cpu_count": None,
        "ram_mb":    None,
        "gpu":       "none",
        "platform":  sys.platform,
    }
    try:
        info["hostname"] = os.uname().nodename
    except Exception:
        pass

    # arch
    machine = os.uname().machine if hasattr(os.uname(), "machine") else ""
    info["arch"] = {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(machine, machine)

    # CPU model
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    info["cpu"] = line.split(":", 1)[1].strip()
                    break
    except OSError:
        pass

    # CPU count
    try:
        info["cpu_count"] = os.cpu_count()
    except Exception:
        pass

    # RAM
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    kb = int(line.split()[1])
                    info["ram_mb"] = kb // 1024
                    break
    except OSError:
        pass

    # GPU
    for cmd, kind in [("nvidia-smi", "nvidia"), ("rocm-smi", "amd")]:
        if _command_exists(cmd):
            info["gpu"] = kind
            break

    _SYSINFO_CACHE = info
    _SYSINFO_TS = time.time()
    return info


def _command_exists(name: str) -> bool:
    from shutil import which
    return which(name) is not None


def main():
    if not STATUS_DIR.exists():
        print(f"warning: {STATUS_DIR} does not exist; static assets will 404", file=sys.stderr)
    addr = ("0.0.0.0", STATUS_PORT)
    try:
        httpd = ThreadingHTTPServer(addr, Handler)
    except PermissionError:
        print(f"cannot bind to port {STATUS_PORT}; are you root?", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"bind error: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"lfm-vision status server on http://0.0.0.0:{STATUS_PORT}", file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
