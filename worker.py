"""밴드 음원 분리 믹서 - 홈 PC 워커 (v2)

EC2 서버의 작업 큐를 폴링해서 유튜브 다운로드(yt-dlp)와 Demucs 분리를
수행하고, 결과 스템 mp3들과 meta.json을 EC2에 업로드한다.

유튜브가 EC2 IP를 차단하므로 다운로드는 가정용 IP인 이 PC에서만 가능하다.
PC가 NAT 뒤에 있어도 아웃바운드 폴링만 쓰므로 포트포워딩이 필요 없다.

사용법:
    export EC2_URL='http://<EC2-주소>:5000'
    export WORKER_TOKEN='EC2와 동일한 문자열'
    python worker.py
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import requests

BASE_DIR = Path(__file__).resolve().parent
UPLOAD_DIR = BASE_DIR / "uploads"                   # 다운로드 원본 mp3
OUTPUT_DIR = BASE_DIR / "separated"                 # 분리 결과 (로컬 캐시 겸용)
MODEL = "htdemucs_6s"                               # Demucs 6-stem 모델 (서버와 일치해야 함)
ALL_TRACKS = ["vocals", "drums", "bass", "guitar", "piano", "other"]
EXT = "mp3"                                         # --mp3 출력 (WAV 대비 용량 1/10)
SILENCE_MEAN_DB = -45.0                             # 평균 음량이 이보다 작으면 '없는 악기'로 판정

EC2_URL = os.environ.get("EC2_URL", "http://localhost:5000").rstrip("/")
WORKER_TOKEN = os.environ.get("WORKER_TOKEN", "")
POLL_INTERVAL = 3                                   # 작업이 없을 때 재폴링 간격 (초)
RETRY_INTERVAL = 15                                 # 서버 접속 실패 시 재시도 간격 (초)

UPLOAD_DIR.mkdir(exist_ok=True)
OUTPUT_DIR.mkdir(exist_ok=True)

session = requests.Session()
session.headers["X-Worker-Token"] = WORKER_TOKEN


def log(msg: str):
    print(time.strftime("[%m-%d %H:%M:%S]"), msg, flush=True)


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


def separate(video_id: str) -> dict:
    """다운로드 → 분리 → 악기 감지를 수행하고 meta(dict)를 반환한다.

    이미 로컬에 분리 결과가 있으면(이전 실행이 업로드 직전에 끊긴 경우 등)
    그대로 재사용한다 → 재시도 시 다운로드/분리를 반복하지 않는다.
    """
    song_dir = OUTPUT_DIR / MODEL / video_id
    meta_path = song_dir / "meta.json"
    if meta_path.exists():
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        if all((song_dir / f"{t}.{EXT}").exists() for t in meta["tracks"]):
            log(f"  로컬 캐시 재사용: {meta['title']}")
            return meta

    input_path = UPLOAD_DIR / f"{video_id}.mp3"
    # 영상 ID로 URL을 재조립 → 유튜브 외 임의 주소 다운로드 차단 (서버도 ID를 검증함)
    cmd = [
        sys.executable, "-m", "yt_dlp",
        "-x", "--audio-format", "mp3",
        "--no-playlist",
        "--no-simulate", "--print", "title",    # 다운로드하면서 곡 제목도 출력
        "-o", str(UPLOAD_DIR / f"{video_id}.%(ext)s"),
        f"https://www.youtube.com/watch?v={video_id}",
    ]
    log("  유튜브 다운로드 중...")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 or not input_path.exists():
        raise RuntimeError(f"유튜브 다운로드 실패: {result.stderr[-2000:]}")
    title = result.stdout.strip() or video_id

    log(f"  Demucs 분리 중: {title}")
    cmd = [
        sys.executable, "-m", "demucs",
        "-n", MODEL,
        "--mp3",
        "-o", str(OUTPUT_DIR),
        str(input_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"음원 분리 실패: {result.stderr[-2000:]}")

    meta = {"title": title, "tracks": detect_tracks(song_dir)}
    meta_path.write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")
    return meta


def upload(video_id: str, meta: dict):
    """분리 결과를 EC2에 업로드한다. 파일마다 고유한 필드명을 써야
    서버(request.files)가 전부 받는다."""
    song_dir = OUTPUT_DIR / MODEL / video_id
    names = [f"{t}.{EXT}" for t in meta["tracks"]] + ["meta.json"]
    handles = [(song_dir / name).open("rb") for name in names]
    try:
        files = {name: (name, fh, "application/octet-stream")
                 for name, fh in zip(names, handles)}
        resp = session.post(f"{EC2_URL}/worker/result/{video_id}",
                            files=files, timeout=600)
        resp.raise_for_status()
    finally:
        for fh in handles:
            fh.close()


def report_fail(video_id: str, error: str):
    try:
        session.post(f"{EC2_URL}/worker/fail/{video_id}",
                     json={"error": error}, timeout=10)
    except requests.RequestException:
        pass    # 보고조차 실패하면 서버가 타임아웃으로 알아서 재배정한다


def main():
    if not WORKER_TOKEN:
        sys.exit("WORKER_TOKEN 환경변수를 설정하세요 (EC2와 동일한 값).")
    log(f"워커 시작 — 서버: {EC2_URL}, 폴링 간격: {POLL_INTERVAL}초")

    while True:
        try:
            resp = session.get(f"{EC2_URL}/worker/job", timeout=10)
        except requests.RequestException as e:
            log(f"서버 접속 실패({e.__class__.__name__}) — {RETRY_INTERVAL}초 후 재시도")
            time.sleep(RETRY_INTERVAL)
            continue

        if resp.status_code == 204:                 # 대기 중인 작업 없음
            time.sleep(POLL_INTERVAL)
            continue
        if resp.status_code != 200:
            log(f"작업 조회 실패 (HTTP {resp.status_code}): {resp.text[:200]}")
            time.sleep(RETRY_INTERVAL)
            continue

        video_id = resp.json()["video_id"]
        log(f"작업 시작: {video_id}")
        try:
            meta = separate(video_id)
            log(f"  업로드 중: {meta['title']} (트랙 {len(meta['tracks'])}개)")
            upload(video_id, meta)
            log(f"완료: {meta['title']}")
        except Exception as e:                      # 개별 작업 실패가 워커를 죽이지 않도록
            log(f"실패: {video_id} — {e}")
            report_fail(video_id, str(e))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
        log("워커 종료")
