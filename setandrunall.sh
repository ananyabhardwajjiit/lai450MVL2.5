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
  wget https://huggingface.co/ggml-org/llama.cpp/resolve/main/llama-b8152-bin-ubuntu-x64.tar.gz
  tar -xvf llama-b8152-bin-ubuntu-x64.tar.gz
fi

# -------------------------------
# STEP 3: Download model
# -------------------------------
echo "=== STEP 3: Downloading model ==="

mkdir -p ~/.cache/llama.cpp
cd ~/.cache/llama.cpp

if [ ! -f "model.gguf" ]; then
  wget -O model.gguf "https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/LFM2.5-VL-450M-F16.gguf"
fi

if [ ! -f "mmproj.gguf" ]; then
  wget -O mmproj.gguf "https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/mmproj-LFM2.5-VL-450m-F16.gguf"
fi

# -------------------------------
# STEP 4: Setup OpenWebUI
# -------------------------------
echo "=== STEP 4: Installing OpenWebUI ==="

cd ~

if [ ! -d "openwebui-env" ]; then
  python3 -m venv openwebui-env
  source openwebui-env/bin/activate
  pip install --upgrade pip
  pip install open-webui
  deactivate
fi

# -------------------------------
# STEP 5: Start everything using tmux
# -------------------------------
echo "=== STEP 5: Starting services ==="

tmux kill-session -t llama 2>/dev/null
tmux kill-session -t openwebui 2>/dev/null

# Start llama server
tmux new -d -s llama "/home/ubuntu/llama-b8152/llama-server \
  -m /home/ubuntu/.cache/llama.cpp/model.gguf \
  --mmproj /home/ubuntu/.cache/llama.cpp/mmproj.gguf \
  --host 0.0.0.0 --port 8000 -c 8192"

echo "Waiting for llama to initialize..."
sleep 8

# Start OpenWebUI
tmux new -d -s openwebui "source /home/ubuntu/openwebui-env/bin/activate && open-webui serve --host 0.0.0.0 --port 8080"

echo "Waiting for OpenWebUI..."
sleep 8

# -------------------------------
# STEP 6: Status check
# -------------------------------
echo ""
echo "=== STATUS ==="

echo "--- TMUX ---"
tmux ls

echo ""
echo "--- PORTS ---"
ss -tulnp | grep -E "8000|8080"

echo ""
echo "=== DONE ==="
echo "OpenWebUI: http://<YOUR_VM_IP>:8080"
echo "API: http://<YOUR_VM_IP>:8000/v1"
