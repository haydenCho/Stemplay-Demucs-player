#!/usr/bin/env bash
# stemplay v2 - nginx 리버스 프록시 설정 스크립트 (EC2에서 실행)
#
# 구성:
#   브라우저/워커 → nginx(443, SSL 종료) → gunicorn(127.0.0.1:5000)
#   오디오 파일은 nginx가 직접 서빙한다 — server.py가 세션 확인 후
#   X-Accel-Redirect로 위임하는 방식이라 인증을 우회하지 않으면서도
#   Range 요청(재생 위치 탐색)이 빠르다.
#
# 사용법:
#   sudo ./setup-nginx.sh
#
# 전제:
#   - nginx 설치됨
#   - certbot으로 $DOMAIN 인증서 발급 완료 (/etc/letsencrypt/live/$DOMAIN/)
#
# 적용 후 할 일 (스크립트 끝에도 출력됨):
#   - EC2 .env: WEB_PASSWORD, SECRET_KEY, NGINX_ACCEL=1, BIND=127.0.0.1 설정
#   - 보안그룹: 443/80만 열고 5000은 닫기
#   - 홈 PC .env: EC2_URL=https://$DOMAIN

set -euo pipefail

DOMAIN="${DOMAIN:-stemplay.greatsounds.me}"
PORT="${PORT:-5000}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIO_DIR="$SCRIPT_DIR/separated/htdemucs_6s"
SITE=/etc/nginx/sites-available/stemplay

[ "$(id -u)" -eq 0 ] || { echo "❌ sudo로 실행하세요: sudo ./setup-nginx.sh"; exit 1; }
command -v nginx >/dev/null || { echo "❌ nginx가 설치되어 있지 않습니다."; exit 1; }
[ -d "/etc/letsencrypt/live/$DOMAIN" ] || {
    echo "❌ $DOMAIN 인증서가 없습니다. 먼저 발급하세요:"
    echo "   sudo certbot --nginx -d $DOMAIN"; exit 1; }

# 오디오 디렉토리를 프로젝트 소유자 권한으로 미리 생성 (첫 분리 전에도 nginx -t 통과)
OWNER="$(stat -c %U "$SCRIPT_DIR")"
sudo -u "$OWNER" mkdir -p "$AUDIO_DIR"

# nginx(www-data)가 오디오 경로를 읽을 수 있는지 확인
if ! sudo -u www-data test -x "$SCRIPT_DIR" 2>/dev/null; then
    echo "⚠️  www-data가 $SCRIPT_DIR 에 접근할 수 없습니다. 홈 디렉토리 권한을 확인하세요:"
    echo "   chmod o+x $(dirname "$SCRIPT_DIR") $SCRIPT_DIR"
fi

echo "==> nginx 사이트 설정 생성: $SITE"
cat > "$SITE" <<EOF
server {
    server_name $DOMAIN;

    # 워커의 분리 결과 업로드 (스템 mp3 여러 개 + meta.json 멀티파트)
    client_max_body_size 300m;

    # 분리된 오디오 — server.py가 세션 확인 후 X-Accel-Redirect로 위임하면
    # nginx가 직접 서빙 (internal: 외부에서 이 경로로 직접 접근 불가)
    location /_audio/ {
        internal;
        alias $AUDIO_DIR/;
    }

    # 나머지 전부 gunicorn으로 프록시 (웹 UI + 브라우저 API + 워커 API)
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;    # 워커의 대용량 업로드 대비
    }

    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

ln -sf "$SITE" /etc/nginx/sites-enabled/stemplay

# 같은 도메인을 잡는 다른 설정 파일이 있으면 경고 (기존 v1 설정 등)
DUP="$(grep -rl "server_name.*$DOMAIN" /etc/nginx/sites-enabled/ 2>/dev/null | grep -v '/stemplay$' || true)"
if [ -n "$DUP" ]; then
    echo "⚠️  같은 도메인($DOMAIN)을 쓰는 다른 설정이 있습니다. 중복이면 지우세요:"
    echo "$DUP" | sed 's/^/   /'
fi

echo "==> nginx 설정 검사 및 리로드"
nginx -t
systemctl reload nginx

echo
echo "✅ 완료 → https://$DOMAIN"
echo
echo "남은 작업:"
echo "  1. $SCRIPT_DIR/.env 설정 후 ./run.sh server 재실행:"
echo "       WORKER_TOKEN=<길고 추측 불가능한 문자열>"
echo "       WEB_PASSWORD=<웹 접속 비밀번호>"
echo "       SECRET_KEY=\$(openssl rand -hex 32)"
echo "       NGINX_ACCEL=1"
echo "       BIND=127.0.0.1"
echo "  2. EC2 보안그룹 인바운드: 443, 80만 0.0.0.0/0 으로 열기 — 5000 규칙은 삭제"
echo "  3. 홈 PC .env: EC2_URL=https://$DOMAIN 으로 변경 후 ./run.sh worker 재실행"
