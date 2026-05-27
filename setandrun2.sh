#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_URL="https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/LFM2.5-VL-450M-F16.gguf"
MMPROJ_URL="https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/mmproj-LFM2.5-VL-450m-F16.gguf"
MODEL_DIR="/opt/lfm2"
LLAMA_DIR="/opt/llama.cpp"
SERVICE_NAME="lfm2-ocr"

echo "=== Installing dependencies ==="
sudo apt-get update
sudo apt-get install -y \
    curl \
    wget \
    git \
    build-essential \
    cmake \
    pkg-config \
    libcurl4-openssl-dev

echo "=== Detecting CPU ==="
THREADS=$(nproc)
if [ "$THREADS" -ge 4 ]; then
    LLAMA_THREADS=3
    LLAMA_PARALLEL=2
    LLAMA_BATCH_THREADS=4
else
    LLAMA_THREADS=2
    LLAMA_PARALLEL=1
    LLAMA_BATCH_THREADS=2
fi
echo "CPU threads: $THREADS"
echo "Using llama threads: $LLAMA_THREADS"
echo "Using batch threads: $LLAMA_BATCH_THREADS"
echo "Using parallel slots: $LLAMA_PARALLEL"

echo "=== Cloning llama.cpp (official ggml-org) ==="
# Wipe any partial/stale clone so re-runs always start fresh
sudo rm -rf "$LLAMA_DIR"
sudo git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"

# Fix ownership so current user can run git/cmake without sudo and without safe.directory issues
sudo chown -R "$(id -u):$(id -g)" "$LLAMA_DIR"

cd "$LLAMA_DIR"
git fetch --tags

LATEST_TAG=$(git tag | grep -E '^b[0-9]{4,}$' | sort -t b -k2 -n | tail -1)
echo "=== Checking out latest tag: $LATEST_TAG ==="
git checkout "$LATEST_TAG"
echo "Building at: $(git describe --tags)"

echo "=== Building llama.cpp ==="
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON
cmake --build build -j"$(nproc)"

LLAMA_BIN="${LLAMA_DIR}/build/bin/llama-server"
if [ ! -f "$LLAMA_BIN" ]; then
    echo "ERROR: llama-server binary not found at $LLAMA_BIN — build failed."
    exit 1
fi
echo "Binary OK: $LLAMA_BIN"

echo "=== Downloading model ==="
sudo mkdir -p "$MODEL_DIR"
cd "$MODEL_DIR"
if [ ! -f model.gguf ]; then
    sudo wget --show-progress -O model.gguf "$MODEL_URL"
fi
if [ ! -f mmproj.gguf ]; then
    sudo wget --show-progress -O mmproj.gguf "$MMPROJ_URL"
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
ExecStart=${LLAMA_BIN} \
  -m ${MODEL_DIR}/model.gguf \
  --mmproj ${MODEL_DIR}/mmproj.gguf \
  --host 0.0.0.0 \
  --port 8000 \
  -c 2048 \
  -t ${LLAMA_THREADS} \
  -tb ${LLAMA_BATCH_THREADS} \
  -np ${LLAMA_PARALLEL} \
  -b 1024 \
  -ub 512 \
  --metrics \
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

echo "=== Starting service ==="
sudo systemctl restart ${SERVICE_NAME}

echo "=== Waiting for startup (polling up to 90s) ==="
STARTED=0
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:8000/health >/dev/null 2>&1; then
        echo "Service is up after ~$((i * 3))s"
        STARTED=1
        break
    fi
    echo "  waiting... ($((i * 3))s)"
    sleep 3
done

if [ "$STARTED" -eq 0 ]; then
    echo "WARNING: Service did not respond in 90s. Check logs:"
    echo "  sudo journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
fi

echo "=== Health Check ==="
curl -s http://127.0.0.1:8000/health || true
echo

echo "=== Metrics Check ==="
curl -s http://127.0.0.1:8000/metrics | head || true
echo

echo "=== DONE ==="
echo "API:     http://SERVER_IP:8000/v1/chat/completions"
echo "Metrics: http://SERVER_IP:8000/metrics"
echo "Logs:    sudo journalctl -u ${SERVICE_NAME} -f"
