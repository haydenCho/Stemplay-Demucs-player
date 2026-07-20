#!/usr/bin/env bash
# 백엔드 배포 스크립트 — Flask API 서버(gunicorn)를 systemd 서비스로 실행
#
# 사용법:
#   ./deploy-backend.sh
#   (보통은 통합 스크립트 ./deploy.sh 로 프론트엔드와 함께 배포한다)
#
# 하는 일:
#   - 저사양 인스턴스(t2.micro 등)에서 Demucs OOM 방지용 스왑 생성
#   - setup.sh --setup-only 로 시스템 패키지 / venv / 파이썬 의존성 설치
#   - gunicorn 설치 후 systemd 서비스(stemplay)로 등록 → 재부팅에도 자동 시작
#   - debug=True인 개발 서버(python server.py) 대신 gunicorn으로 구동
#
# gunicorn은 127.0.0.1:5000에만 바인딩한다. 외부 접근은 nginx(deploy-frontend.sh)를
# 통해서만 하며, 보안 그룹에 5000 포트를 열 필요가 없다.
#
# 여러 번 실행해도 안전하다 (재배포 = git pull 후 재실행).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
SERVICE_NAME="stemplay"
PORT=5000
SWAP_FILE="/swapfile"
SWAP_SIZE_GB=4

info() { echo -e "\n\033[1;34m==>\033[0m $*"; }

cd "$SCRIPT_DIR"

# ── 1. 스왑 생성 (RAM 4GB 미만 + 스왑 없음일 때만) ───────────────────
# Demucs가 곡 하나 분리하는 데 수 GB를 쓰므로 t2.micro(1GB) 같은
# 저사양 인스턴스에서는 스왑 없이는 OOM으로 죽는다.
RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
SWAP_KB=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
if [ "$RAM_KB" -lt 4000000 ] && [ "$SWAP_KB" -eq 0 ]; then
    AVAIL_GB=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
    if [ "$AVAIL_GB" -gt $((SWAP_SIZE_GB + 2)) ]; then
        info "RAM ${RAM_KB}kB로 부족 → ${SWAP_SIZE_GB}GB 스왑 생성 (Demucs OOM 방지)"
        sudo fallocate -l "${SWAP_SIZE_GB}G" "$SWAP_FILE"
        sudo chmod 600 "$SWAP_FILE"
        sudo mkswap "$SWAP_FILE"
        sudo swapon "$SWAP_FILE"
        # 재부팅 후에도 유지
        grep -q "^$SWAP_FILE" /etc/fstab || \
            echo "$SWAP_FILE none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
    else
        info "⚠️ 디스크 여유(${AVAIL_GB}GB)가 부족해 스왑 생성을 건너뜁니다. Demucs 실행 시 OOM이 날 수 있습니다."
    fi
else
    info "메모리 확인 완료 (스왑 생성 불필요)"
fi

# ── 2. 설치 (setup.sh 재사용: ffmpeg, venv, 파이썬 의존성) ───────────
info "setup.sh --setup-only 실행"
./setup.sh --setup-only

# ── 3. gunicorn 설치 ─────────────────────────────────────────────────
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
info "gunicorn 설치"
pip install --quiet gunicorn

# ── 4. systemd 서비스 등록 ───────────────────────────────────────────
# 워커 1개(Demucs가 메모리를 많이 쓰므로) + 스레드 8개(분리 작업 중에도
# API 응답이 막히지 않도록). timeout은 분리 작업이 길어 넉넉히 600초.
info "systemd 서비스 등록: $SERVICE_NAME"
sudo tee "/etc/systemd/system/$SERVICE_NAME.service" >/dev/null <<EOF
[Unit]
Description=stemplay - band stem mixer backend
After=network.target

[Service]
User=$USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=$VENV_DIR/bin/gunicorn -w 1 --threads 8 -b 127.0.0.1:$PORT --timeout 600 server:app
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 개발 서버(python server.py)가 떠 있었다면 포트 충돌 방지를 위해 종료
pkill -f "python3? .*server\.py" 2>/dev/null || true

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

# ── 5. 기동 확인 (최대 15초 대기) ────────────────────────────────────
info "백엔드 기동 확인"
for _ in $(seq 1 15); do
    sleep 1
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then
        echo
        echo "✅ 백엔드 실행 중 (127.0.0.1:$PORT, systemd 서비스: $SERVICE_NAME)"
        echo "  상태 확인: sudo systemctl status $SERVICE_NAME"
        echo "  로그 확인: journalctl -u $SERVICE_NAME -f"
        echo "  재시작:    sudo systemctl restart $SERVICE_NAME"
        exit 0
    fi
done

echo
echo "❌ 백엔드가 15초 안에 응답하지 않습니다. 로그를 확인하세요:"
journalctl -u "$SERVICE_NAME" -n 30 --no-pager
exit 1
