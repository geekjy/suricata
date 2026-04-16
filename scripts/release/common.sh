#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[release] %s\n' "$*"
}

die() {
  printf '[release] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

script_dir() {
  CDPATH= cd -- "$(dirname -- "$1")" && pwd
}

repo_root() {
  local dir
  dir="$(script_dir "$1")"
  CDPATH= cd -- "$dir/../.." && pwd
}

host_arch() {
  case "${1:-$(uname -m)}" in
    x86_64|amd64) printf 'x86_64\n' ;;
    aarch64|arm64) printf 'aarch64\n' ;;
    armv7l|armv7) printf 'armv7\n' ;;
    *) printf '%s\n' "${1:-$(uname -m)}" ;;
  esac
}

copy_dependency() {
  local src="$1"
  local dest_dir="$2"
  local base target

  [ -e "$src" ] || return 0
  mkdir -p "$dest_dir"
  base="$(basename "$src")"

  if [ -L "$src" ]; then
    cp -af "$src" "$dest_dir/$base"
    target="$(readlink -f "$src" || true)"
    if [ -n "$target" ] && [ -e "$target" ]; then
      cp -af "$target" "$dest_dir/$(basename "$target")"
    fi
    return 0
  fi

  cp -af "$src" "$dest_dir/$base"
}

append_glob_matches() {
  local array_name="$1"
  local pattern="$2"
  local match

  while IFS= read -r match; do
    eval "$array_name+=(\"\$match\")"
  done < <(compgen -G "$pattern" || true)
}

collect_linux_deps() {
  local bundle_dir="$1"
  shift

  local dest_dir="$bundle_dir/lib/runtime"
  local target dep

  need_cmd ldd
  mkdir -p "$dest_dir"

  for target in "$@"; do
    [ -e "$target" ] || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      case "$dep" in
        "$bundle_dir"/*) continue ;;
        /lib/*|/lib64/*) continue ;;
        linux-vdso.so.*) continue ;;
        */ld-linux*.so*|*/ld-musl-*.so*|*/ld64.so*) continue ;;
      esac
      copy_dependency "$dep" "$dest_dir"
    done < <(ldd "$target" 2>/dev/null | awk '
      $2 == "=>" && $3 ~ /^\// { print $3 }
      $1 ~ /^\// { print $1 }
    ' | sort -u)
  done
}

collect_macos_deps() {
  local bundle_dir="$1"
  shift

  local dest_dir="$bundle_dir/lib/runtime"
  local target dep

  need_cmd otool
  mkdir -p "$dest_dir"

  for target in "$@"; do
    [ -e "$target" ] || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      case "$dep" in
        "$bundle_dir"/*) continue ;;
        /System/*|/usr/lib/*) continue ;;
      esac
      copy_dependency "$dep" "$dest_dir"
    done < <(otool -L "$target" | awk 'NR > 1 && $1 ~ /^\// { print $1 }' | sort -u)
  done
}

collect_windows_deps() {
  local bundle_dir="$1"
  shift

  local dest_dir="$bundle_dir/bin"
  local target dep

  need_cmd ldd
  mkdir -p "$dest_dir"

  for target in "$@"; do
    [ -e "$target" ] || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      case "$dep" in
        "$bundle_dir"/*) continue ;;
        *'/Windows/'*) continue ;;
      esac
      copy_dependency "$dep" "$dest_dir"
    done < <(ldd "$target" 2>/dev/null | awk '
      $2 == "=>" && $3 ~ /^\// { print $3 }
      $1 ~ /^\// { print $1 }
    ' | sort -u)
  done
}

write_release_metadata() {
  local bundle_dir="$1"
  local release_name="$2"
  local platform="$3"

  cat > "$bundle_dir/RELEASE-METADATA.txt" <<EOF
release_name=${release_name}
platform=${platform}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}
