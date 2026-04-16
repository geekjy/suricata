#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=./common.sh
source "$(CDPATH= cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)/common.sh"

ROOT_DIR="$(repo_root "$SCRIPT_PATH")"
RELEASE_NAME="${RELEASE_NAME:?RELEASE_NAME is required}"
PLATFORM_FAMILY="${PLATFORM_FAMILY:-linux}"
ARCHIVE_FORMAT="${ARCHIVE_FORMAT:-tar.gz}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/suricata/current}"
MAKE_JOBS="${MAKE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
CONFIGURE_ARGS="${CONFIGURE_ARGS:-}"
INSTALL_TARGETS="${INSTALL_TARGETS:-install install-conf install-library}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist-release}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.release-work/$RELEASE_NAME}"
COLLECT_DEPS="${COLLECT_DEPS:-yes}"
CONFIGURE_ENV="${CONFIGURE_ENV:-}"
MAKE_ENV="${MAKE_ENV:-}"
INSTALL_ENV="${INSTALL_ENV:-}"

need_cmd make
need_cmd tar
need_cmd cp

mkdir -p "$OUTPUT_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/rootfs" "$WORK_DIR/bundle"

log "Building ${RELEASE_NAME}"
( cd "$ROOT_DIR" && ./autogen.sh )
if [ -n "$CONFIGURE_ENV" ]; then
  (
    cd "$ROOT_DIR" &&
    eval "$CONFIGURE_ENV ./configure --prefix=\"$INSTALL_PREFIX\" --sysconfdir=\"$INSTALL_PREFIX/etc\" --localstatedir=\"$INSTALL_PREFIX/var\" $CONFIGURE_ARGS"
  )
else
  (
    cd "$ROOT_DIR" &&
    ./configure \
      --prefix="$INSTALL_PREFIX" \
      --sysconfdir="$INSTALL_PREFIX/etc" \
      --localstatedir="$INSTALL_PREFIX/var" \
      $CONFIGURE_ARGS
  )
fi

if [ -n "$MAKE_ENV" ]; then
  (
    cd "$ROOT_DIR" &&
    eval "$MAKE_ENV make -j \"$MAKE_JOBS\""
  )
else
  ( cd "$ROOT_DIR" && make -j "$MAKE_JOBS" )
fi

if [ -n "$INSTALL_ENV" ]; then
  (
    cd "$ROOT_DIR" &&
    eval "$INSTALL_ENV make $INSTALL_TARGETS DESTDIR=\"$WORK_DIR/rootfs\""
  )
else
  ( cd "$ROOT_DIR" && make $INSTALL_TARGETS DESTDIR="$WORK_DIR/rootfs" )
fi

BUNDLE_DIR="$WORK_DIR/bundle/$RELEASE_NAME"
INSTALL_ROOT="$WORK_DIR/rootfs$INSTALL_PREFIX"
[ -d "$INSTALL_ROOT" ] || die "Expected install root not found: $INSTALL_ROOT"

mkdir -p "$BUNDLE_DIR"
cp -a "$INSTALL_ROOT"/. "$BUNDLE_DIR"/

mkdir -p "$BUNDLE_DIR/support/systemd" "$BUNDLE_DIR/support/openwrt" "$BUNDLE_DIR/support/env"
cp -f "$ROOT_DIR/scripts/release/templates/suricata-start.sh" "$BUNDLE_DIR/bin/suricata-start"
cp -f "$ROOT_DIR/scripts/release/templates/suricata.service" "$BUNDLE_DIR/support/systemd/suricata.service"
cp -f "$ROOT_DIR/scripts/release/templates/suricata.openwrt.init" "$BUNDLE_DIR/support/openwrt/suricata-release"
cp -f "$ROOT_DIR/scripts/release/templates/suricata-release.env" "$BUNDLE_DIR/support/env/suricata-release.env"
chmod +x "$BUNDLE_DIR/bin/suricata-start" "$BUNDLE_DIR/support/openwrt/suricata-release"

mkdir -p "$BUNDLE_DIR/var/log" "$BUNDLE_DIR/var/run"
write_release_metadata "$BUNDLE_DIR" "$RELEASE_NAME" "$PLATFORM_FAMILY"

if [ "$COLLECT_DEPS" = "yes" ]; then
  dep_targets=()
  dep_targets+=("$BUNDLE_DIR/bin/suricata")
  [ -e "$BUNDLE_DIR/bin/suricatasc" ] && dep_targets+=("$BUNDLE_DIR/bin/suricatasc")
  append_glob_matches dep_targets "$BUNDLE_DIR/lib/*.so*"
  append_glob_matches dep_targets "$BUNDLE_DIR/lib/suricata/*.so*"

  case "$(uname -s)" in
    Darwin)
      collect_macos_deps "$BUNDLE_DIR" "${dep_targets[@]}"
      ;;
    *)
      collect_linux_deps "$BUNDLE_DIR" "${dep_targets[@]}"
      ;;
  esac
fi

case "$ARCHIVE_FORMAT" in
  tar.gz)
    tar -C "$WORK_DIR/bundle" -czf "$OUTPUT_DIR/${RELEASE_NAME}.tar.gz" "$RELEASE_NAME"
    ;;
  zip)
    need_cmd zip
    (
      cd "$WORK_DIR/bundle"
      zip -qry "$OUTPUT_DIR/${RELEASE_NAME}.zip" "$RELEASE_NAME"
    )
    ;;
  *)
    die "Unsupported archive format: $ARCHIVE_FORMAT"
    ;;
esac

log "Created package in $OUTPUT_DIR"
