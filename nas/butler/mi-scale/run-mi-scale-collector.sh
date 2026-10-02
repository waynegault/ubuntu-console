#!/bin/sh
# NAS-local Mi Scale collector runner
# This wrapper keeps all execution on NAS and writes data under /mnt/HD/HD_a2/wayne.

export MI_SCALE_DATA_DIR=/mnt/HD/HD_a2/wayne/body-monitor
export MI_SCALE_TARGET=D8:E7:2F:08:7C:5D
export MI_SCALE_ALIAS=Mi_Scale_2
export MI_SCALE_OWNER=Wayne123
export MI_SCALE_RUNTIME=linux

# Guard: current btusb stack has known scan instability; keep disabled until kernel fix.
if [ "${MI_SCALE_ENABLE_SCAN:-0}" != "1" ]; then
  echo "MI scale collector installed on NAS, scan disabled (set MI_SCALE_ENABLE_SCAN=1 to enable)."
  exit 0
fi

# One-shot read; caller can loop from cron/fun_plug.
exec python3 /mnt/HD/HD_a2/wayne/mi-scale-2-collector.py
