#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_URL="https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/LFM2.5-VL-450M-F16.gguf"
MMPROJ_URL="https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/mmproj-LFM2.5-VL-450m-F16.gguf"
BINARY_URL="https://github.com/ananyabhardwajjiit/lai450MVL2.5/releases/download/v1.0/llama-server-bin.tar.gz"
MODEL_DIR="/opt/lfm2"
LLAMA_DIR="/opt/llama.cpp"
SERVICE_NAME="lfm2-ocr"

echo "=== Installing dependencies ==="
sudo apt-get update -qq
sudo apt-get install -y curl wget libgomp1

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
echo "CPU threads: $THREADS | llama: $LLAMA_THREADS | batch: $LLAMA_BATCH_THREADS | parallel: $LLAMA_PARALLEL"

echo "=== Downloading llama-server binaries ==="
sudo rm -rf "$LLAMA_DIR"
sudo mkdir -p "$LLAMA_DIR"
sudo chown "$(id -u):$(id -g)" "$LLAMA_DIR"
cd "$LLAMA_DIR"
wget -q --show-progress -O bin.tar.gz "$BINARY_URL"
tar -xzf bin.tar.gz
rm bin.tar.gz
LLAMA_BIN="${LLAMA_DIR}/bin/llama-server"
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
WorkingDirectory=${LLAMA_DIR}/bin
Environment=LD_LIBRARY_PATH=${LLAMA_DIR}/bin
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
  -fa auto
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "=== Starting service ==="
sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_NAME}
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

echo "=== DONE ==="
echo "API:     http://$(curl -s ifconfig.me):8000/v1/chat/completions"
echo "Metrics: http://$(curl -s ifconfig.me):8000/metrics"
echo "Logs:    sudo journalctl -u ${SERVICE_NAME} -f"
