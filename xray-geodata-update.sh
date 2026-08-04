#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DAT_DIR="/usr/local/share/xray"
LOG="/var/log/xray-geodata-update.log"
LOCK="/var/run/xray-geodata.lock"

GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

need_root() { [[ ${EUID:-99999} -eq 0 ]]; }

calc_hash() { [[ -f "$1" ]] && sha256sum "$1" | awk '{print $1}' || echo "none"; }

cleanup() {
  rm -f \
    "$DAT_DIR/geoip.dat.new" "$DAT_DIR/geosite.dat.new" \
    "$DAT_DIR/geoip.dat.sha256sum.new" "$DAT_DIR/geosite.dat.sha256sum.new"
}
trap cleanup EXIT INT TERM

download_and_verify_to_new() {
  local url="$1"         # .../geoip.dat
  local newfile="$2"     # .../geoip.dat.new
  local sumfile="$3"     # .../geoip.dat.sha256sum.new

  curl -fsSL --retry 3 --max-time 120 -o "$newfile" "$url"
  curl -fsSL --retry 3 --max-time 20  -o "$sumfile" "${url}.sha256sum"

  # 让 sha256sum 文件中的“文件名”匹配 *.new 的 basename
  sed -i "s|  .*|  $(basename "$newfile")|" "$sumfile"

  (cd "$(dirname "$newfile")" && sha256sum -c --status "$(basename "$sumfile")")
}

if ! need_root; then
  echo "Error: must run as root." >&2
  exit 1
fi

mkdir -p "$DAT_DIR" "$(dirname "$LOG")"

exec 9>"$LOCK"
flock -n 9 || exit 0

{
  echo "===== $(date -Is) start ====="

  old_geoip="$(calc_hash "$DAT_DIR/geoip.dat")"
  old_geosite="$(calc_hash "$DAT_DIR/geosite.dat")"
  echo "Old geoip:   $old_geoip"
  echo "Old geosite: $old_geosite"

  # 阶段 1：两者都下载 + 校验到 .new；任意失败会触发 set -e 直接退出，且不会替换旧文件
  echo "Downloading+verifying geoip.dat ..."
  download_and_verify_to_new "$GEOIP_URL" \
    "$DAT_DIR/geoip.dat.new" \
    "$DAT_DIR/geoip.dat.sha256sum.new"

  echo "Downloading+verifying geosite.dat ..."
  download_and_verify_to_new "$GEOSITE_URL" \
    "$DAT_DIR/geosite.dat.new" \
    "$DAT_DIR/geosite.dat.sha256sum.new"

  # 计算 new 的 hash，用于判断是否需要提交/重启
  new_geoip="$(calc_hash "$DAT_DIR/geoip.dat.new")"
  new_geosite="$(calc_hash "$DAT_DIR/geosite.dat.new")"
  echo "New geoip:   $new_geoip"
  echo "New geosite: $new_geosite"

  changed=0
  [[ "$old_geoip" != "$new_geoip" ]] && changed=1
  [[ "$old_geosite" != "$new_geosite" ]] && changed=1

  if [[ $changed -eq 1 ]]; then
    echo "Change detected -> committing files + restarting xray"

    # 阶段 2：一起提交（同目录 mv 一般是原子替换）
    mv -f "$DAT_DIR/geoip.dat.new"   "$DAT_DIR/geoip.dat"
    mv -f "$DAT_DIR/geosite.dat.new" "$DAT_DIR/geosite.dat"

    systemctl restart xray
  else
    echo "No change -> keep existing files, no restart"
  fi

  echo "===== $(date -Is) done ====="
} >>"$LOG" 2>&1
