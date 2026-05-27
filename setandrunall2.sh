#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_URL="https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/LFM2.5-VL-450M-F16.gguf"
MMPROJ_URL="https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/mmproj-LFM2.5-VL-450m-F16.gguf"
LLAMA_RELEASE="b8152"
LLAMA_URL="https://github.com/ggerganov/llama.cpp/releases/download/${LLAMA_RELEASE}/llama-${LLAMA_RELEASE}-bin-ubuntu-x64.tar.gz"
LLAMA_DIR="/opt/llama.cpp"
MODEL_DIR="/opt/lfm2"
SERVICE_NAME="lfm2-ocr"

echo "=== Installing dependencies ==="
sudo apt-get update -qq
sudo apt-get install -y curl wget tar

echo "=== Downloading llama.cpp prebuilt binary (${LLAMA_RELEASE}) ==="
sudo rm -rf "$LLAMA_DIR"
sudo mkdir -p "$LLAMA_DIR"
sudo chown "$(id -u):$(id -g)" "$LLAMA_DIR"
cd "$LLAMA_DIR"
wget -q --show-progress -O llama.tar.gz "$LLAMA_URL"
tar -xzf llama.tar.gz
rm llama.tar.gz

LLAMA_BIN="${LLAMA_DIR}/llama-b8152/llama-server"
chmod +x "$LLAMA_BIN"
echo "Binary OK: $LLAMA_BIN"

echo "=== Downloading model ==="
sudo mkdir -p "$MODEL_DIR"
cd "$MODEL_DIR"
if [ ! -f model.gguf ]; then
    sudo wget -q --show-progress -O model.gguf "$MODEL_URL"
fi
if [ ! -f mmproj.gguf ]; then
    sudo wget -q --show-progress -O mmproj.gguf "$MMPROJ_URL"
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
  -c 8192
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
    echo "WARNING: Service did not respond in 90s."
    echo "  sudo journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
fi

echo "=== DONE ==="
echo "API:  http://$(curl -s ifconfig.me):8000/v1/chat/completions"
echo "Logs: sudo journalctl -u ${SERVICE_NAME} -f"
