"""밴드 음원 분리 믹서 - 백엔드 서버

유튜브 링크로 받은 곡을 yt-dlp로 다운로드한 뒤 Demucs(htdemucs_6s)로
6트랙(보컬/드럼/베이스/기타/피아노/그 외)으로 분리하고, 트랙별 평균 음량을
측정해 실제로 연주되는 악기만 감지하여 웹 프론트엔드에 서빙한다.
"""
import json
import re
import sys
import subprocess
from pathlib import Path

from flask import Flask, request, jsonify, send_from_directory

BASE_DIR = Path(__file__).resolve().parent
UPLOAD_DIR = BASE_DIR / "uploads"
OUTPUT_DIR = BASE_DIR / "separated"
MODEL = "htdemucs_6s"                               # Demucs 6-stem 모델
ALL_TRACKS = ["vocals", "drums", "bass", "guitar", "piano", "other"]
EXT = "mp3"                                         # --mp3 출력 (WAV 대비 용량 1/10)
SILENCE_MEAN_DB = -45.0                             # 평균 음량이 이보다 작으면 '없는 악기'로 판정

# youtube.com/watch?v=ID, youtu.be/ID, shorts/ID 형식에서 11자리 영상 ID 추출
YOUTUBE_ID_RE = re.compile(
    r"(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|embed/)|youtu\.be/)"
    r"([A-Za-z0-9_-]{11})"
)

UPLOAD_DIR.mkdir(exist_ok=True)
OUTPUT_DIR.mkdir(exist_ok=True)

app = Flask(__name__)


def detect_tracks(song_dir: Path) -> list[str]:
    """분리된 스템별 평균 음량(dB)을 재서 실제 연주되는 악기만 골라낸다.

    없는 악기의 스템은 다른 악기가 미세하게 새어 들어간 소리뿐이라
    평균 음량이 매우 낮다(-45dB 미만). 연주되는 악기는 보통 -30dB 이상.
    """
    detected = []
    for track in ALL_TRACKS:
        path = song_dir / f"{track}.{EXT}"
        if not path.exists():
            continue
        result = subprocess.run(
            ["ffmpeg", "-i", str(path), "-af", "volumedetect", "-f", "null", "-"],
            capture_output=True, text=True,
        )
        match = re.search(r"mean_volume:\s*(-?[\d.]+)\s*dB", result.stderr)
        # 음량 측정에 실패하면 안전하게 '있는 악기'로 취급
        if match is None or float(match.group(1)) > SILENCE_MEAN_DB:
            detected.append(track)
    return detected or ALL_TRACKS   # 전부 무음 판정이면(비정상) 전체 트랙 반환


@app.get("/")
def index():
    # index.html을 같은 서버에서 서빙 → CORS 설정 불필요, 배포 시 주소 수정 불필요
    return send_from_directory(BASE_DIR, "index.html")


@app.post("/process")
def process():
    url = (request.get_json(silent=True) or {}).get("url", "")
    match = YOUTUBE_ID_RE.search(url)
    if not match:
        return jsonify({"error": "올바른 유튜브 링크가 아닙니다."}), 400

    # 영상 ID를 곡 이름(캐시 키)으로 사용 → 같은 링크는 다운로드/분리를 건너뛴다
    video_id = match.group(1)
    song_dir = OUTPUT_DIR / MODEL / video_id
    meta_path = song_dir / "meta.json"

    cached = False
    if meta_path.exists():
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        cached = all((song_dir / f"{t}.{EXT}").exists() for t in meta["tracks"])

    if not cached:
        input_path = UPLOAD_DIR / f"{video_id}.mp3"

        # 사용자 입력 URL 대신 추출한 ID로 재조립 → 유튜브 외 임의 주소 다운로드 차단
        cmd = [
            sys.executable, "-m", "yt_dlp",
            "-x", "--audio-format", "mp3",
            "--no-playlist",
            "--no-simulate", "--print", "title",    # 다운로드하면서 곡 제목도 출력
            "-o", str(UPLOAD_DIR / f"{video_id}.%(ext)s"),
            f"https://www.youtube.com/watch?v={video_id}",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0 or not input_path.exists():
            return jsonify({"error": "유튜브 다운로드에 실패했습니다.",
                            "detail": result.stderr[-2000:]}), 500
        title = result.stdout.strip() or video_id

        cmd = [
            sys.executable, "-m", "demucs",
            "-n", MODEL,
            "--mp3",
            "-o", str(OUTPUT_DIR),
            str(input_path),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            return jsonify({"error": "음원 분리에 실패했습니다.",
                            "detail": result.stderr[-2000:]}), 500

        meta = {"title": title, "tracks": detect_tracks(song_dir)}
        meta_path.write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")

    return jsonify({
        "song_name": video_id,
        "title": meta["title"],
        "tracks": [{"id": t, "file": f"{t}.{EXT}"} for t in meta["tracks"]],
        "cached": cached,
    })


@app.get("/audio/<song_name>/<track_name>")
def audio(song_name: str, track_name: str):
    # send_from_directory는 내부적으로 safe_join을 사용해 경로 탈출을 막는다
    return send_from_directory(OUTPUT_DIR / MODEL / song_name, track_name)


if __name__ == "__main__":
    # 0.0.0.0 바인딩: WSL 밖(윈도우 브라우저)이나 EC2/라즈베리파이에서도 접속 가능
    app.run(host="0.0.0.0", port=5000, debug=True)
