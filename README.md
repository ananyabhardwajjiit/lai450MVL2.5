# lfm-vision

> Self-hosted vision AI for your homelab or VPS. One command, your hardware, your data.

lfm-vision turns a fresh Ubuntu box into a local vision-AI server in a single
command. It runs Liquid AI's [LFM2.5-VL 450M](https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF)
— a tiny vision-language model (~450M params) — on top of [llama.cpp](https://github.com/ggml-org/llama.cpp),
served through an OpenAI-compatible API. No GPU required. No cloud. No
subscription.

```
curl -fsSL https://raw.githubusercontent.com/ananyabhardwajjiit/lai450MVL2.5/main/setandrunall.sh | bash
```

That's it. A few minutes later, `http://your-server/` shows a status page
with the model loaded, and `http://your-server:8000/v1` is an OpenAI-compatible
chat-completions API. Optional `--with-openwebui` adds a chat UI on `:8080`.

---

## Why this exists

Most "run local AI" guides assume you have a 24GB GPU and an afternoon. The
LFM2.5-VL 450M model is different: it's small enough to run on a $5 VPS or
a Raspberry Pi 5, but it's still a real vision model — it can read text
out of images, describe photos, and answer questions about what it sees.

That's the gap. This repo is the install path for people who want:

- **A vision-capable LLM** running on hardware they already own
- **An OpenAI-compatible API** they can point other tools at
- **Something that survives reboots** and just works (systemd, not tmux)
- **No data leaving their network** (everything stays on the box)
- **One command to install, one command to update, one command to remove**

---

## What the model can do

The 450M is small, so set expectations: it's not GPT-4V. It's good at
narrow, concrete vision tasks. Things it does well out of the box:

| Task | Example prompt |
|------|----------------|
| **Image captioning** | `Describe this image in one sentence.` |
| **OCR / text extraction** | `Read the text in this image verbatim.` |
| **Receipt & document parsing** | `Extract the items, quantities, and total from this receipt.` |
| **Visual Q&A** | `What color is the car in this image?` |
| **Object recognition** | `List the objects visible in this image.` |
| **Scene description** | `What is happening in this scene?` |
| **UI / screenshot reading** | `What does this button say?` |

Things it can't do well: long-form reasoning over images, medical diagnosis,
handwriting (untrained domains), precise spatial reasoning, anything
requiring world knowledge it doesn't have. The 450M is a **perception** model,
not a reasoning model. Pair it with a text-only LLM via your tool of choice
for anything beyond perception.

### Realistic use cases for a homelab

- Drop-in OCR for a personal document scanner (paperless-ngx, Immich, etc.)
- Receipt logger for a self-hosted budgeting app
- "What's in the fridge?" photo assistant
- Captioning for a home photo library
- Triage for security camera snapshots ("person at door" vs "cat at door")
- Reading screenshots you don't want to upload to a cloud LLM

---

## Quickstart

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/ananyabhardwajjiit/lai450MVL2.5/main/setandrunall.sh | bash
```

After install (usually 2-4 minutes, depending on network), you'll get URLs
like:

```
Model:     450m (b8152)
API:       http://YOUR-SERVER:8000/v1
Status:    http://YOUR-SERVER/
```

### With the chat UI

```bash
curl -fsSL .../setandrunall.sh | bash -s -- --with-openwebui
```

Adds OpenWebUI on `:8080`. Good for talking to the model in a browser.

### On a Raspberry Pi / ARM64 box

Same command — the installer detects your arch and downloads the right
binary. Tested on aarch64. 2GB RAM is the minimum; 4GB is comfortable.

---

## The 4 install scripts (and when to use each)

The repo ships four installer scripts. They all install the same thing at
the end, but get llama.cpp differently:

| Script | llama.cpp comes from | Status page | Web UI | Best for |
|--------|---------------------|-------------|--------|----------|
| `setandrunall.sh`   | Official prebuilt (x64/arm64) | yes | optional | **Most users — start here** |
| `setandrunall2.sh`  | Official prebuilt               | no  | no        | Headless servers, embedding in other systems |
| `setandrun2.sh`     | Built from source on your box   | yes | optional | Best performance (5-10 min compile) |
| `setandrun3.sh`     | The project's own release       | yes | optional | Project-specific binary optimizations |

**Rule of thumb:** start with `setandrunall.sh`. Move to `setandrun2.sh` if
you want a few extra percent of CPU inference speed. Use `setandrunall2.sh`
if you don't need a web UI. Use `setandrun3.sh` only if you know you want
the project's own optimized build.

Every script accepts the same flags. The most useful:

```bash
# Change the model size (when more are available)
./setandrunall.sh --model 450m

# Change the API port
./setandrunall.sh --port 9000

# Force a specific context size (tokens of conversation history + image)
./setandrunall.sh --context 4096

# Pin number of CPU threads (default: auto)
./setandrunall.sh --threads 4

# One-command update to the latest llama.cpp
./setandrunall.sh --update

# Clean removal
./setandrunall.sh --uninstall
```

Run any script with `--help` for the full list.

---

## Configuration

After first run, a config file is generated at `/etc/lfm-vision/config.yaml`.
Edit it to change defaults and re-run the installer to apply.

```yaml
model: 450m
api_port: 8000
status_port: 80
webui_port: 8080
with_openwebui: false
with_status_page: true
context_size: auto    # or 2048, 4096, 8192, etc.
threads: auto         # or 2, 4, 8
parallel: auto        # or 1, 2, 4
```

`auto` values are picked from your hardware: CPU threads, RAM, GPU presence.
A box with 8GB RAM gets 8192-token context by default; 4GB gets 4096.

The config file is plain YAML-key-value (no external parser required). The
installer handles it without `yq` or any Python dependency at install time.

---

## Using the API

The installer exposes an OpenAI-compatible chat completions endpoint. Any
tool that speaks the OpenAI API can use it — just point at the local URL.

### curl

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "model.gguf",
    "messages": [{"role":"user","content":"What'\''s in this image?"}],
    "images": []
  }'
```

For images, use the OpenAI multimodal format:

```json
{
  "model": "model.gguf",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "text", "text": "Describe this image"},
      {"type": "image_url", "image_url": {"url": "https://example.com/photo.jpg"}}
    ]
  }]
}
```

Base64 data URLs work too:

```json
{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,<BASE64>"}}
```

### Python (OpenAI client)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="not-needed",
)

resp = client.chat.completions.create(
    model="model.gguf",
    messages=[{
        "role": "user",
        "content": [
            {"type": "text", "text": "Read the text in this image"},
            {"type": "image_url", "image_url": {"url": "https://example.com/receipt.jpg"}},
        ],
    }],
)
print(resp.choices[0].message.content)
```

### Other clients

Anything that points an OpenAI-compatible base URL at your server works:

- [Open WebUI](https://github.com/open-webui/open-webui) (install with `--with-openwebui`)
- [LobeChat](https://github.com/lobehub/lobe-chat)
- [LibreChat](https://github.com/danny-avila/LibreChat)
- [Page Assist](https://github.com/n4ze3m/page-assist) (browser extension)
- Home Assistant, n8n, LangChain, LlamaIndex, etc.

---

## Hardware auto-detection

The installer probes your machine and picks sensible defaults:

| Spec detected | Effect |
|---------------|--------|
| CPU thread count | `threads` and `parallel` for llama.cpp |
| Total RAM | `context_size` (8192 / 4096 / 2048 tokens) |
| NVIDIA GPU present | `-ngl 99` to offload the model to GPU |
| AMD GPU + rocm-smi | Detected (CPU path used unless ROCm build) |
| Architecture (x64 / arm64) | Selects the right prebuilt binary |

If autotune gets it wrong, override per-flag (`--threads`, `--context`,
etc.) or in `/etc/lfm-vision/config.yaml`.

### Minimum requirements

- **CPU:** any x86_64 or aarch64 Linux box
- **RAM:** 1.5GB free for the 450M model + overhead. 4GB recommended.
- **Disk:** ~2GB free (`/opt` for the binary, `/var/lib` for state)
- **OS:** Ubuntu 20.04+ or Debian 11+ tested. Other apt-based distros
  usually work but aren't part of CI.

GPU is optional. The 450M is small enough that a CPU-only box handles a
request per second or two, which is plenty for personal use.

---

## Operations

### Service management

```bash
# Status of the API
sudo systemctl status lfm-vision-api

# Live logs
sudo journalctl -u lfm-vision-api -f

# Restart after editing config
sudo systemctl restart lfm-vision-api

# Same for the other services
sudo systemctl status lfm-vision-status     # status page
sudo systemctl status lfm-vision-webui      # if you installed OpenWebUI
```

### Where things live

| Path | What's there |
|------|--------------|
| `/opt/lfm-vision/bin/`           | llama-server binary |
| `/opt/lfm-vision/status/`        | Status landing page (HTML, CSS, JS, Python server) |
| `/var/lib/lfm-vision/models/`    | `model.gguf`, `mmproj.gguf` |
| `/var/lib/lfm-vision/state.json` | Machine-readable install state (read by status page) |
| `/var/lib/lfm-vision/webui-venv/`| OpenWebUI Python venv (if installed) |
| `/etc/lfm-vision/config.yaml`    | Your config |
| `/var/log/lfm-vision/`           | `api.log`, `status.log`, `webui.log` |

### Update

```bash
curl -fsSL .../setandrunall.sh | bash -s -- --update
```

Re-fetches the latest llama.cpp release, restarts the API. The model
itself is only re-downloaded if you change `--model`.

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/ananyabhardwajjiit/lai450MVL2.5/main/uninstall.sh | bash
```

Stops services, removes the service units, deletes the install roots. Does
NOT remove the Hugging Face cache (`~/.cache/llama.cpp/`) or OpenWebUI
user data — those are yours to keep or delete.

---

## Troubleshooting

### "API did not respond in 90s"

Check the log: `sudo journalctl -u lfm-vision-api -n 100 --no-pager`.
Common causes:

- **Out of memory** — the OS killed the process. Check `dmesg | grep -i
  oom`. Reduce `--context` and `--parallel`.
- **Wrong arch binary** — re-run with `--dry-run` to see what would be
  downloaded. An arm64 box needs the arm64 build.
- **Corrupted model download** — `sudo rm /var/lib/lfm-vision/models/*.gguf`
  and re-run the installer.

### "Status page did not respond at :80"

Port 80 requires root. The installer runs as root or with sudo, so the
service should bind. If something else is on port 80, change it:

```bash
./setandrunall.sh --status-port 8081
```

### "GitHub API unreachable; falling back to b8152"

The installer couldn't reach `api.github.com` to find the latest llama.cpp
release. It falls back to a known-good version. This is fine — the install
will still work. The next `--update` run will pick up the real latest.

### I want to use a different model

Edit `/etc/lfm-vision/config.yaml`, change `model:` to whatever's in the
catalog (currently just `450m`), and re-run the installer. New models will
be added to the catalog in `lib/common.sh` as Liquid AI releases them.

### 403 / rate limit from Hugging Face

HF gates large downloads behind an HF token for some IPs. If you see this,
set `HF_TOKEN` in the environment and re-run.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Your server                       │
│                                                       │
│   ┌──────────────────┐    ┌──────────────────────┐  │
│   │  :80 status page │◄───┤ Python stdlib server │  │
│   │  (HTML+JS)       │    │ (server.py)          │  │
│   └──────────────────┘    │  polls /health,      │  │
│                           │  /v1/models,         │  │
│                           │  /metrics            │  │
│   ┌──────────────────┐    └─────────┬────────────┘  │
│   │  :8000 API       │◄─────────────┘              │
│   │  (llama-server)  │                              │
│   │  LFM2.5-VL 450M  │                              │
│   └────────┬─────────┘                              │
│            │                                         │
│   ┌────────▼─────────┐  (optional)                  │
│   │  :8080 OpenWebUI │                              │
│   │  (chat UI)       │                              │
│   └──────────────────┘                              │
│                                                       │
│   All three are systemd services.                    │
│   No tmux. No /home/ubuntu. No hand-holding.         │
└─────────────────────────────────────────────────────┘
```

The status server is a single Python file using only the standard library
(`http.server`, `urllib`, `json`). No `pip install`. It reads llama.cpp's
`/metrics` endpoint and serves a minimal JSON API to the HTML page.

---

## Repository layout

```
lai450MVL2.5/
├── setandrunall.sh         main installer (start here)
├── setandrunall2.sh        minimal installer (API only)
├── setandrun2.sh           build from source installer
├── setandrun3.sh           project custom-binary installer
├── uninstall.sh            clean removal
├── lib/
│   ├── common.sh           hardware detection, config, paths, systemd
│   └── install.sh          shared install pipeline
├── status-page/
│   ├── index.html          landing page
│   ├── style.css
│   ├── app.js
│   └── server.py           stdlib-only status server
├── config.example.yaml     config file template
├── docs/                   (more docs as they get written)
└── test.jpg                sample image for the smoke test
```

---

## License

MIT. See `LICENSE`.

## Credits

- [Liquid AI](https://liquid.ai/) for the LFM2.5-VL 450M model
- [Georgi Gerganov and the llama.cpp contributors](https://github.com/ggml-org/llama.cpp) for the inference engine
- [Open WebUI](https://github.com/open-webui/open-webui) for the chat UI
