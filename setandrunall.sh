#!/bin/bash

set -e

echo "=== STEP 1: System update & install ==="
sudo apt update
sudo apt install -y python3 python3-pip python3-venv tmux curl wget git

# -------------------------------
# STEP 2: Install llama.cpp binary
# -------------------------------
echo "=== STEP 2: Installing llama.cpp ==="

cd ~

if [ ! -d "llama-b8152" ]; then
  wget https://github.com/ggerganov/llama.cpp/releases/download/b8152/llama-b8152-bin-ubuntu-x64.tar.gz
  tar -xvf llama-b8152-bin-ubuntu-x64.tar.gz
fi

# Verify binary exists
if [ ! -f "/home/ubuntu/llama-b8152/llama-server" ]; then
  echo "❌ llama-server binary missing"
  exit 1
fi

chmod +x /home/ubuntu/llama-b8152/llama-server

# -------------------------------
# STEP 3: Download model (robust)
# -------------------------------
echo "=== STEP 3: Downloading model ==="

mkdir -p ~/.cache/llama.cpp
cd ~/.cache/llama.cpp

download_file () {
  URL=$1
  OUT=$2

  if [ -f "$OUT" ]; then
    echo "✔ $OUT already exists, skipping"
  else
    echo "⬇ Downloading $OUT ..."
    wget -L --continue \
      --retry-connrefused \
      --waitretry=2 \
      --read-timeout=20 \
      --timeout=15 \
      -t 0 \
      -O "$OUT" "$URL"
  fi
}

download_file \
"https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/LFM2.5-VL-450M-F16.gguf" \
model.gguf

download_file \
"https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/mmproj-LFM2.5-VL-450m-F16.gguf" \
mmproj.gguf

# Basic size check (avoid broken downloads)
if [ ! -s "model.gguf" ] || [ ! -s "mmproj.gguf" ]; then
  echo "❌ Model download failed or incomplete"
  exit 1
fi

# -------------------------------
# STEP 4: Setup OpenWebUI
# -------------------------------

echo "=== STEP 4: Installing OpenWebUI ==="

cd ~

# Install Python 3.11 (required)
sudo apt install -y software-properties-common
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt update
sudo apt install -y python3.11 python3.11-venv python3.11-distutils

# Always recreate environment (prevents broken reuse)
rm -rf ~/openwebui-env

# Create venv with Python 3.11
python3.11 -m venv ~/openwebui-env
source ~/openwebui-env/bin/activate

# Upgrade pip and install OpenWebUI
pip install --upgrade pip
pip install open-webui

# Verify installation (fail fast if broken)
if ! command -v open-webui >/dev/null 2>&1; then
  echo "❌ OpenWebUI installation failed"
  exit 1
fi

deactivate


# -------------------------------
# STEP 5: Start everything using tmux
# -------------------------------
echo "=== STEP 5: Starting services ==="

tmux kill-session -t llama 2>/dev/null || true
tmux kill-session -t openwebui 2>/dev/null || true

# Start llama server
tmux new -d -s llama "/home/ubuntu/llama-b8152/llama-server \
  -m /home/ubuntu/.cache/llama.cpp/model.gguf \
  --mmproj /home/ubuntu/.cache/llama.cpp/mmproj.gguf \
  --host 0.0.0.0 --port 8000 -c 8192"

echo "Waiting for llama to initialize..."
sleep 10

# Start OpenWebUI
tmux new -d -s openwebui "source /home/ubuntu/openwebui-env/bin/activate && open-webui serve --host 0.0.0.0 --port 8080"

echo "Waiting for OpenWebUI..."
sleep 10

# -------------------------------
# STEP 6: Status check
# -------------------------------
echo ""
echo "=== STATUS ==="

echo "--- TMUX ---"
tmux ls || true

echo ""
echo "--- PORTS ---"
ss -tulnp | grep -E "8000|8080" || true

echo ""
echo "--- TEST API ---"
curl -s http://127.0.0.1:8000/v1/models || echo "❌ API not responding"

echo ""
echo "=== DONE ==="
echo "OpenWebUI: http://<YOUR_VM_IP>:8080"
echo "API: http://<YOUR_VM_IP>:8000/v1"
