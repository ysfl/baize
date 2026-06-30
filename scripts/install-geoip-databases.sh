#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${GEOIP_DATA_DIR:-$ROOT_DIR/runtime/geoip}"
DBIP_MONTH="${GEOIP_DBIP_MONTH:-$(date -u +%Y-%m)}"
DBIP_BASE_URL="${GEOIP_DBIP_BASE_URL:-https://download.db-ip.com/free}"

log() {
  echo "[install-geoip] $*" >&2
}

die() {
  echo "[install-geoip] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/install-geoip-databases.sh

环境变量:
  GEOIP_DATA_DIR      数据目录，默认 runtime/geoip
  GEOIP_DBIP_MONTH    DB-IP Lite 月份，默认当前 UTC 月份，例如 2026-06
  GEOIP_DBIP_BASE_URL 下载来源，默认 https://download.db-ip.com/free
  GEOIP_OFFLINE_BACKFILL_ONLY
                    只使用本地已有 .mmdb 或 .mmdb.gz 回填，不联网下载

English:
  Download DB-IP Lite City and ASN databases into runtime/geoip and create the
  stable filenames used by the Baize container. Set GEOIP_OFFLINE_BACKFILL_ONLY=true
  to relink existing local files without downloading.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path"
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path"
    return
  fi
  die "缺少 shasum 或 sha256sum"
}

install_database() {
  local edition="$1"
  local stable_name="$2"
  local url="$DBIP_BASE_URL/${edition}-${DBIP_MONTH}.mmdb.gz"
  local archive_path="$DATA_DIR/${edition}-${DBIP_MONTH}.mmdb.gz"
  local versioned_path="$DATA_DIR/${edition}-${DBIP_MONTH}.mmdb"
  local stable_path="$DATA_DIR/${stable_name}.mmdb"
  local archive_tmp="${archive_path}.tmp"
  local db_tmp="${versioned_path}.tmp"
  local offline_only="${GEOIP_OFFLINE_BACKFILL_ONLY:-false}"

  if [[ -s "$versioned_path" ]]; then
    log "复用本地数据库 ${versioned_path}"
  else
    if [[ -s "$archive_path" ]]; then
      log "使用本地压缩包回填 ${archive_path}"
      gzip -t "$archive_path"
      gzip -dc "$archive_path" >"$db_tmp"
    else
      case "$offline_only" in
        true|TRUE|1|yes|YES|on|ON)
          die "未找到本地 ${versioned_path} 或 ${archive_path}，无法离线回填"
          ;;
      esac
      require_cmd curl
      log "下载 ${edition} ${DBIP_MONTH}: ${url}"
      curl --fail --location --retry 3 --connect-timeout 10 --output "$archive_tmp" "$url"
      gzip -t "$archive_tmp"
      gzip -dc "$archive_tmp" >"$db_tmp"
      mv "$archive_tmp" "$archive_path"
    fi
    [[ -s "$db_tmp" ]] || die "数据库结果为空: $versioned_path"
    mv "$db_tmp" "$versioned_path"
  fi

  sha256_file "$versioned_path" >"${versioned_path}.sha256"
  ln -sfn "$(basename "$versioned_path")" "$stable_path"
  log "已安装 ${stable_path} -> $(basename "$versioned_path")"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_cmd gzip
  mkdir -p "$DATA_DIR"

  install_database "dbip-city-lite" "dbip-city-lite"
  install_database "dbip-asn-lite" "dbip-asn-lite"

  cat <<EOF
[install-geoip] 完成
数据目录: $DATA_DIR
City 库: $DATA_DIR/dbip-city-lite.mmdb
ASN  库: $DATA_DIR/dbip-asn-lite.mmdb

如果服务已经在运行，请重启中心服务:
  docker compose restart server
EOF
}

main "$@"
