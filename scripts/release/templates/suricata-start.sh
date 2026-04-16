#!/bin/sh
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)
ENV_FILE=${SURICATA_ENV_FILE:-/etc/default/suricata-release}

if [ -r "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

detect_interface() {
  if [ -n "${SURICATA_INTERFACE:-}" ]; then
    printf '%s\n' "$SURICATA_INTERFACE"
    return 0
  fi

  if command -v ip >/dev/null 2>&1; then
    iface=$(ip route show default 2>/dev/null | awk '/default/ { print $5; exit }')
    if [ -z "${iface:-}" ]; then
      iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" { print $2; exit }')
    fi
  else
    iface=""
  fi

  if [ -z "${iface:-}" ]; then
    echo "Unable to detect a capture interface. Set SURICATA_INTERFACE in $ENV_FILE." >&2
    return 1
  fi

  printf '%s\n' "$iface"
}

LOG_DIR=${SURICATA_LOG_DIR:-$ROOT_DIR/var/log}
RUN_DIR=${SURICATA_RUN_DIR:-$ROOT_DIR/var/run}
PID_FILE=${SURICATA_PID_FILE:-$RUN_DIR/suricata.pid}
CONFIG_FILE=${SURICATA_CONFIG:-$ROOT_DIR/etc/suricata.yaml}
INTERFACE=$(detect_interface)

mkdir -p "$LOG_DIR" "$RUN_DIR"
umask 027

LIB_PATH=$ROOT_DIR/lib
if [ -d "$ROOT_DIR/lib/runtime" ]; then
  LIB_PATH=$ROOT_DIR/lib/runtime:$LIB_PATH
fi

if [ -n "${LD_LIBRARY_PATH:-}" ]; then
  LIB_PATH=$LIB_PATH:$LD_LIBRARY_PATH
fi
export LD_LIBRARY_PATH=$LIB_PATH

if [ "$(uname -s 2>/dev/null || printf Linux)" = "Darwin" ]; then
  DYLIB_PATH=$ROOT_DIR/lib
  if [ -d "$ROOT_DIR/lib/runtime" ]; then
    DYLIB_PATH=$ROOT_DIR/lib/runtime:$DYLIB_PATH
  fi
  if [ -n "${DYLD_LIBRARY_PATH:-}" ]; then
    DYLIB_PATH=$DYLIB_PATH:$DYLD_LIBRARY_PATH
  fi
  export DYLD_LIBRARY_PATH=$DYLIB_PATH
fi

if [ -n "${SURICATA_OPTIONS:-}" ]; then
  # shellcheck disable=SC2086
  exec "$ROOT_DIR/bin/suricata" -c "$CONFIG_FILE" --pidfile "$PID_FILE" -l "$LOG_DIR" -i "$INTERFACE" $SURICATA_OPTIONS "$@"
fi

exec "$ROOT_DIR/bin/suricata" -c "$CONFIG_FILE" --pidfile "$PID_FILE" -l "$LOG_DIR" -i "$INTERFACE" "$@"
