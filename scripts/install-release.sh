#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-OISF/suricata}"
RELEASE_TAG="${RELEASE_TAG:-}"
ASSET_URL="${ASSET_URL:-}"
INSTALL_BASE="${INSTALL_BASE:-/opt/suricata}"
STATE_DIR="${STATE_DIR:-/var/lib/suricata-release-installer}"
ENV_FILE="${ENV_FILE:-/etc/default/suricata-release}"
SYSTEMD_SERVICE_FILE="${SYSTEMD_SERVICE_FILE:-/etc/systemd/system/suricata-release.service}"
OPENWRT_INIT_FILE="${OPENWRT_INIT_FILE:-/etc/init.d/suricata-release}"

log() {
  printf '[suricata-install] %s\n' "$*"
}

die() {
  printf '[suricata-install] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Please run as root."
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x86_64\n' ;;
    aarch64|arm64) printf 'aarch64\n' ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

detect_distro() {
  [ -r /etc/os-release ] || die "/etc/os-release is required."
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    openwrt) printf 'openwrt\n' ;;
    ubuntu) printf 'linux-ubuntu\n' ;;
    almalinux) printf 'linux-almalinux\n' ;;
    centos|centos-stream) printf 'linux-centos\n' ;;
    *)
      case " ${ID_LIKE:-} " in
        *" openwrt "*) printf 'openwrt\n' ;;
        *" debian "*) printf 'linux-ubuntu\n' ;;
        *" rhel "*) printf 'linux-almalinux\n' ;;
        *) die "Unsupported distribution: ${ID:-unknown}" ;;
      esac
      ;;
  esac
}

asset_name_for_host() {
  local distro="$1"
  local arch="$2"

  case "$distro" in
    openwrt) printf 'suricata-openwrt-%s.tar.gz\n' "$arch" ;;
    linux-ubuntu|linux-almalinux|linux-centos) printf 'suricata-%s-%s.tar.gz\n' "$distro" "$arch" ;;
    *) die "Unsupported distro mapping: $distro" ;;
  esac
}

download_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$output"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -O "$output" "$url"
    return 0
  fi

  die "Missing downloader: curl or wget"
}

backup_target() {
  local target="$1"
  local backup_root="$STATE_DIR/backup"

  if [ -e "$target" ] || [ -L "$target" ]; then
    mkdir -p "$backup_root$(dirname "$target")"
    cp -a "$target" "$backup_root$target"
  fi
}

install_env_file() {
  local bundle_dir="$1"

  mkdir -p "$(dirname "$ENV_FILE")"
  if [ ! -e "$ENV_FILE" ]; then
    cp -f "$bundle_dir/support/env/suricata-release.env" "$ENV_FILE"
  fi
}

install_systemd_service() {
  local bundle_dir="$1"

  need_cmd systemctl
  backup_target "$SYSTEMD_SERVICE_FILE"
  cp -f "$bundle_dir/support/systemd/suricata.service" "$SYSTEMD_SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable --now suricata-release.service
}

install_openwrt_service() {
  local bundle_dir="$1"

  backup_target "$OPENWRT_INIT_FILE"
  cp -f "$bundle_dir/support/openwrt/suricata-release" "$OPENWRT_INIT_FILE"
  chmod +x "$OPENWRT_INIT_FILE"
  "$OPENWRT_INIT_FILE" enable
  "$OPENWRT_INIT_FILE" restart
}

main() {
  require_root
  need_cmd tar

  local distro arch asset_name asset_url tmp extract_dir bundle_dir
  local install_root install_id install_dir current_link meta_file

  distro="$(detect_distro)"
  arch="$(detect_arch)"
  asset_name="$(asset_name_for_host "$distro" "$arch")"

  if [ -n "$ASSET_URL" ]; then
    asset_url="$ASSET_URL"
  elif [ -n "$RELEASE_TAG" ]; then
    asset_url="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${asset_name}"
  else
    asset_url="https://github.com/${REPO}/releases/latest/download/${asset_name}"
  fi

  log "Detected target: distro=${distro} arch=${arch}"
  log "Downloading asset: ${asset_url}"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$STATE_DIR"
  download_file "$asset_url" "$tmp/package.tar.gz"

  extract_dir="$tmp/extract"
  mkdir -p "$extract_dir"
  tar -xzf "$tmp/package.tar.gz" -C "$extract_dir"
  bundle_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -n "$bundle_dir" ] || die "Unexpected archive layout."
  [ -x "$bundle_dir/bin/suricata-start" ] || die "suricata-start not found in package."

  install_root="$INSTALL_BASE/releases"
  current_link="$INSTALL_BASE/current"
  install_id="${RELEASE_TAG:-$(date +%Y%m%d%H%M%S)}-$(basename "$bundle_dir")"
  install_dir="$install_root/$install_id"
  meta_file="$STATE_DIR/install.env"

  mkdir -p "$install_root" /usr/local/bin
  backup_target "$current_link"
  backup_target /usr/local/bin/suricata-release

  rm -rf "$install_dir"
  cp -a "$bundle_dir" "$install_dir"
  ln -sfn "$install_dir" "$current_link"
  ln -sfn "$current_link/bin/suricata-start" /usr/local/bin/suricata-release

  install_env_file "$install_dir"
  case "$distro" in
    openwrt)
      install_openwrt_service "$install_dir"
      ;;
    *)
      install_systemd_service "$install_dir"
      ;;
  esac

  cat > "$meta_file" <<EOF
REPO=${REPO}
DISTRO=${distro}
ARCH=${arch}
ASSET_NAME=${asset_name}
ASSET_URL=${asset_url}
INSTALL_DIR=${install_dir}
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  log "Installed into ${install_dir}"
  case "$distro" in
    openwrt)
      log "Service: /etc/init.d/suricata-release {start|stop|restart|status}"
      ;;
    *)
      log "Service: systemctl {start|stop|restart|status} suricata-release"
      ;;
  esac
}

main "$@"
