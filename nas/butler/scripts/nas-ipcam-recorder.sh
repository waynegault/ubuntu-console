#!/usr/bin/env bash
set -euo pipefail

# NAS-native RTSP recorder for IP cameras.
# - Stores segmented MP4 files on NAS storage.
# - Runs without any PC dependency.
#
# Usage:
#   CAMERA_NAME=front_door RTSP_URL='rtsp://user:pass@192.168.33.50:554/stream1' \
#   /mnt/HD/HD_a2/butler/nas-ipcam-recorder.sh
#
# Optional env vars:
#   RECORD_ROOT=/mnt/HD/HD_a2/butler/camera-recordings
#   SEGMENT_SECONDS=300
#   RETENTION_DAYS=14

CAMERA_NAME="${CAMERA_NAME:-camera1}"
RTSP_URL="${RTSP_URL:-}"
RECORD_ROOT="${RECORD_ROOT:-/mnt/HD/HD_a2/butler/camera-recordings}"
SEGMENT_SECONDS="${SEGMENT_SECONDS:-300}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
FFMPEG_BIN="${FFMPEG_BIN:-$(command -v ffmpeg 2>/dev/null || true)}"
LOG_DIR="${RECORD_ROOT}/logs"
CAM_DIR="${RECORD_ROOT}/${CAMERA_NAME}"

if [[ -z "${RTSP_URL}" ]]; then
  echo "[ERROR] RTSP_URL is required" >&2
  exit 1
fi

if [[ -z "${FFMPEG_BIN}" ]]; then
  echo "[ERROR] ffmpeg not found. Install ffmpeg on NAS (Entware package: ffmpeg)." >&2
  exit 1
fi

mkdir -p "${CAM_DIR}" "${LOG_DIR}"

# One process per camera to avoid duplicate writers.
LOCK_DIR="/tmp/nas-ipcam-recorder-${CAMERA_NAME}.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  echo "[INFO] recorder already running for ${CAMERA_NAME}" >&2
  exit 0
fi
trap 'rm -rf "${LOCK_DIR}"' EXIT INT TERM

# Keep storage bounded.
find "${CAM_DIR}" -type f -name '*.mp4' -mtime +"${RETENTION_DAYS}" -delete || true

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_PATTERN="${CAM_DIR}/${CAMERA_NAME}_${STAMP}_%05d.mp4"
LOG_FILE="${LOG_DIR}/${CAMERA_NAME}.log"

{
  echo "[$(date -Iseconds)] starting recorder camera=${CAMERA_NAME} segment=${SEGMENT_SECONDS}s"
  "${FFMPEG_BIN}" \
    -hide_banner -loglevel warning \
    -rtsp_transport tcp \
    -i "${RTSP_URL}" \
    -an \
    -c copy \
    -f segment \
    -segment_time "${SEGMENT_SECONDS}" \
    -segment_format mp4 \
    -reset_timestamps 1 \
    "${OUT_PATTERN}"
} >> "${LOG_FILE}" 2>&1
