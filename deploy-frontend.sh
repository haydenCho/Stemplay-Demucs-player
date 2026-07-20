#!/usr/bin/env bash
# 프론트엔드 배포 스크립트 — nginx로 정적 파일(index.html, 오디오) 직접 서빙
#
# 사용법:
#   ./deploy-frontend.sh            # nginx 설정 생성/갱신 후 적용
#   ./deploy-frontend.sh --force    # certbot이 수정한 기존 설정도 덮어쓰기
#   (보통은 통합 스크립트 ./deploy.sh 로 백엔드와 함께 배포한다)
#
# 하는 일:
#   - nginx 설치 (없을 때만)
#   - /etc/nginx/sites-enabled/stemplay.greatsounds.me.conf 셋업:
#       * index.html과 separated/의 분리된 오디오 → nginx가 직접 서빙
#       * /process, /clear API → 백엔드 gunicorn(127.0.0.1:5000)으로 프록시
#   - Let's Encrypt 인증서가 이미 있으면 HTTPS(443) + HTTP→HTTPS 리다이렉트 구성,
#     없으면 HTTP(80)로 구성하고 certbot 실행 방법을 안내
#
# DNS: stemplay.greatsounds.me → 13.124.156.125 (A 레코드) 가 등록되어 있어야 한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="stemplay.greatsounds.me"
PUBLIC_IP="13.124.156.125"
BACKEND_PORT=5000
CONF_AVAILABLE="/etc/nginx/sites-available/$DOMAIN.conf"
CONF_ENABLED="/etc/nginx/sites-enabled/$DOMAIN.conf"
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

info() { echo -e "\n\033[1;34m==>\033[0m $*"; }

cd "$SCRIPT_DIR"

# ── 1. nginx 설치 ────────────────────────────────────────────────────
if ! command -v nginx >/dev/null; then
    info "nginx 설치"
    sudo apt-get update
    sudo apt-get install -y nginx
else
    info "nginx 확인 완료 (이미 설치됨)"
fi

# ── 2. DNS 확인 ──────────────────────────────────────────────────────
RESOLVED=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)
if [ "$RESOLVED" = "$PUBLIC_IP" ]; then
    info "DNS 확인 완료: $DOMAIN → $PUBLIC_IP"
else
    info "⚠️ DNS 확인 필요: $DOMAIN 이 ${RESOLVED:-해석 안 됨} 로 나옵니다."
    echo "   도메인 관리 콘솔에서 A 레코드를 추가하세요: $DOMAIN → $PUBLIC_IP"
    echo "   (전파 전이라면 설정은 계속 진행되며, 전파 후 자동으로 접속됩니다)"
fi

# ── 3. 파일 접근 권한 ────────────────────────────────────────────────
# Ubuntu의 홈 디렉토리는 750 권한이라 nginx(www-data)가 프로젝트 안의
# 정적 파일을 읽지 못한다 → www-data를 내 그룹에 추가해 그룹 권한으로 접근.
if ! id -nG www-data | grep -qw "$(id -gn)"; then
    info "www-data를 $(id -gn) 그룹에 추가 (정적 파일 읽기 권한)"
    sudo usermod -aG "$(id -gn)" www-data
else
    info "파일 접근 권한 확인 완료"
fi

# ── 4. nginx 사이트 설정 생성 ────────────────────────────────────────
# 공통 부분: 정적 파일은 nginx가 직접, API만 백엔드로 프록시.
# (heredoc 안의 \$ 는 nginx 변수를 위한 이스케이프)
LOCATIONS=$(cat <<EOF
    root $SCRIPT_DIR;
    index index.html;

    # 정적 파일 (index.html)
    location / {
        try_files \$uri \$uri/ =404;
    }

    # 분리된 오디오 파일도 nginx가 직접 서빙 (Range 요청 지원 → 탐색이 빠름)
    location /audio/ {
        alias $SCRIPT_DIR/separated/htdemucs_6s/;
    }

    # API는 백엔드(gunicorn)로 프록시
    location ~ ^/(process|clear)\$ {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;    # 분리 작업이 수 분 걸리므로 넉넉하게
    }
EOF
)

if sudo test -d "$CERT_DIR"; then
    # 인증서가 이미 있으면 처음부터 HTTPS 구성으로 작성
    info "Let's Encrypt 인증서 감지 → HTTPS(443) 설정 작성: $CONF_AVAILABLE"
    sudo tee "$CONF_AVAILABLE" >/dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;

$LOCATIONS
}
EOF
elif [ -f "$CONF_AVAILABLE" ] && grep -q "listen 443" "$CONF_AVAILABLE" && [ "${1:-}" != "--force" ]; then
    # certbot --nginx 가 이 파일을 수정해 HTTPS를 붙인 경우 덮어쓰지 않는다
    info "기존 설정에 HTTPS(443)가 적용되어 있어 보존합니다. (덮어쓰려면 --force)"
else
    info "HTTP(80) 설정 작성: $CONF_AVAILABLE"
    sudo tee "$CONF_AVAILABLE" >/dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

$LOCATIONS
}
EOF
fi

sudo ln -sf "$CONF_AVAILABLE" "$CONF_ENABLED"

# ── 5. 적용 및 확인 ──────────────────────────────────────────────────
info "nginx 설정 검사 및 재시작"
sudo nginx -t
# reload가 아닌 restart: www-data의 새 그룹 멤버십을 워커에 반영하기 위함
sudo systemctl restart nginx

if curl -s -o /dev/null -H "Host: $DOMAIN" "http://127.0.0.1/"; then
    echo
    echo "✅ 프론트엔드(nginx) 배포 완료!"
    if sudo test -d "$CERT_DIR"; then
        echo "  접속 주소: https://$DOMAIN"
    else
        echo "  접속 주소: http://$DOMAIN"
        echo "  HTTPS 적용: sudo certbot --nginx -d $DOMAIN"
        echo "  (certbot 미설치 시: sudo apt-get install -y certbot python3-certbot-nginx)"
    fi
else
    echo
    echo "❌ nginx가 index.html을 서빙하지 못합니다. 에러 로그를 확인하세요:"
    sudo tail -20 /var/log/nginx/error.log
    exit 1
fi
