#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=./common.sh
source "$(CDPATH= cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)/common.sh"

ROOT_DIR="$(repo_root "$SCRIPT_PATH")"
RELEASE_NAME="${RELEASE_NAME:?RELEASE_NAME is required}"
RUST_TARGET="${RUST_TARGET:?RUST_TARGET is required}"
OPENWRT_TARGET="${OPENWRT_TARGET:?OPENWRT_TARGET is required}"
OPENWRT_SUBTARGET="${OPENWRT_SUBTARGET:?OPENWRT_SUBTARGET is required}"
OPENWRT_VERSION="${OPENWRT_VERSION:-23.05.5}"
OPENWRT_BASE_URL="${OPENWRT_BASE_URL:-https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/suricata/current}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist-release}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.release-work/$RELEASE_NAME}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$ROOT_DIR/.release-downloads}"
MAKE_JOBS="${MAKE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
TARGET_CFLAGS="${TARGET_CFLAGS:--Os -pipe}"
TARGET_LDFLAGS="${TARGET_LDFLAGS:-}"
RUST_ENV_PREFIX="$(printf '%s' "$RUST_TARGET" | tr '[:lower:]-' '[:upper:]_')"

ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
LIBYAML_VERSION="${LIBYAML_VERSION:-0.2.5}"
JANSSON_VERSION="${JANSSON_VERSION:-2.14}"
PCRE2_VERSION="${PCRE2_VERSION:-10.45}"
LIBPCAP_VERSION="${LIBPCAP_VERSION:-1.10.5}"

need_cmd curl
need_cmd tar
need_cmd make
need_cmd python3
need_cmd cargo
need_cmd pkg-config
need_cmd rustup
need_cmd rustc

mkdir -p "$OUTPUT_DIR" "$WORK_DIR" "$DOWNLOAD_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/src" "$WORK_DIR/build" "$WORK_DIR/rootfs" "$WORK_DIR/bundle" "$WORK_DIR/sysroot"

download_once() {
  local url="$1"
  local dest="$2"
  if [ ! -f "$dest" ]; then
    log "Downloading $(basename "$dest")"
    curl -fL "$url" -o "$dest"
  fi
}

extract_archive() {
  local archive="$1"
  local dest="$2"
  rm -rf "$dest"
  mkdir -p "$dest"
  case "$archive" in
    *.tar.zst|*.tzst)
      tar --zstd -xf "$archive" -C "$dest"
      ;;
    *)
      tar -xf "$archive" -C "$dest"
      ;;
  esac
}

resolve_openwrt_toolchain_filename() {
  local sums_file="$1"
  python3 - "$sums_file" "$OPENWRT_TARGET" "$OPENWRT_SUBTARGET" <<'PY'
import re
import sys

path, target, subtarget = sys.argv[1:]
regex = re.compile(rf"openwrt-toolchain-.*-{re.escape(target)}-{re.escape(subtarget)}_gcc-.*_musl\.Linux-x86_64\.tar\.(?:xz|zst)$")
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        parts = line.strip().split()
        if len(parts) >= 2 and regex.search(parts[-1]):
            print(parts[-1])
            sys.exit(0)
raise SystemExit("Unable to locate OpenWrt toolchain filename in sha256sums")
PY
}

prepare_toolchain() {
  local sums_file="$DOWNLOAD_DIR/openwrt-${OPENWRT_TARGET}-${OPENWRT_SUBTARGET}-sha256sums"
  local archive_name archive_path extract_dir gcc_path

  download_once "$OPENWRT_BASE_URL/sha256sums" "$sums_file"
  archive_name="$(resolve_openwrt_toolchain_filename "$sums_file")"
  archive_path="$DOWNLOAD_DIR/$archive_name"
  download_once "$OPENWRT_BASE_URL/$archive_name" "$archive_path"

  extract_dir="$WORK_DIR/toolchain"
  extract_archive "$archive_path" "$extract_dir"
  gcc_path="$(python3 - "$extract_dir" <<'PY'
import os
import sys

root = sys.argv[1]
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        if name.endswith("-gcc"):
            print(os.path.join(dirpath, name))
            raise SystemExit(0)
raise SystemExit("Unable to locate OpenWrt cross compiler")
PY
)"

  TOOLCHAIN_BIN_DIR="$(dirname "$gcc_path")"
  TARGET_CC="$gcc_path"
  TARGET_PREFIX="${TARGET_CC%-gcc}"
  TARGET_CXX="${TARGET_PREFIX}-g++"
  TARGET_AR="${TARGET_PREFIX}-ar"
  TARGET_RANLIB="${TARGET_PREFIX}-ranlib"
  TARGET_STRIP="${TARGET_PREFIX}-strip"
  TARGET_READELF="${TARGET_PREFIX}-readelf"
  if ! command -v "$TARGET_READELF" >/dev/null 2>&1; then
    TARGET_READELF="readelf"
  fi
  TOOLCHAIN_SYSROOT="$("$TARGET_CC" -print-sysroot)"

  export PATH="$TOOLCHAIN_BIN_DIR:$PATH"
}

prepare_rust_target() {
  rustup target add "$RUST_TARGET"
  export CARGO_BUILD_TARGET="$RUST_TARGET"
  export "CC_${RUST_ENV_PREFIX}=$TARGET_CC"
  export "AR_${RUST_ENV_PREFIX}=$TARGET_AR"
  export "CARGO_TARGET_${RUST_ENV_PREFIX}_LINKER=$TARGET_CC"
  export "CARGO_TARGET_${RUST_ENV_PREFIX}_AR=$TARGET_AR"
  export RUSTFLAGS="${RUSTFLAGS:-} -Clink-self-contained=no"
}

dep_env_common() {
  export CC="$TARGET_CC"
  export CXX="$TARGET_CXX"
  export AR="$TARGET_AR"
  export RANLIB="$TARGET_RANLIB"
  export STRIP="$TARGET_STRIP"
  export CFLAGS="$TARGET_CFLAGS --sysroot=$TOOLCHAIN_SYSROOT"
  export CXXFLAGS="$TARGET_CFLAGS --sysroot=$TOOLCHAIN_SYSROOT"
  export CPPFLAGS="--sysroot=$TOOLCHAIN_SYSROOT -I$WORK_DIR/sysroot/usr/include"
  export LDFLAGS="${TARGET_LDFLAGS} --sysroot=$TOOLCHAIN_SYSROOT -L$WORK_DIR/sysroot/usr/lib"
  export PKG_CONFIG_SYSROOT_DIR="$WORK_DIR/sysroot"
  export PKG_CONFIG_LIBDIR="$WORK_DIR/sysroot/usr/lib/pkgconfig:$WORK_DIR/sysroot/usr/share/pkgconfig"
  export PKG_CONFIG_PATH=
  export PKG_CONFIG="pkg-config --static"
}

fetch_source() {
  local url="$1"
  local archive_name="$2"
  local archive_path="$DOWNLOAD_DIR/$archive_name"
  download_once "$url" "$archive_path"
  extract_archive "$archive_path" "$WORK_DIR/src/$archive_name.dir"
}

first_source_dir() {
  local root="$1"
  python3 - "$root" <<'PY'
import os
import sys

root = sys.argv[1]
for entry in os.listdir(root):
    path = os.path.join(root, entry)
    if os.path.isdir(path):
        print(path)
        raise SystemExit(0)
raise SystemExit(f"No source directory found in {root}")
PY
}

build_zlib() {
  local archive="zlib-${ZLIB_VERSION}.tar.gz"
  local src_root="$WORK_DIR/src/$archive.dir"
  local src_dir

  fetch_source "https://zlib.net/${archive}" "$archive"
  src_dir="$(first_source_dir "$src_root")"
  dep_env_common
  (
    cd "$src_dir"
    CHOST="$RUST_TARGET" ./configure --prefix=/usr --static
    make -j "$MAKE_JOBS"
    make install DESTDIR="$WORK_DIR/sysroot"
  )
}

build_libyaml() {
  local archive="yaml-${LIBYAML_VERSION}.tar.gz"
  local src_root="$WORK_DIR/src/$archive.dir"
  local src_dir

  fetch_source "https://pyyaml.org/download/libyaml/${archive}" "$archive"
  src_dir="$(first_source_dir "$src_root")"
  dep_env_common
  (
    cd "$src_dir"
    ./configure --host="$RUST_TARGET" --prefix=/usr --disable-shared --enable-static
    make -j "$MAKE_JOBS"
    make install DESTDIR="$WORK_DIR/sysroot"
  )
}

build_jansson() {
  local archive="jansson-${JANSSON_VERSION}.tar.gz"
  local src_root="$WORK_DIR/src/$archive.dir"
  local src_dir

  fetch_source "https://github.com/akheron/jansson/releases/download/v${JANSSON_VERSION}/${archive}" "$archive"
  src_dir="$(first_source_dir "$src_root")"
  dep_env_common
  (
    cd "$src_dir"
    ./configure --host="$RUST_TARGET" --prefix=/usr --disable-shared --enable-static
    make -j "$MAKE_JOBS"
    make install DESTDIR="$WORK_DIR/sysroot"
  )
}

build_pcre2() {
  local archive="pcre2-${PCRE2_VERSION}.tar.gz"
  local src_root="$WORK_DIR/src/$archive.dir"
  local src_dir

  fetch_source "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/${archive}" "$archive"
  src_dir="$(first_source_dir "$src_root")"
  dep_env_common
  (
    cd "$src_dir"
    ./configure \
      --host="$RUST_TARGET" \
      --prefix=/usr \
      --disable-shared \
      --enable-static \
      --disable-pcre2-16 \
      --disable-pcre2-32 \
      --disable-jit
    make -j "$MAKE_JOBS"
    make install DESTDIR="$WORK_DIR/sysroot"
  )
}

build_libpcap() {
  local archive="libpcap-${LIBPCAP_VERSION}.tar.gz"
  local src_root="$WORK_DIR/src/$archive.dir"
  local src_dir

  fetch_source "https://www.tcpdump.org/release/${archive}" "$archive"
  src_dir="$(first_source_dir "$src_root")"
  dep_env_common
  (
    cd "$src_dir"
    ./configure \
      --host="$RUST_TARGET" \
      --prefix=/usr \
      --disable-shared \
      --enable-static \
      --with-pcap=linux \
      --without-libnl \
      --disable-bluetooth \
      --disable-dbus \
      --disable-rdma
    make -j "$MAKE_JOBS"
    make install DESTDIR="$WORK_DIR/sysroot"
  )
}

configure_suricata_env() {
  export CC="$TARGET_CC"
  export CXX="$TARGET_CXX"
  export AR="$TARGET_AR"
  export RANLIB="$TARGET_RANLIB"
  export STRIP="$TARGET_STRIP"
  export READELF="$TARGET_READELF"
  export PKG_CONFIG_SYSROOT_DIR="$WORK_DIR/sysroot"
  export PKG_CONFIG_LIBDIR="$WORK_DIR/sysroot/usr/lib/pkgconfig:$WORK_DIR/sysroot/usr/share/pkgconfig"
  export PKG_CONFIG_PATH=
  export PKG_CONFIG="pkg-config --static"
  export CPPFLAGS="--sysroot=$TOOLCHAIN_SYSROOT -I$WORK_DIR/sysroot/usr/include"
  export CFLAGS="$TARGET_CFLAGS --sysroot=$TOOLCHAIN_SYSROOT -I$WORK_DIR/sysroot/usr/include"
  export CXXFLAGS="$TARGET_CFLAGS --sysroot=$TOOLCHAIN_SYSROOT -I$WORK_DIR/sysroot/usr/include"
  export LDFLAGS="${TARGET_LDFLAGS} --sysroot=$TOOLCHAIN_SYSROOT -L$WORK_DIR/sysroot/usr/lib"
}

copy_needed_runtime_libs() {
  local bundle_dir="$1"
  local binary needed lib candidate

  mkdir -p "$bundle_dir/lib/runtime"
  for binary in "$bundle_dir/bin/suricata" "$bundle_dir/bin/suricatasc" "$bundle_dir/bin/suricatactl"; do
    [ -e "$binary" ] || continue
    while IFS= read -r needed; do
      [ -n "$needed" ] || continue
      case "$needed" in
        libc.so.*|ld-musl-*.so.*) continue ;;
      esac
      for candidate in \
        "$WORK_DIR/sysroot/usr/lib/$needed" \
        "$TOOLCHAIN_SYSROOT/usr/lib/$needed" \
        "$TOOLCHAIN_SYSROOT/lib/$needed"; do
        if [ -e "$candidate" ]; then
          copy_dependency "$candidate" "$bundle_dir/lib/runtime"
          break
        fi
      done
    done < <("$READELF" -d "$binary" 2>/dev/null | awk -F'[][]' '/NEEDED/ { print $2 }' | sort -u)
  done
}

build_suricata() {
  local bundle_dir install_root

  configure_suricata_env
  (
    cd "$ROOT_DIR"
    ./autogen.sh
    ./configure \
      --host="$RUST_TARGET" \
      --prefix="$INSTALL_PREFIX" \
      --sysconfdir="$INSTALL_PREFIX/etc" \
      --localstatedir="$INSTALL_PREFIX/var" \
      --disable-python \
      --disable-suricata-update \
      --disable-gccmarch-native \
      --disable-gccprotect \
      --disable-unittests \
      --disable-shared \
      --disable-ebpf \
      --disable-af-xdp \
      --disable-nfqueue \
      --disable-nflog \
      --disable-netmap \
      --disable-dpdk \
      --disable-hwloc \
      --disable-hiredis \
      --disable-geoip \
      --disable-libmagic
    make -j "$MAKE_JOBS"
    make install install-conf DESTDIR="$WORK_DIR/rootfs"
  )

  bundle_dir="$WORK_DIR/bundle/$RELEASE_NAME"
  install_root="$WORK_DIR/rootfs$INSTALL_PREFIX"
  [ -d "$install_root" ] || die "Expected install root not found: $install_root"

  mkdir -p "$bundle_dir"
  cp -a "$install_root"/. "$bundle_dir"/
  mkdir -p "$bundle_dir/support/systemd" "$bundle_dir/support/openwrt" "$bundle_dir/support/env"
  cp -f "$ROOT_DIR/scripts/release/templates/suricata-start.sh" "$bundle_dir/bin/suricata-start"
  cp -f "$ROOT_DIR/scripts/release/templates/suricata.service" "$bundle_dir/support/systemd/suricata.service"
  cp -f "$ROOT_DIR/scripts/release/templates/suricata.openwrt.init" "$bundle_dir/support/openwrt/suricata-release"
  cp -f "$ROOT_DIR/scripts/release/templates/suricata-release.env" "$bundle_dir/support/env/suricata-release.env"
  chmod +x "$bundle_dir/bin/suricata-start" "$bundle_dir/support/openwrt/suricata-release"
  mkdir -p "$bundle_dir/var/log" "$bundle_dir/var/run"
  write_release_metadata "$bundle_dir" "$RELEASE_NAME" openwrt

  "$TARGET_STRIP" "$bundle_dir/bin/suricata" || true
  [ -e "$bundle_dir/bin/suricatasc" ] && "$TARGET_STRIP" "$bundle_dir/bin/suricatasc" || true
  [ -e "$bundle_dir/bin/suricatactl" ] && "$TARGET_STRIP" "$bundle_dir/bin/suricatactl" || true

  copy_needed_runtime_libs "$bundle_dir"
  tar -C "$WORK_DIR/bundle" -czf "$OUTPUT_DIR/${RELEASE_NAME}.tar.gz" "$RELEASE_NAME"
}

log "Preparing OpenWrt toolchain"
prepare_toolchain
prepare_rust_target

log "Building OpenWrt dependency chain"
build_zlib
build_libyaml
build_jansson
build_pcre2
build_libpcap

log "Building Suricata for OpenWrt"
build_suricata
log "Created package in $OUTPUT_DIR"
