#!/usr/bin/env bash

set -Eeuo pipefail

MODEL_URL="https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/LFM2.5-VL-450M-F16.gguf"
MMPROJ_URL="https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/mmproj-LFM2.5-VL-450m-F16.gguf"

MODEL_DIR="/opt/lfm2"
LLAMA_DIR="/opt/llama.cpp"
SERVICE_NAME="lfm2-ocr"

echo "=== Installing dependencies ==="

sudo apt update

sudo apt install -y \
    curl \
    wget \
    git \
    build-essential \
    cmake \
    pkg-config \
    libcurl4-openssl-dev

echo "=== Detecting CPU ==="

THREADS=$(nproc)

# Tuned for c3-standard-4
if [ "$THREADS" -ge 4 ]; then
    LLAMA_THREADS=3
    LLAMA_PARALLEL=2
else
    LLAMA_THREADS=2
    LLAMA_PARALLEL=1
fi

echo "CPU threads: $THREADS"
echo "Using llama threads: $LLAMA_THREADS"
echo "Using parallel slots: $LLAMA_PARALLEL"

echo "=== Installing llama.cpp ==="

if [ ! -d "$LLAMA_DIR" ]; then
    sudo git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
fi

cd "$LLAMA_DIR"

sudo git fetch --tags
sudo git checkout b8152

echo "=== Building llama.cpp ==="

sudo cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON

sudo cmake --build build -j"$(nproc)"

echo "=== Downloading model ==="

sudo mkdir -p "$MODEL_DIR"

cd "$MODEL_DIR"

if [ ! -f model.gguf ]; then
    sudo wget -O model.gguf "$MODEL_URL"
fi

if [ ! -f mmproj.gguf ]; then
    sudo wget -O mmproj.gguf "$MMPROJ_URL"
fi

echo "=== Creating systemd service ==="

sudo tee /etc/systemd/system/${SERVICE_NAME}.service >/dev/null <<EOF
[Unit]
Description=LFM2 OCR API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${LLAMA_DIR}

ExecStart=${LLAMA_DIR}/build/bin/llama-server \
  -m ${MODEL_DIR}/model.gguf \
  --mmproj ${MODEL_DIR}/mmproj.gguf \
  --host 0.0.0.0 \
  --port 8000 \
  -c 2048 \
  -t ${LLAMA_THREADS} \
  -tb ${LLAMA_THREADS} \
  -np ${LLAMA_PARALLEL} \
  -b 1024 \
  -ub 512 \
  --metrics \
  --no-context-shift \
  -fa

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "=== Reloading systemd ==="

sudo systemctl daemon-reload

echo "=== Enabling service ==="

sudo systemctl enable ${SERVICE_NAME}

echo "=== Restarting service ==="

sudo systemctl restart ${SERVICE_NAME}

echo "=== Waiting for startup ==="

sleep 10

echo "=== Health Check ==="

curl http://127.0.0.1:8000/health || true

echo
echo "=== Metrics Check ==="

curl http://127.0.0.1:8000/metrics | head || true

echo
echo "=== DONE ==="

echo "API:"
echo "http://SERVER_IP:8000/v1/chat/completions"

echo
echo "Metrics:"
echo "http://SERVER_IP:8000/metrics"

echo
echo "Logs:"
echo "sudo journalctl -u ${SERVICE_NAME} -f"
