#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then echo "请使用 root 用户运行此脚本。"; exit 1; fi
if ! command -v apt-get >/dev/null 2>&1; then echo "当前脚本仅支持 Debian / Ubuntu。"; exit 1; fi
if ! command -v systemctl >/dev/null 2>&1; then echo "未检测到 systemctl，当前脚本需要标准 Debian / Ubuntu VPS。"; exit 1; fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates jq tar gzip coreutils grep sed gawk nginx >/dev/null
for c in curl jq tar gzip awk grep sed sort head wc cp mktemp seq nginx; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少命令：$c"; exit 1; }
done
command -v docker >/dev/null 2>&1 || { echo "未检测到 Docker，请先运行一键安装脚本。"; exit 1; }

INSTALL_URL="https://raw.githubusercontent.com/kkx999/Sub-Store-Tutorial/main/install.sh"
BACKUP_RESTART=""
BACKUP_PARTIAL=""
UP_NAME=""; UP_OLD=""; UP_BACKUP=""; UP_DATA=""; UP_WAS_RUNNING=0; UP_ACTIVE=0
RS_NAME=""; RS_DATA=""; RS_OLD=""; RS_STAGE=""; RS_WAS_RUNNING=0; RS_ACTIVE=0

running(){ [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = true ]; }
envv(){ docker inspect "$1" | jq -r --arg k "$2=" '.[0].Config.Env[]? | select(startswith($k)) | ltrimstr($k)' | head -n1; }
port(){ docker inspect "$1" | jq -r '.[0].HostConfig.PortBindings["3001/tcp"][0].HostPort // empty'; }
data(){ docker inspect "$1" | jq -r '.[0].Mounts[]? | select(.Destination=="/opt/app/data") | .Source' | head -n1; }
health(){
  local n="$1" p="$2" x="$3"
  for _ in $(seq 1 30); do running "$n" && curl -fsS --max-time 5 "http://127.0.0.1:$p$x/api/utils/env" >/dev/null 2>&1 && return 0; sleep 2; done
  return 1
}
instances(){
  mapfile -t INS < <(docker ps -a --format '{{.Names}}' | grep -E '^sub-store(-[0-9]+)?$' | sort -V || true)
  [ "${#INS[@]}" -gt 0 ] || { echo "没有检测到 Sub-Store。"; echo "安装：bash <(curl -fsSL $INSTALL_URL)"; exit 1; }
}
choose(){
  instances; echo; echo "检测到以下 Sub-Store："
  local i n s p x
  for i in "${!INS[@]}"; do n="${INS[$i]}"; s="已停止"; running "$n" && s="运行中"; p="$(port "$n")"; x="$(envv "$n" SUB_STORE_FRONTEND_BACKEND_PATH)"; echo "$((i+1))) $n  [$s]  端口:${p:-未知}  路径:${x:-未知}"; done
  read -rp "请选择实例编号: " N
  [[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -ge 1 ] && [ "$N" -le "${#INS[@]}" ] || { echo "实例编号无效。"; exit 1; }
  SEL="${INS[$((N-1))]}"
}

backup_cleanup(){ [ -n "$BACKUP_RESTART" ] && docker start "$BACKUP_RESTART" >/dev/null 2>&1 || true; [ -n "$BACKUP_PARTIAL" ] && rm -f "$BACKUP_PARTIAL" || true; }
make_backup(){
  local n="$1" d="$2" restart="${3:-1}" was=0 rc=0
  [ -d "$d" ] || { echo "数据目录不存在：$d"; return 1; }
  LAST_BACKUP="/root/${n}-backup-$(date +%Y%m%d-%H%M%S).tar.gz"; BACKUP_PARTIAL="$LAST_BACKUP"
  running "$n" && was=1
  trap backup_cleanup EXIT; trap 'exit 130' INT TERM
  [ "$was" -eq 0 ] || { BACKUP_RESTART="$n"; docker stop "$n" >/dev/null; }
  tar -czf "$LAST_BACKUP" -C "$d" . || rc=$?
  if [ "$was" -eq 1 ] && [ "$restart" -eq 1 ]; then docker start "$n" >/dev/null || { echo "备份后容器启动失败：$n"; return 1; }; BACKUP_RESTART=""; fi
  if [ "$rc" -ne 0 ] || ! tar -tzf "$LAST_BACKUP" >/dev/null 2>&1; then rm -f "$LAST_BACKUP"; BACKUP_PARTIAL=""; trap - EXIT INT TERM; echo "备份失败或校验失败。"; return 1; fi
  chmod 600 "$LAST_BACKUP"; BACKUP_PARTIAL=""; [ "$restart" -eq 1 ] && BACKUP_RESTART=""
  trap - EXIT INT TERM
}

restore_archive(){
  local f="$1" target="$2" st listing
  tar -tzf "$f" >/dev/null 2>&1 || return 1
  listing="$(tar -tzf "$f")"
  printf '%s\n' "$listing" | grep -Eq '(^/|(^|/)\.\.(/|$))' && return 1
  st="$(mktemp -d /tmp/sub-store-archive.XXXXXX)" || return 1; mkdir -p "$st/data"
  tar -xzf "$f" -C "$st/data" || { rm -rf "$st"; return 1; }
  rm -rf "$target"; mkdir -p "$target"; cp -a "$st/data"/. "$target"/; rm -rf "$st"
}

update_cleanup(){
  [ "$UP_ACTIVE" -eq 1 ] || return 0
  echo; echo "更新未完成，正在自动回滚..."
  docker rm -f "$UP_NAME" >/dev/null 2>&1 || true
  if [ -f "$UP_BACKUP" ]; then
    restore_archive "$UP_BACKUP" "$UP_DATA" && echo "更新前数据已恢复。" || echo "警告：数据自动恢复失败，请保留备份：$UP_BACKUP"
  fi
  docker inspect "$UP_OLD" >/dev/null 2>&1 && docker rename "$UP_OLD" "$UP_NAME" >/dev/null 2>&1 || true
  [ "$UP_WAS_RUNNING" -eq 0 ] || docker start "$UP_NAME" >/dev/null 2>&1 || true
}
do_update(){
  choose; local n="$SEL" p d x cron old
  p="$(port "$n")"; d="$(data "$n")"; x="$(envv "$n" SUB_STORE_FRONTEND_BACKEND_PATH)"; cron="$(envv "$n" SUB_STORE_BACKEND_SYNC_CRON)"; cron="${cron:-55 23 * * *}"
  [ -n "$p" ] && [ -n "$d" ] && [ -n "$x" ] && [ -d "$d" ] || { echo "无法完整读取实例配置，已停止更新。"; exit 1; }

  echo "先拉取最新镜像，当前服务保持运行..."
  docker pull xream/sub-store
  UP_WAS_RUNNING=0; running "$n" && UP_WAS_RUNNING=1
  echo "镜像拉取完成，正在生成更新前备份..."
  make_backup "$n" "$d" 0
  echo "更新前备份：$LAST_BACKUP"

  old="${n}-rollback-$(date +%Y%m%d%H%M%S)"
  UP_NAME="$n"; UP_OLD="$old"; UP_BACKUP="$LAST_BACKUP"; UP_DATA="$d"; UP_ACTIVE=1
  BACKUP_RESTART=""
  trap update_cleanup EXIT; trap 'exit 130' INT TERM
  docker rename "$n" "$old"
  docker run -d --restart=always -e "SUB_STORE_BACKEND_SYNC_CRON=$cron" -e "SUB_STORE_FRONTEND_BACKEND_PATH=$x" -p "127.0.0.1:$p:3001" -v "$d:/opt/app/data" --name "$n" xream/sub-store >/dev/null
  health "$n" "$p" "$x" || { echo "新版本健康检查失败。"; docker logs --tail 100 "$n" || true; exit 1; }
  [ "$UP_WAS_RUNNING" -eq 1 ] || docker stop "$n" >/dev/null
  UP_ACTIVE=0; trap - EXIT INT TERM
  docker rm -f "$old" >/dev/null 2>&1 || echo "警告：旧容器 $old 未能自动删除。"
  echo "更新完成：$n"; echo "更新前备份：$LAST_BACKUP"
}

do_backup(){
  choose; local d; d="$(data "$SEL")"; make_backup "$SEL" "$d" 1
  echo "备份完成：$LAST_BACKUP"
  echo "备份文件位于 /root/，可用 SFTP / SSH 文件管理工具直接下载。"
}

rs_cleanup(){
  [ "$RS_ACTIVE" -eq 1 ] || { [ -n "$RS_STAGE" ] && rm -rf "$RS_STAGE" || true; return 0; }
  echo; echo "恢复未完成，正在自动回滚原数据..."
  docker stop "$RS_NAME" >/dev/null 2>&1 || true
  [ -d "$RS_OLD" ] && { rm -rf "$RS_DATA"; mv "$RS_OLD" "$RS_DATA" || true; }
  [ "$RS_WAS_RUNNING" -eq 0 ] || docker start "$RS_NAME" >/dev/null 2>&1 || true
  [ -n "$RS_STAGE" ] && rm -rf "$RS_STAGE" || true
}
prepare_restore(){
  local f="$1" st="$2" listing tops
  tar -tzf "$f" >/dev/null 2>&1 || { echo "备份压缩包损坏或无法读取。"; return 1; }
  listing="$(tar -tzf "$f")"; printf '%s\n' "$listing" | grep -Eq '(^/|(^|/)\.\.(/|$))' && { echo "备份包包含不安全路径。"; return 1; }
  mkdir -p "$st/raw"; tar -xzf "$f" -C "$st/raw"
  mkdir -p "$st/data"
  if printf '%s\n' "$listing" | head -n1 | grep -qE '^\./'; then cp -a "$st/raw"/. "$st/data"/; return 0; fi
  tops="$(printf '%s\n' "$listing" | sed 's#^\./##' | cut -d/ -f1 | sed '/^$/d' | sort -u)"
  if [ "$(printf '%s\n' "$tops" | wc -l)" -eq 1 ] && [[ "$tops" =~ ^sub-store(-[0-9]+)?$ ]] && [ -d "$st/raw/$tops" ]; then cp -a "$st/raw/$tops"/. "$st/data"/; return 0; fi
  echo "无法识别这个备份的目录结构。"; return 1
}
do_restore(){
  choose; local n="$SEL" d p x f old st; d="$(data "$n")"; p="$(port "$n")"; x="$(envv "$n" SUB_STORE_FRONTEND_BACKEND_PATH)"
  [ -d "$d" ] && [ -n "$p" ] && [ -n "$x" ] || { echo "无法完整读取实例配置。"; exit 1; }
  echo "请先把 .tar.gz 备份文件放到服务器 /root/ 目录。"; read -rp "请输入备份文件完整路径: " f; [ -f "$f" ] || { echo "找不到：$f"; exit 1; }
  st="$(mktemp -d /tmp/sub-store-restore.XXXXXX)"; RS_STAGE="$st"; trap rs_cleanup EXIT; trap 'exit 130' INT TERM; prepare_restore "$f" "$st"
  read -rp "确认恢复到 $n？当前数据会先保留一份 [y/N]: " ok; [[ "$ok" =~ ^[Yy]$ ]] || { rm -rf "$st"; RS_STAGE=""; trap - EXIT INT TERM; echo "已取消。"; exit 0; }
  RS_WAS_RUNNING=0; running "$n" && RS_WAS_RUNNING=1; old="${d}.before-restore-$(date +%Y%m%d-%H%M%S)"
  RS_NAME="$n"; RS_DATA="$d"; RS_OLD="$old"; RS_ACTIVE=1
  [ "$RS_WAS_RUNNING" -eq 0 ] || docker stop "$n" >/dev/null
  mv "$d" "$old"; mv "$st/data" "$d"; docker start "$n" >/dev/null
  health "$n" "$p" "$x" || { echo "恢复后的数据未通过健康检查。"; exit 1; }
  [ "$RS_WAS_RUNNING" -eq 1 ] || docker stop "$n" >/dev/null
  RS_ACTIVE=0; RS_STAGE=""; rm -rf "$st"; trap - EXIT INT TERM
  echo "恢复完成：$n"; echo "恢复前数据保留在：$old"
}

restore_nginx_link(){ local site="$1" link="$2"; [ -f "$site" ] && ln -sfn "$site" "$link" || true; systemctl reload nginx >/dev/null 2>&1 || true; }
do_uninstall(){
  choose; local n="$SEL" d site link domain="" choice ok expected
  d="$(data "$n")"; site="/etc/nginx/sites-available/$n"; link="/etc/nginx/sites-enabled/$n"; expected="/etc/$n"
  [ -f "$site" ] && domain="$(awk '/^[[:space:]]*server_name[[:space:]]+/ {gsub(";","",$2); print $2; exit}' "$site")"
  echo "1) 卸载服务，但保留数据"; echo "2) 完全卸载，并永久删除数据"; read -rp "请选择 [1/2]: " choice
  if [ "$choice" = 2 ]; then
    [ "$d" = "$expected" ] && [ -d "$d" ] || { echo "数据目录异常：$d"; echo "为防止误删，已停止完全卸载。"; exit 1; }
    read -rp "确认永久删除 $n 和 $d？输入 DELETE 继续: " ok; [ "$ok" = DELETE ] || { echo "已取消。"; exit 0; }
  elif [ "$choice" = 1 ]; then
    read -rp "确认卸载 $n 并保留数据？[y/N]: " ok; [[ "$ok" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }
  else echo "请选择 1 或 2。"; exit 1; fi

  rm -f "$link"
  nginx -t || { restore_nginx_link "$site" "$link"; echo "Nginx 检查失败，未卸载。"; exit 1; }
  systemctl reload nginx || { restore_nginx_link "$site" "$link"; echo "Nginx 重新加载失败，未卸载。"; exit 1; }
  docker rm -f "$n" >/dev/null 2>&1 || { restore_nginx_link "$site" "$link"; echo "容器删除失败，已恢复 Nginx。"; exit 1; }
  rm -f "$site"

  if [ "$choice" = 1 ]; then echo "已卸载 $n，数据保留：$d"; return; fi
  rm -rf -- "$d"
  if [ -n "$domain" ]; then [ ! -x /root/.acme.sh/acme.sh ] || /root/.acme.sh/acme.sh --remove -d "$domain" --ecc >/dev/null 2>&1 || true; rm -f "/etc/nginx/ssl/$domain.cer" "/etc/nginx/ssl/$domain.key"; fi
  echo "已完全删除：$n"
}
do_status(){
  instances; printf '%-16s %-8s %-8s %-28s %s\n' "实例" "状态" "端口" "数据目录" "后端路径"
  local n s; for n in "${INS[@]}"; do s="停止"; running "$n" && s="运行"; printf '%-16s %-8s %-8s %-28s %s\n' "$n" "$s" "$(port "$n")" "$(data "$n")" "$(envv "$n" SUB_STORE_FRONTEND_BACKEND_PATH)"; done
}

cat <<'EOF'
========================================
        Sub-Store 管理脚本
========================================
1) 更新 Sub-Store
2) 备份
3) 恢复备份
4) 卸载
5) 查看实例状态
0) 退出
EOF
read -rp "请选择操作 [0-5]: " A
case "$A" in 1) do_update;; 2) do_backup;; 3) do_restore;; 4) do_uninstall;; 5) do_status;; 0) exit 0;; *) echo "无效选择。"; exit 1;; esac
