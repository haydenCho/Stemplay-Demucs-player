#!/usr/bin/env bash
# 밴드 음원 분리 플레이어 - 원클릭 설치 스크립트
#
# 사용법:
#   ./setup.sh                # 설치 후 서버를 백그라운드로 실행 (기존 서버는 자동 종료)
#   ./setup.sh --setup-only   # 설치만 수행 (서버 실행 안 함)
#
# 여러 번 실행해도 안전하다 (이미 설치된 항목은 건너뜀).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

info() { echo -e "\n\033[1;34m==>\033[0m $*"; }

cd "$SCRIPT_DIR"

# ── 1. 시스템 패키지 (ffmpeg, python3-venv) ──────────────────────────
NEED_PKGS=()
command -v ffmpeg  >/dev/null || NEED_PKGS+=(ffmpeg)
command -v curl    >/dev/null || NEED_PKGS+=(curl)
dpkg -s python3-venv >/dev/null 2>&1 || NEED_PKGS+=(python3-venv)

if [ ${#NEED_PKGS[@]} -gt 0 ]; then
    info "시스템 패키지 설치: ${NEED_PKGS[*]} (sudo 비밀번호가 필요할 수 있음)"
    sudo apt-get update
    sudo apt-get install -y "${NEED_PKGS[@]}"
else
    info "시스템 패키지 확인 완료 (ffmpeg, python3-venv 이미 설치됨)"
fi

# ── 2. 파이썬 가상환경 ───────────────────────────────────────────────
if [ ! -f "$VENV_DIR/bin/activate" ]; then
    info "가상환경 생성: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
else
    info "가상환경 확인 완료 (이미 존재함)"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

# ── 3. 파이썬 의존성 ─────────────────────────────────────────────────
info "pip 업그레이드"
pip install --upgrade pip --quiet

# GPU(NVIDIA)가 없으면 CPU 전용 torch를 먼저 설치해
# 불필요한 CUDA 패키지 다운로드(~2GB)를 피한다.
if ! command -v nvidia-smi >/dev/null 2>&1; then
    info "NVIDIA GPU 미감지 → CPU 전용 torch 설치 (용량 절약)"
    pip install torch torchaudio --index-url https://download.pytorch.org/whl/cpu
else
    info "NVIDIA GPU 감지됨 → CUDA 지원 torch 사용 (demucs 설치 시 자동 포함)"
fi

info "파이썬 패키지 설치 (flask, demucs — 최초 설치 시 수 분 소요)"
pip install -r requirements.txt

# ── 4. 설치 검증 ─────────────────────────────────────────────────────
info "설치 검증"
python -c "import flask, demucs, torch; print(f'  flask {flask.__version__} / torch {torch.__version__} / CUDA 사용 가능: {torch.cuda.is_available()}')"

echo
echo "✅ 설치 완료!"

# ── 5. 서버 실행 (--setup-only 지정 시 건너뜀) ──────────────────────
if [ "${1:-}" = "--setup-only" ]; then
    echo
    echo "서버 실행 방법:"
    echo "  cd $SCRIPT_DIR"
    echo "  source .venv/bin/activate"
    echo "  python server.py"
    echo
    echo "브라우저에서 http://localhost:5000 접속"
    echo "(첫 곡 분리 시 htdemucs_6s 모델 ~80MB가 자동 다운로드됩니다)"
    exit 0
fi

# 기존에 떠 있던 서버를 종료하고 새로 시작한다.
# server.py 프로세스(flask debug 리로더 자식 포함)와 5000 포트 점유 프로세스 모두 정리.
info "기존 서버 프로세스 종료 확인"
if pkill -f "python3? .*server\.py" 2>/dev/null; then
    echo "  기존 서버를 종료했습니다."
fi
fuser -k -TERM 5000/tcp 2>/dev/null || true
sleep 1     # 포트가 완전히 해제될 때까지 잠깐 대기

info "서버를 백그라운드로 시작합니다 → http://localhost:5000"
echo "  (첫 곡 분리 시 htdemucs_6s 모델 ~80MB가 자동 다운로드됩니다)"
nohup python server.py > "$SCRIPT_DIR/server.log" 2>&1 &
SERVER_PID=$!

# 서버가 정상적으로 떴는지 확인 (최대 10초 대기)
for _ in $(seq 1 10); do
    sleep 1
    if curl -s -o /dev/null http://localhost:5000/; then
        echo
        echo "✅ 서버 실행 중 (PID $SERVER_PID)"
        echo "  로그 확인: tail -f $SCRIPT_DIR/server.log"
        # flask 디버그 리로더가 자식 프로세스를 하나 더 만들므로 pkill로 안내
        echo "  서버 종료: pkill -f 'python3? .*server\\.py'"
        echo "  재시작:    ./setup.sh (기존 서버 자동 종료 후 재실행)"
        exit 0
    fi
done

echo
echo "❌ 서버가 10초 안에 응답하지 않습니다. 로그를 확인하세요:"
tail -20 "$SCRIPT_DIR/server.log"
exit 1
