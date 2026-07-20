#!/usr/bin/env bash
# stemplay v2 - 설치 확인 + 백그라운드 실행 스크립트
#
# 사용법:
#   ./run.sh            # 서버 + 워커 모두 실행 (로컬 개발 / 단일 PC)
#   ./run.sh server     # 서버만 실행 (EC2: 웹 서빙 + 작업 큐 + 저장소)
#   ./run.sh worker     # 워커만 실행 (홈 PC: 유튜브 다운로드 + Demucs 분리)
#
# 실행할 때마다 해당 역할의 기존 프로세스를 자동 종료하고 새로 시작하므로
# 재시작 용도로도 그냥 다시 실행하면 된다. 여러 번 실행해도 안전하다.
#
# 환경변수 (.env 파일에 적어두면 자동 로드된다 — .env.example 참고):
#   WORKER_TOKEN  서버-워커 공유 시크릿 (기본값 dev — 로컬 개발용. EC2 운영 시 반드시 변경)
#   EC2_URL       워커가 바라볼 서버 주소 (기본값 http://localhost:5000)
#   PORT          서버 포트 (기본값 5000)
#   BIND          gunicorn 바인드 주소 (기본값 0.0.0.0 — nginx 뒤에서는 127.0.0.1 권장)
#   WEB_PASSWORD  웹 UI 비밀번호 (비우면 인증 없음 — 로컬 개발용. EC2 운영 시 반드시 설정)
#   SECRET_KEY    세션 쿠키 서명 키 (openssl rand -hex 32 로 생성)
#   NGINX_ACCEL   1이면 오디오 서빙을 nginx에 위임 (setup-nginx.sh 적용 시)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
ROLE="${1:-all}"

# .env 파일이 있으면 읽어서 환경변수로 등록한다 (export로 이미 설정된 값이 우선).
# WORKER_TOKEN 같은 시크릿은 깃에 올리지 말고 .env에 보관할 것 (.gitignore 등록됨).
if [ -f "$SCRIPT_DIR/.env" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        key="${line%%=*}"
        val="${line#*=}"
        val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
        [ -n "${!key:-}" ] || export "$key=$val"
    done < "$SCRIPT_DIR/.env"
fi

PORT="${PORT:-5000}"
BIND="${BIND:-0.0.0.0}"
WORKER_TOKEN="${WORKER_TOKEN:-dev}"
EC2_URL="${EC2_URL:-http://localhost:$PORT}"

case "$ROLE" in all|server|worker) ;; *)
    echo "사용법: ./run.sh [server|worker]  (인자 없으면 둘 다 실행)"; exit 1 ;;
esac

info() { echo -e "\n\033[1;34m==>\033[0m $*"; }

cd "$SCRIPT_DIR"

# ── 1. 시스템 패키지 ─────────────────────────────────────────────────
# 서버는 파이썬만 있으면 되고, 워커는 ffmpeg(악기 감지)과
# node(yt-dlp의 유튜브 추출용 JS 런타임)가 추가로 필요하다.
NEED_PKGS=()
command -v curl >/dev/null || NEED_PKGS+=(curl)
dpkg -s python3-venv >/dev/null 2>&1 || NEED_PKGS+=(python3-venv)
if [ "$ROLE" != "server" ]; then
    command -v ffmpeg >/dev/null || NEED_PKGS+=(ffmpeg)
    command -v node   >/dev/null || NEED_PKGS+=(nodejs)
fi

if [ ${#NEED_PKGS[@]} -gt 0 ]; then
    info "시스템 패키지 설치: ${NEED_PKGS[*]} (sudo 비밀번호가 필요할 수 있음)"
    sudo apt-get update
    sudo apt-get install -y "${NEED_PKGS[@]}"
else
    info "시스템 패키지 확인 완료"
fi

if [ "$ROLE" != "server" ] && command -v node >/dev/null; then
    NODE_MAJOR="$(node --version | sed 's/^v\([0-9]*\).*/\1/')"
    if [ "$NODE_MAJOR" -lt 20 ]; then
        echo "⚠️  node v$NODE_MAJOR 감지 — yt-dlp는 node 20 이상을 권장합니다." \
             "다운로드가 계속 실패하면 node를 업그레이드하세요."
    fi
fi

# ── 2. 파이썬 가상환경 + 의존성 ──────────────────────────────────────
if [ ! -f "$VENV_DIR/bin/activate" ]; then
    info "가상환경 생성: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

if [ "$ROLE" = "server" ]; then
    # EC2 서버는 torch/demucs/yt-dlp가 전부 불필요 → flask만 설치
    python -c "import flask, gunicorn" 2>/dev/null || {
        info "파이썬 패키지 설치 (flask, gunicorn)"
        pip install --quiet --upgrade pip
        pip install --quiet flask gunicorn
    }
else
    python -c "import flask, gunicorn, demucs, yt_dlp, requests" 2>/dev/null || {
        info "파이썬 패키지 설치 (demucs 포함 — 최초 설치 시 수 분 소요)"
        pip install --quiet --upgrade pip
        # GPU(NVIDIA)가 없으면 CPU 전용 torch를 먼저 설치해
        # 불필요한 CUDA 패키지 다운로드(~2GB)를 피한다.
        if ! command -v nvidia-smi >/dev/null 2>&1; then
            info "NVIDIA GPU 미감지 → CPU 전용 torch 설치 (용량 절약)"
            pip install --quiet torch torchaudio --index-url https://download.pytorch.org/whl/cpu
        fi
        pip install --quiet -r requirements.txt
    }
fi
info "설치 확인 완료"

# ── 3. 기존 프로세스 종료 ────────────────────────────────────────────
info "기존 프로세스 종료"
if [ "$ROLE" != "worker" ]; then
    pkill -f "gunicorn.*server:app"      2>/dev/null && echo "  기존 서버(gunicorn) 종료" || true
    pkill -f "python3? .*server\.py"     2>/dev/null && echo "  기존 서버(flask) 종료"    || true
    fuser -k -TERM "$PORT/tcp"           >/dev/null 2>&1 || true
fi
if [ "$ROLE" != "server" ]; then
    pkill -f "python3? .*worker\.py"     2>/dev/null && echo "  기존 워커 종료" || true
fi
sleep 1     # 포트가 완전히 해제될 때까지 잠깐 대기

# ── 4. 백그라운드 실행 ───────────────────────────────────────────────
if [ "$ROLE" != "worker" ]; then
    if [ "$WORKER_TOKEN" = "dev" ]; then
        echo "⚠️  WORKER_TOKEN이 기본값(dev)입니다 — 로컬 개발용. EC2에서는 반드시 바꿔서 실행하세요."
    fi
    if [ -z "${WEB_PASSWORD:-}" ]; then
        echo "⚠️  WEB_PASSWORD가 비어 있어 웹 인증 없이 실행됩니다 — 로컬 개발용. EC2에서는 반드시 설정하세요."
    fi
    info "서버 시작 (백그라운드) → http://localhost:$PORT"
    WORKER_TOKEN="$WORKER_TOKEN" nohup "$VENV_DIR/bin/gunicorn" \
        -b "$BIND:$PORT" --threads 4 server:app \
        > "$SCRIPT_DIR/server.log" 2>&1 &
    SERVER_PID=$!

    # 서버가 정상적으로 떴는지 확인 (최대 10초 대기)
    for _ in $(seq 1 10); do
        sleep 1
        if curl -s -o /dev/null "http://localhost:$PORT/songs"; then break; fi
        if [ "$_" = 10 ]; then
            echo "❌ 서버가 10초 안에 응답하지 않습니다. 로그를 확인하세요:"
            tail -20 "$SCRIPT_DIR/server.log"; exit 1
        fi
    done
    echo "✅ 서버 실행 중 (PID $SERVER_PID) — 로그: tail -f server.log"
fi

if [ "$ROLE" != "server" ]; then
    info "워커 시작 (백그라운드) → 서버: $EC2_URL"
    EC2_URL="$EC2_URL" WORKER_TOKEN="$WORKER_TOKEN" nohup \
        "$VENV_DIR/bin/python" worker.py \
        > "$SCRIPT_DIR/worker.log" 2>&1 &
    WORKER_PID=$!

    sleep 2
    if ! kill -0 "$WORKER_PID" 2>/dev/null; then
        echo "❌ 워커가 시작 직후 종료됐습니다. 로그를 확인하세요:"
        tail -20 "$SCRIPT_DIR/worker.log"; exit 1
    fi
    echo "✅ 워커 실행 중 (PID $WORKER_PID) — 로그: tail -f worker.log"
fi

echo
echo "종료 방법:"
[ "$ROLE" != "worker" ] && echo "  서버: pkill -f 'gunicorn.*server:app'"
[ "$ROLE" != "server" ] && echo "  워커: pkill -f 'python3? .*worker\\.py'"
exit 0
