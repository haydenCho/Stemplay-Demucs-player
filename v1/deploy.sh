#!/usr/bin/env bash
# 통합 배포 스크립트 — 백엔드(gunicorn) + 프론트엔드(nginx)를 한 번에 배포
#
# 사용법 (EC2 인스턴스 안에서 실행):
#   1. 깃허브에서 클론:
#        git clone https://github.com/<계정>/Stemplay-Demucs-player.git
#   2. 배포:
#        cd ~/Stemplay-Demucs-player && ./deploy.sh
#
#   (선택) PC에서 미리 분리해 둔 곡 캐시를 가져가면 EC2에서 분리를 건너뛴다:
#        rsync -av ~/Music/band-mixer/separated/ ubuntu@13.124.156.125:~/Stemplay-Demucs-player/separated/
#
# 구성:
#   - deploy-backend.sh  : Flask API(gunicorn, 127.0.0.1:5000)를 systemd 서비스로 실행
#   - deploy-frontend.sh : nginx가 index.html/오디오를 직접 서빙, API만 백엔드로 프록시
#                          → /etc/nginx/sites-enabled/stemplay.greatsounds.me.conf 셋업
#
# 보안 그룹: 80, 443, 22만 열면 된다 (5000은 열지 말 것 — 백엔드는 localhost 전용).
# DNS: stemplay.greatsounds.me → 13.124.156.125 (A 레코드) 필요.
#
# 여러 번 실행해도 안전하다 (재배포 = git pull 후 ./deploy.sh 재실행).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="stemplay.greatsounds.me"

"$SCRIPT_DIR/deploy-backend.sh"
"$SCRIPT_DIR/deploy-frontend.sh"

echo
echo "🎸 전체 배포 완료!"
if sudo test -d "/etc/letsencrypt/live/$DOMAIN"; then
    echo "  브라우저에서 접속: https://$DOMAIN"
else
    echo "  브라우저에서 접속: http://$DOMAIN"
    echo "  🔒 SSL 인증서 설정 (HTTPS 적용):"
    echo "     sudo apt-get install -y certbot python3-certbot-nginx"
    echo "     sudo certbot --nginx -d $DOMAIN"
fi
echo "  백엔드 로그:  journalctl -u stemplay -f"
echo "  nginx 로그:   sudo tail -f /var/log/nginx/access.log"
