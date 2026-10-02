#!/usr/bin/env bash
set -euo pipefail

# NAS IoT bootstrap for WD MyCloud EX2 Ultra.
# Purpose:
# - Install Entware (opkg) on NAS volume (not internal OS)
# - Install core IoT packages: mosquitto, telegraf, ffmpeg
# - Prepare persistent startup hooks from fun_plug
#
# This script is designed to run ON the NAS.
#
# Usage:
#   ENTWARE_INSTALL=1 /mnt/HD/HD_a2/butler/nas-iot-bootstrap.sh
#
# Optional env vars:
#   ENTWARE_ROOT=/opt
#   ENTWARE_MIRROR=http://bin.entware.net/armv7sf-k3.2

ENTWARE_ROOT="${ENTWARE_ROOT:-/opt}"
ENTWARE_MIRROR="${ENTWARE_MIRROR:-http://bin.entware.net/armv7sf-k3.2}"
LOG_FILE="/mnt/HD/HD_a2/butler/logs/nas-iot-bootstrap.log"
STARTUP_SNIPPET="/mnt/HD/HD_a2/butler/iot/fun_plug.iothub.sh"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STARTUP_SNIPPET")"

log() {
  printf '%s %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG_FILE"
}

require_nas_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log "ERROR: run as root on NAS"
    exit 1
  fi
}

install_entware() {
  if command -v opkg >/dev/null 2>&1; then
    # swallow-ok: a missing opkg shows as the fallback text in this log line
    log "Entware already present: $(opkg --version 2>/dev/null | head -1 || echo opkg)"
    return 0
  fi

  if [[ "${ENTWARE_INSTALL:-0}" != "1" ]]; then
    log "Entware not installed. Set ENTWARE_INSTALL=1 to perform installation."
    return 1
  fi

  log "Installing Entware from ${ENTWARE_MIRROR}"
  mkdir -p "$ENTWARE_ROOT"
  cd /tmp
  wget -O entware-generic.sh "${ENTWARE_MIRROR}/installer/generic.sh"
  sh entware-generic.sh

  if ! command -v opkg >/dev/null 2>&1; then
    if [[ -x /opt/bin/opkg ]]; then
      export PATH="/opt/bin:/opt/sbin:$PATH"
    fi
  fi

  command -v opkg >/dev/null 2>&1 || {
    log "ERROR: Entware install did not provide opkg"
    return 1
  }

  log "Entware installed successfully"
}

install_packages() {
  export PATH="/opt/bin:/opt/sbin:$PATH"
  if ! command -v opkg >/dev/null 2>&1; then
    log "Skipping package install: opkg not available"
    return 1
  fi

  log "Updating opkg repositories"
  opkg update

  for pkg in mosquitto telegraf ffmpeg; do
    if opkg list-installed | awk '{print $1}' | grep -qx "$pkg"; then
      log "Package already installed: $pkg"
    else
      log "Installing package: $pkg"
      opkg install "$pkg"
    fi
  done

  # WireGuard userspace tools are optional; kernel support may still be absent.
  if ! opkg list-installed | awk '{print $1}' | grep -qx wireguard-tools; then
    log "Installing optional package: wireguard-tools"
    opkg install wireguard-tools || log "wireguard-tools install failed (non-fatal)"
  fi
}

write_startup_snippet() {
  cat > "$STARTUP_SNIPPET" <<'EOF'
#!/bin/sh
# OpenClaw NAS IoT startup snippet (source this from fun_plug)

export PATH="/opt/bin:/opt/sbin:$PATH"

# Start Mosquitto if available and not running.
if command -v mosquitto >/dev/null 2>&1; then
  pgrep -f mosquitto >/dev/null 2>&1 || nohup mosquitto -d >/dev/null 2>&1
fi

# Start Telegraf if available and config exists.
if command -v telegraf >/dev/null 2>&1; then
  if [ -f /opt/etc/telegraf.conf ]; then
    pgrep -f telegraf >/dev/null 2>&1 || nohup telegraf --config /opt/etc/telegraf.conf >/dev/null 2>&1
  fi
fi
EOF
  chmod +x "$STARTUP_SNIPPET"
  log "Wrote startup snippet: $STARTUP_SNIPPET"
  log "Add this line to /mnt/USB/USB1_c1/fun_plug if not present:"
  log "  [ -x /mnt/HD/HD_a2/butler/iot/fun_plug.iothub.sh ] && /mnt/HD/HD_a2/butler/iot/fun_plug.iothub.sh"
}

print_status() {
  export PATH="/opt/bin:/opt/sbin:$PATH"
  log "Status summary"
  command -v opkg >/dev/null 2>&1 && log "opkg: yes" || log "opkg: no"
  for b in mosquitto telegraf ffmpeg wg wg-quick; do
    command -v "$b" >/dev/null 2>&1 && log "$b: yes" || log "$b: no"
  done
}

main() {
  require_nas_root
  log "Starting NAS IoT bootstrap"
  # A failed install step used to be swallowed with a trailing "always succeed", and the
  # bootstrap still printed "Done" — the silent-failure shape this pass exists to remove.
  # The status is RECORDED, reported at the end, and carried in the exit code.
  _install_rc=0
  install_entware || _install_rc=1
  install_packages || _install_rc=1
  write_startup_snippet
  print_status
  if [ "$_install_rc" -ne 0 ]; then
    log "Done WITH FAILURES: a package install step did not complete - see the log above"
    return "$_install_rc"
  fi
  log "Done"
}

main "$@"
