#!/bin/sh
set -eu
OTP_FILE=${MYAIR_OTP_FILE:-/mnt/HD/HD_a2/butler/cron/myair-email-otp.txt}
if [ ! -f "$OTP_FILE" ]; then
  echo "OTP file not found: $OTP_FILE" >&2
  exit 1
fi
otp="$(grep -Eo '[0-9]{6,8}' "$OTP_FILE" | tail -n 1 || true)"
if [ -z "$otp" ]; then
  echo "No OTP found in file: $OTP_FILE" >&2
  exit 1
fi
echo "$otp"
