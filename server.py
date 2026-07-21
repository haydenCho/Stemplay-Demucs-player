"""밴드 음원 분리 믹서 - EC2 서버 (v2)

웹 서빙 + 작업 큐 + 분리 결과 저장/제공만 담당한다.
유튜브 다운로드와 Demucs 분리는 홈 PC의 worker.py가 수행한다
(유튜브가 EC2 IP를 차단하므로). 워커는 /worker/* API를 폴링해
작업을 가져가고, 분리 결과 mp3들을 업로드한다.

torch / demucs / yt-dlp / ffmpeg 불필요 — Flask만 있으면 된다.
"""
import hmac
import json
import os
import re
import shutil
import threading
import time
from datetime import timedelta
from pathlib import Path

from flask import (Flask, Response, jsonify, redirect, render_template_string,
                   request, send_from_directory, session)

BASE_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = BASE_DIR / "separated"
MODEL = "htdemucs_6s"                               # Demucs 6-stem 모델 (워커와 일치해야 함)
ALL_TRACKS = ["vocals", "drums", "bass", "guitar", "piano", "other"]
EXT = "mp3"

# .env 파일이 있으면 읽어서 환경변수로 등록한다 (export로 이미 설정된 값이 우선).
# WORKER_TOKEN 같은 시크릿을 깃에 올리지 않기 위함 — .env는 .gitignore에 있다.
if (BASE_DIR / ".env").exists():
    for _line in (BASE_DIR / ".env").read_text().splitlines():
        _line = _line.strip()
        if _line and not _line.startswith("#") and "=" in _line:
            _key, _, _val = _line.partition("=")
            os.environ.setdefault(_key.strip(), _val.strip().strip("'\""))

WORKER_TOKEN = os.environ.get("WORKER_TOKEN", "")   # 워커 인증용 공유 시크릿
WEB_PASSWORD = os.environ.get("WEB_PASSWORD", "")   # 웹 UI 비밀번호 (비우면 인증 없음 — 로컬 개발용)
NGINX_ACCEL = os.environ.get("NGINX_ACCEL") == "1"  # 오디오 서빙을 nginx에 위임 (setup-nginx.sh 참고)
WORKER_ONLINE_WINDOW = 30.0                         # 마지막 폴링이 이 초 이내면 '워커 켜짐'
JOB_STALE_SECONDS = 30 * 60                         # processing이 이보다 오래되면 워커가 죽은 것 → 재배정

# youtube.com/watch?v=ID, youtu.be/ID, shorts/ID 형식에서 11자리 영상 ID 추출
YOUTUBE_ID_RE = re.compile(
    r"(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|embed/)|youtu\.be/)"
    r"([A-Za-z0-9_-]{11})"
)

OUTPUT_DIR.mkdir(exist_ok=True)

app = Flask(__name__)

# 세션 쿠키 서명 키. SECRET_KEY 미설정 시 부팅마다 랜덤 → 서버 재시작하면 재로그인 필요.
# (run.sh는 gunicorn을 워커 프로세스 1개 + 스레드로 띄우므로 랜덤 키도 정상 동작한다)
app.secret_key = os.environ.get("SECRET_KEY") or os.urandom(32)
app.permanent_session_lifetime = timedelta(days=30)
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"

# 작업 큐. 단일 사용자 서비스라 메모리로 충분하다 (gunicorn 기본 워커 1개 기준).
# 서버가 재시작되면 대기 중이던 작업은 사라지므로 링크를 다시 제출하면 된다.
# video_id -> {"status": "queued"|"processing"|"failed", "error": str|None, "created": float}
jobs: dict[str, dict] = {}
jobs_lock = threading.Lock()
worker_last_seen = 0.0                              # 워커가 마지막으로 폴링한 시각


def song_dir(video_id: str) -> Path:
    return OUTPUT_DIR / MODEL / video_id


def load_song(video_id: str) -> dict | None:
    """분리 완료된 곡의 재생 정보를 반환한다. 캐시 미스나 파일 누락이면 None."""
    meta_path = song_dir(video_id) / "meta.json"
    if not meta_path.exists():
        return None
    try:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not all((song_dir(video_id) / f"{t}.{EXT}").exists() for t in meta["tracks"]):
        return None
    return {
        "song_name": video_id,
        "title": meta["title"],
        "tracks": [{"id": t, "file": f"{t}.{EXT}"} for t in meta["tracks"]],
    }


def worker_online() -> bool:
    return time.time() - worker_last_seen < WORKER_ONLINE_WINDOW


def require_worker_token():
    """워커 API 인증. 통과하면 None, 실패하면 (응답, 상태코드)를 반환한다."""
    global worker_last_seen
    if not WORKER_TOKEN:
        return jsonify({"error": "서버에 WORKER_TOKEN이 설정되지 않았습니다."}), 503
    sent = request.headers.get("X-Worker-Token", "")
    if not hmac.compare_digest(sent, WORKER_TOKEN):
        return jsonify({"error": "워커 토큰이 일치하지 않습니다."}), 403
    worker_last_seen = time.time()
    return None


# ------------------------------------------------------------------- 웹 인증

LOGIN_HTML = """<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>밴드 믹서 - 로그인</title>
<style>
  body { font-family: sans-serif; background: #111; color: #eee; margin: 0;
         display: flex; justify-content: center; align-items: center; height: 100vh; }
  form { background: #1c1c1c; padding: 2rem; border-radius: 12px; text-align: center; }
  input { font-size: 1rem; padding: .6rem .8rem; border-radius: 8px;
          border: 1px solid #444; background: #111; color: #eee; }
  button { font-size: 1rem; padding: .6rem 1rem; border-radius: 8px; border: 0;
           background: #4a7dff; color: #fff; cursor: pointer; margin-left: .3rem; }
  .error { color: #ff7676; margin-top: .8rem; font-size: .9rem; }
</style></head><body>
<form method="post">
  <h2>🎛️ 밴드 믹서</h2>
  <input type="password" name="password" placeholder="비밀번호" autofocus>
  <button>입장</button>
  {% if error %}<div class="error">{{ error }}</div>{% endif %}
</form></body></html>"""


@app.before_request
def require_login():
    """웹 UI 비밀번호 인증. WEB_PASSWORD가 비어 있으면 비활성 (로컬 개발)."""
    if not WEB_PASSWORD:
        return None
    path = request.path
    if path == "/login" or path.startswith("/worker/"):
        return None                     # 로그인 페이지와 워커 API(토큰 인증)는 제외
    if session.get("authed"):
        return None
    if path == "/":
        return redirect("/login")       # 페이지 접속 → 로그인 화면으로
    return jsonify({"error": "로그인이 필요합니다."}), 401   # API 호출 → 401 (JS가 처리)


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "GET":
        return render_template_string(LOGIN_HTML, error=None)
    if WEB_PASSWORD and hmac.compare_digest(request.form.get("password", ""), WEB_PASSWORD):
        session.permanent = True        # 쿠키 30일 유지 → 폰에서 매번 입력 안 해도 됨
        session["authed"] = True
        return redirect("/")
    time.sleep(1)                       # 무차별 대입 속도 제한
    return render_template_string(LOGIN_HTML, error="비밀번호가 올바르지 않습니다."), 403


# ---------------------------------------------------------------- 브라우저 API

@app.get("/")
def index():
    # index.html을 같은 서버에서 서빙 → CORS 설정 불필요, 배포 시 주소 수정 불필요
    return send_from_directory(BASE_DIR, "index.html")

@app.get("/images/<path:filename>")
def images(filename):
    # 이미지 파일도 서빙
    return send_from_directory(BASE_DIR / "images", filename)

@app.get("/songs")
def songs():
    """곡 리스트: 분리 완료된 곡들 + 진행 중인 작업들 + 워커 생존 여부."""
    done = []
    model_dir = OUTPUT_DIR / MODEL
    if model_dir.exists():
        for child in model_dir.iterdir():
            song = load_song(child.name)
            if song:
                song["mtime"] = (child / "meta.json").stat().st_mtime
                done.append(song)
    done.sort(key=lambda s: s.pop("mtime"), reverse=True)   # 최근 분리한 곡부터

    with jobs_lock:
        pending = [
            {"song_name": vid, "status": job["status"], "error": job.get("error")}
            for vid, job in sorted(jobs.items(), key=lambda kv: kv[1]["created"])
        ]
    return jsonify({"songs": done, "jobs": pending, "worker_online": worker_online()})


@app.post("/process")
def process():
    url = (request.get_json(silent=True) or {}).get("url", "")
    match = YOUTUBE_ID_RE.search(url)
    if not match:
        return jsonify({"error": "올바른 유튜브 링크가 아닙니다."}), 400
    video_id = match.group(1)

    # 이미 분리된 곡이면 바로 재생 정보 반환
    song = load_song(video_id)
    if song:
        return jsonify({**song, "status": "done", "cached": True})

    with jobs_lock:
        job = jobs.get(video_id)
        if job and job["status"] in ("queued", "processing"):
            return jsonify({"song_name": video_id, "status": job["status"]})
        # 신규 작업 또는 실패했던 작업 재시도
        jobs[video_id] = {"status": "queued", "error": None, "created": time.time()}

    return jsonify({"song_name": video_id, "status": "queued",
                    "worker_online": worker_online()})


@app.get("/status/<video_id>")
def status(video_id: str):
    song = load_song(video_id)
    if song:
        return jsonify({**song, "status": "done"})
    with jobs_lock:
        job = jobs.get(video_id)
    if job is None:
        return jsonify({"status": "unknown"}), 404
    return jsonify({"song_name": video_id, "status": job["status"],
                    "error": job.get("error"), "worker_online": worker_online()})


@app.get("/audio/<song_name>/<track_name>")
def audio(song_name: str, track_name: str):
    # nginx 뒤에서는 세션 확인만 하고 파일 전송은 nginx에 위임한다
    # (X-Accel-Redirect → internal location이 직접 서빙, Range 지원으로 탐색이 빠름)
    if NGINX_ACCEL:
        if (not re.fullmatch(r"[A-Za-z0-9_-]{11}", song_name)
                or track_name not in {f"{t}.{EXT}" for t in ALL_TRACKS}):
            return jsonify({"error": "잘못된 경로입니다."}), 404
        resp = Response()
        resp.headers["X-Accel-Redirect"] = f"/_audio/{song_name}/{track_name}"
        return resp
    # send_from_directory는 내부적으로 safe_join을 사용해 경로 탈출을 막는다
    return send_from_directory(OUTPUT_DIR / MODEL / song_name, track_name)


@app.post("/clear")
def clear():
    # 분리 결과 캐시와 작업 큐 전체 초기화
    with jobs_lock:
        jobs.clear()
    for child in OUTPUT_DIR.iterdir():
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
    return jsonify({"ok": True})


@app.delete("/songs/<video_id>")
def delete_song(video_id: str):
    # 곡 하나만 삭제: 분리 결과 폴더와 대기/실패 중인 작업 큐 항목을 함께 정리한다
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
        return jsonify({"error": "올바른 영상 ID가 아닙니다."}), 400
    with jobs_lock:
        jobs.pop(video_id, None)
    dest = song_dir(video_id)
    if dest.exists():
        shutil.rmtree(dest)
    return jsonify({"ok": True})


# ------------------------------------------------------------------ 워커 API

@app.get("/worker/job")
def worker_job():
    """대기 중인 작업 하나를 워커에게 배정한다. 없으면 204."""
    denied = require_worker_token()
    if denied:
        return denied
    now = time.time()
    with jobs_lock:
        for vid, job in sorted(jobs.items(), key=lambda kv: kv[1]["created"]):
            # 워커가 죽어서 오래 방치된 processing 작업도 다시 배정한다
            stale = job["status"] == "processing" and now - job["created"] > JOB_STALE_SECONDS
            if job["status"] == "queued" or stale:
                job.update(status="processing", created=now)
                return jsonify({"video_id": vid})
    return "", 204


@app.post("/worker/result/<video_id>")
def worker_result(video_id: str):
    """분리 결과 업로드: 스템 mp3들 + meta.json (multipart/form-data)."""
    denied = require_worker_token()
    if denied:
        return denied
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
        return jsonify({"error": "올바른 영상 ID가 아닙니다."}), 400

    allowed = {f"{t}.{EXT}" for t in ALL_TRACKS} | {"meta.json"}
    files = {f.filename: f for f in request.files.values() if f.filename in allowed}
    if "meta.json" not in files:
        return jsonify({"error": "meta.json이 없습니다."}), 400
    try:
        meta = json.loads(files["meta.json"].read().decode("utf-8"))
        files["meta.json"].seek(0)
        tracks = meta["tracks"]
        assert isinstance(meta["title"], str)
        assert tracks and all(t in ALL_TRACKS for t in tracks)
    except (json.JSONDecodeError, UnicodeDecodeError, KeyError, AssertionError, TypeError):
        return jsonify({"error": "meta.json 형식이 올바르지 않습니다."}), 400
    missing = [t for t in tracks if f"{t}.{EXT}" not in files]
    if missing:
        return jsonify({"error": f"트랙 파일 누락: {missing}"}), 400

    # 업로드 도중 브라우저가 미완성 곡을 재생하지 않도록 임시 폴더에 받은 뒤 교체
    dest = song_dir(video_id)
    tmp = dest.with_name(dest.name + ".uploading")
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    for name, f in files.items():
        f.save(tmp / name)
    if dest.exists():
        shutil.rmtree(dest)
    tmp.rename(dest)

    with jobs_lock:
        jobs.pop(video_id, None)
    return jsonify({"ok": True})


@app.post("/worker/fail/<video_id>")
def worker_fail(video_id: str):
    """워커의 실패 보고. 곡 리스트에 실패 사유가 표시된다."""
    denied = require_worker_token()
    if denied:
        return denied
    error = (request.get_json(silent=True) or {}).get("error", "알 수 없는 오류")
    with jobs_lock:
        if video_id in jobs:
            jobs[video_id].update(status="failed", error=str(error)[-2000:])
    return jsonify({"ok": True})


if __name__ == "__main__":
    # 0.0.0.0 바인딩: WSL 밖(윈도우 브라우저)이나 EC2에서도 접속 가능
    app.run(host="0.0.0.0", port=5000, debug=True)
