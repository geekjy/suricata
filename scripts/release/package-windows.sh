#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=./common.sh
source "$(CDPATH= cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)/common.sh"

ROOT_DIR="$(repo_root "$SCRIPT_PATH")"
RELEASE_NAME="${RELEASE_NAME:?RELEASE_NAME is required}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/suricata/current}"
MAKE_JOBS="${MAKE_JOBS:-3}"
CONFIGURE_ARGS="${CONFIGURE_ARGS:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist-release}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.release-work/$RELEASE_NAME}"

need_cmd make
need_cmd zip
need_cmd ldd

mkdir -p "$OUTPUT_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/rootfs" "$WORK_DIR/bundle"

log "Building ${RELEASE_NAME}"
( cd "$ROOT_DIR" && ./autogen.sh )
( cd "$ROOT_DIR" && ./configure \
    --prefix="$INSTALL_PREFIX" \
    --sysconfdir="$INSTALL_PREFIX/etc" \
    --localstatedir="$INSTALL_PREFIX/var" \
    $CONFIGURE_ARGS )
( cd "$ROOT_DIR" && make -j "$MAKE_JOBS" )
( cd "$ROOT_DIR" && make install install-conf DESTDIR="$WORK_DIR/rootfs" )

BUNDLE_DIR="$WORK_DIR/bundle/$RELEASE_NAME"
INSTALL_ROOT="$WORK_DIR/rootfs$INSTALL_PREFIX"
[ -d "$INSTALL_ROOT" ] || die "Expected install root not found: $INSTALL_ROOT"

mkdir -p "$BUNDLE_DIR"
cp -a "$INSTALL_ROOT"/. "$BUNDLE_DIR"/

write_release_metadata "$BUNDLE_DIR" "$RELEASE_NAME" windows

dep_targets=()
dep_targets+=("$BUNDLE_DIR/bin/suricata.exe")
append_glob_matches dep_targets "$BUNDLE_DIR/lib/*.dll"
append_glob_matches dep_targets "$BUNDLE_DIR/bin/*.dll"
collect_windows_deps "$BUNDLE_DIR" "${dep_targets[@]}"

cat > "$BUNDLE_DIR/suricata.cmd" <<'EOF'
@echo off
setlocal
set "ROOT=%~dp0"
set "PATH=%ROOT%bin;%PATH%"
"%ROOT%bin\suricata.exe" %*
EOF

(
  cd "$WORK_DIR/bundle"
  zip -qry "$OUTPUT_DIR/${RELEASE_NAME}.zip" "$RELEASE_NAME"
)

log "Created package in $OUTPUT_DIR"
