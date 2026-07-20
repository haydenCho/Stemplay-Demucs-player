# 🎸 stemplay

> 밴드 음원 분리 플레이어 — 유튜브 곡을 악기별 스템으로 분리해 브라우저에서 믹싱하며 듣는다.

유튜브 링크를 입력하면 yt-dlp로 음원을 내려받고, Demucs(htdemucs_6s)가
**보컬 / 드럼 / 베이스 / 기타 / 피아노 / 그 외** 6개 트랙으로 분리한다.
분리 후 트랙별 평균 음량을 측정해 **실제로 연주되는 악기만 감지**하여
웹 페이지에 표시하고, 악기별 볼륨을 조절하며 감상할 수 있다.

## 설치 (WSL Ubuntu 24.04)

```bash
cd ~/Music/band-mixer
./setup.sh                # 설치 후 바로 서버 실행
./setup.sh --setup-only   # 설치만 수행
```

`setup.sh`가 시스템 패키지(ffmpeg, python3-venv), 가상환경 생성,
파이썬 의존성 설치, 서버 실행까지 한 번에 처리한다.
여러 번 실행해도 안전하며, 이미 설치된 항목은 건너뛰고 바로 서버가 뜬다.
서버 실행 전에 **기존에 떠 있던 서버 프로세스를 자동으로 종료**하므로
재시작 용도로도 그냥 `./setup.sh`를 다시 실행하면 된다.

> GPU(NVIDIA + CUDA)가 있으면 분리 속도가 수십 배 빨라진다.
> CPU만 있어도 동작은 하며, 4분짜리 곡 기준 수 분 정도 걸린다.

## 실행

```bash
./setup.sh                # 설치 확인 후 서버를 백그라운드로 실행 (평소에도 이걸로 실행/재시작)

# 로그 확인
tail -f server.log

# 서버 종료
pkill -f 'python3? .*server\.py'

# 포그라운드로 직접 실행하고 싶다면
source .venv/bin/activate
python server.py
```

브라우저에서 **http://localhost:5000** 접속 → 유튜브 링크 입력 → 슬라이더로 믹싱.

- 첫 실행 시 htdemucs_6s 모델(약 80MB)이 `~/.cache/torch/`에 자동 다운로드된다.
- 한 번 분리한 곡은 영상 ID 기준으로 `separated/` 폴더에 캐싱되어,
  같은 링크를 다시 입력하면 즉시 로드된다.
- WSL의 경우 윈도우 브라우저에서 `localhost:5000`으로 바로 접속 가능하다.

## 폴더 구조

```
band-mixer/
├── server.py          # Flask 백엔드 (yt-dlp 다운로드 → Demucs 실행 → 악기 감지 → 오디오 서빙)
├── index.html         # 프론트엔드 (Web Audio API 멀티트랙 동기 재생 믹서)
├── uploads/           # 다운로드 원본 mp3 (자동 생성)
└── separated/         # 분리 결과 mp3 (자동 생성, 캐시 역할)
    └── htdemucs_6s/<영상ID>/{vocals,drums,bass,guitar,piano,other}.mp3 + meta.json
```

## 배포 시 참고

**공통**: `index.html`을 Flask가 직접 서빙하므로(same-origin) CORS 설정이나
프론트엔드의 서버 주소 수정이 필요 없다. 접속 주소만 바뀐다.

**EC2**
- 보안 그룹에서 5000 포트를 **내 IP에만** 열 것 (나만 쓰는 서비스이므로).
- 상시 운영 시 `debug=True`를 끄고 gunicorn 사용 권장:
  `pip install gunicorn && gunicorn -b 0.0.0.0:5000 --timeout 600 server:app`
  (분리 작업이 길어서 timeout을 넉넉하게 잡아야 함)
- t2.micro 같은 저사양 인스턴스에서는 Demucs 실행 시 메모리 부족이 날 수 있다.

**라즈베리파이**
- 파이에서 Demucs 분리는 매우 느리다(곡당 수십 분). **PC(WSL)에서 미리 분리한 뒤
  `separated/` 폴더째 복사**하면, 파이는 재생 서버 역할만 하므로 쾌적하다.
  캐시 히트로 처리되어 업로드 즉시 재생된다.
- torch 설치는 CPU 전용 버전 사용:
  `pip install torch --index-url https://download.pytorch.org/whl/cpu`
