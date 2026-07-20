#!/usr/bin/env bash
# 밴드 음원 분리 플레이어 - EC2 배포 스크립트 (Ubuntu 기준)
#
# 사용법 (EC2 인스턴스 안에서 실행):
#   1. 깃허브에서 클론:
#        git clone https://github.com/<계정>/Stemplay-Demucs-player.git
#   2. 배포:
#        cd ~/Stemplay-Demucs-player && ./deploy.sh
#
#   (선택) PC에서 미리 분리해 둔 곡 캐시를 가져가면 EC2에서 분리를 건너뛴다:
#        rsync -av ~/Music/band-mixer/separated/ ubuntu@<EC2-IP>:~/Stemplay-Demucs-player/separated/
#
# 하는 일:
#   - 저사양 인스턴스(t2.micro 등)에서 Demucs OOM 방지용 스왑 생성
#   - setup.sh --setup-only 로 시스템 패키지 / venv / 파이썬 의존성 설치
#   - gunicorn 설치 후 systemd 서비스(stemplay)로 등록 → 재부팅에도 자동 시작
#   - debug=True인 개발 서버(python server.py) 대신 gunicorn으로 구동
#
# 여러 번 실행해도 안전하다 (재배포 = git pull 후 ./deploy.sh 재실행).
#
# 외부 접근은 nginx 리버스 프록시(HTTPS)를 통해서만 한다:
#   - gunicorn은 127.0.0.1:5000에만 바인딩 → 외부에서 직접 접근 불가
#   - 보안 그룹에는 5000 포트를 열 필요 없음 (80/443/22만 있으면 됨)
#   - nginx 쪽 location 설정은 프로젝트 README의 배포 섹션 참고
#     (proxy_read_timeout 600s 필수 — 분리 작업이 수 분 걸림)

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
# 오디오 서빙이 막히지 않도록). timeout은 분리 작업이 길어 넉넉히 600초.
info "systemd 서비스 등록: $SERVICE_NAME"
sudo tee "/etc/systemd/system/$SERVICE_NAME.service" >/dev/null <<EOF
[Unit]
Description=stemplay - band stem mixer
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
info "서버 기동 확인"
for _ in $(seq 1 15); do
    sleep 1
    if curl -s -o /dev/null "http://localhost:$PORT/"; then
        echo
        echo "✅ 배포 완료! 서비스가 127.0.0.1:$PORT 에서 실행 중입니다."
        echo "  nginx 프록시 설정 후 https://<도메인> 으로 접속하세요."
        echo "  상태 확인: sudo systemctl status $SERVICE_NAME"
        echo "  로그 확인: journalctl -u $SERVICE_NAME -f"
        echo "  재시작:    sudo systemctl restart $SERVICE_NAME"
        echo "  중지:      sudo systemctl stop $SERVICE_NAME"
        exit 0
    fi
done

echo
echo "❌ 서버가 15초 안에 응답하지 않습니다. 로그를 확인하세요:"
journalctl -u "$SERVICE_NAME" -n 30 --no-pager
exit 1
