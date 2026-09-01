#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本。"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "未检测到 Docker，请先使用 install.sh 部署 Sub-Store。"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  if command -v apt >/dev/null 2>&1; then
    apt update -y && DEBIAN_FRONTEND=noninteractive apt install -y jq tar
  else
    echo "缺少 jq / tar，且当前系统不支持自动安装。"
    exit 1
  fi
fi

INSTALL_URL="https://raw.githubusercontent.com/kkx999/Sub-Store-Tutorial/main/install.sh"
BACKUP_RESTART_NAME=""
BACKUP_PARTIAL=""
UPDATE_NAME=""
UPDATE_ROLLBACK_NAME=""
UPDATE_WAS_RUNNING=0
UPDATE_ACTIVE=0
UPDATE_RENAMED=0
UPDATE_BACKUP_PATH=""
UPDATE_DATA_DIR=""
RESTORE_NAME=""
RESTORE_DATA_DIR=""
RESTORE_OLD_DIR=""
RESTORE_STAGE_DIR=""
RESTORE_WAS_RUNNING=0
RESTORE_ACTIVE=0

list_instances() {
  mapfile -t INSTANCES < <(docker ps -a --format '{{.Names}}' | grep -E '^sub-store(-[0-9]+)?$' | sort -V || true)
  if [ "${#INSTANCES[@]}" -eq 0 ]; then
    echo "没有检测到由本教程命名的 Sub-Store 容器。"
    echo "安装命令：bash <(curl -fsSL $INSTALL_URL)"
    exit 1
  fi
}

container_value() {
  local name="$1" key="$2"
  docker inspect "$name" | jq -r --arg k "$key=" '.[0].Config.Env[]? | select(startswith($k)) | ltrimstr($k)' | head -n1
}

container_port() {
  docker inspect "$1" | jq -r '.[0].HostConfig.PortBindings["3001/tcp"][0].HostPort // empty'
}

container_data_dir() {
  docker inspect "$1" | jq -r '.[0].Mounts[]? | select(.Destination == "/opt/app/data") | .Source' | head -n1
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]
}

wait_health() {
  local name="$1" port="$2" path="$3"
  local url="http://127.0.0.1:$port$path/api/utils/env"
  local i
  for i in $(seq 1 30); do
    if container_running "$name" && curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

select_instance() {
  list_instances
  echo
  echo "检测到以下 Sub-Store："
  local i name state port path
  for i in "${!INSTANCES[@]}"; do
    name="${INSTANCES[$i]}"
    state="已停止"
    container_running "$name" && state="运行中"
    port="$(container_port "$name")"
    path="$(container_value "$name" SUB_STORE_FRONTEND_BACKEND_PATH)"
    echo "$((i + 1))) $name  [$state]  端口:${port:-未知}  路径:${path:-未知}"
  done
  read -rp "请选择实例编号: " INSTANCE_CHOICE
  if [[ ! "$INSTANCE_CHOICE" =~ ^[0-9]+$ ]] || [ "$INSTANCE_CHOICE" -lt 1 ] || [ "$INSTANCE_CHOICE" -gt "${#INSTANCES[@]}" ]; then
    echo "实例编号无效。"
    exit 1
  fi
  SELECTED_INSTANCE="${INSTANCES[$((INSTANCE_CHOICE - 1))]}"
}

backup_exit_cleanup() {
  if [ -n "$BACKUP_RESTART_NAME" ]; then
    docker start "$BACKUP_RESTART_NAME" >/dev/null 2>&1 || true
  fi
  if [ -n "$BACKUP_PARTIAL" ]; then
    rm -f "$BACKUP_PARTIAL" 2>/dev/null || true
  fi
}

backup_instance() {
  local name="$1"
  local quiet="${2:-0}"
  local data_dir backup was_running=0 tar_rc=0

  data_dir="$(container_data_dir "$name")"
  if [ -z "$data_dir" ] || [ ! -d "$data_dir" ]; then
    echo "无法找到 $name 的数据目录。"
    return 1
  fi

  backup="/root/${name}-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  BACKUP_PARTIAL="$backup"

  container_running "$name" && was_running=1

  trap backup_exit_cleanup EXIT
  trap 'exit 130' INT TERM

  if [ "$was_running" -eq 1 ]; then
    BACKUP_RESTART_NAME="$name"
    docker stop "$name" >/dev/null
  fi

  if tar -czf "$backup" -C "$data_dir" .; then
    tar_rc=0
  else
    tar_rc=$?
  fi

  if [ "$was_running" -eq 1 ]; then
    if ! docker start "$name" >/dev/null; then
      echo "警告：备份后容器未能重新启动，请执行 docker start $name"
      return 1
    fi
    BACKUP_RESTART_NAME=""
  fi

  if [ "$tar_rc" -ne 0 ]; then
    rm -f "$backup"
    BACKUP_PARTIAL=""
    trap - EXIT INT TERM
    echo "备份失败，但容器已恢复到备份前的运行状态。"
    return "$tar_rc"
  fi

  BACKUP_PARTIAL=""
  chmod 600 "$backup"
  if ! tar -tzf "$backup" >/dev/null 2>&1; then
    rm -f "$backup"
    trap - EXIT INT TERM
    echo "备份文件校验失败，已删除异常备份。"
    return 1
  fi
  LAST_BACKUP="$backup"
  trap - EXIT INT TERM

  if [ "$quiet" -ne 1 ]; then
    echo "备份完成：$backup"
    ls -lh "$backup"
  fi
}

restore_update_backup() {
  local stage failed_dir
  [ -n "$UPDATE_BACKUP_PATH" ] && [ -f "$UPDATE_BACKUP_PATH" ] || return 1
  [ -n "$UPDATE_DATA_DIR" ] || return 1

  stage="$(mktemp -d /tmp/sub-store-update-rollback.XXXXXX)" || return 1
  mkdir -p "$stage/data"
  if ! tar -xzf "$UPDATE_BACKUP_PATH" -C "$stage/data"; then
    rm -rf "$stage"
    return 1
  fi

  failed_dir="${UPDATE_DATA_DIR}.failed-update-$(date +%Y%m%d-%H%M%S)"
  if [ -e "$UPDATE_DATA_DIR" ]; then
    mv "$UPDATE_DATA_DIR" "$failed_dir" || { rm -rf "$stage"; return 1; }
  else
    failed_dir=""
  fi

  if mv "$stage/data" "$UPDATE_DATA_DIR"; then
    if [ -n "$failed_dir" ] && [ -e "$failed_dir" ]; then
      chmod --reference="$failed_dir" "$UPDATE_DATA_DIR" 2>/dev/null || true
      chown --reference="$failed_dir" "$UPDATE_DATA_DIR" 2>/dev/null || true
      rm -rf "$failed_dir"
    fi
    rm -rf "$stage"
    return 0
  fi

  rm -rf "$UPDATE_DATA_DIR" "$stage"
  if [ -n "$failed_dir" ] && [ -e "$failed_dir" ]; then
    mv "$failed_dir" "$UPDATE_DATA_DIR" >/dev/null 2>&1 || true
  fi
  return 1
}

update_exit_cleanup() {
  if [ "$UPDATE_ACTIVE" -ne 1 ] || [ -z "$UPDATE_NAME" ]; then
    return 0
  fi

  echo
  echo "更新未完成，正在自动恢复更新前状态..."

  if docker inspect "$UPDATE_ROLLBACK_NAME" >/dev/null 2>&1; then
    docker rm -f "$UPDATE_NAME" >/dev/null 2>&1 || true

    if restore_update_backup; then
      echo "更新前数据已自动恢复。"
    else
      echo "警告：自动恢复更新前数据失败，请保留备份并人工检查：$UPDATE_BACKUP_PATH"
    fi

    docker rename "$UPDATE_ROLLBACK_NAME" "$UPDATE_NAME" >/dev/null 2>&1 || true
  fi

  if [ "$UPDATE_WAS_RUNNING" -eq 1 ] && docker inspect "$UPDATE_NAME" >/dev/null 2>&1; then
    docker start "$UPDATE_NAME" >/dev/null 2>&1 || true
  fi
}

update_instance() {
  select_instance
  local name="$SELECTED_INSTANCE"
  local port data_dir sub_path sync_cron backup_path rollback_name was_running=0

  port="$(container_port "$name")"
  data_dir="$(container_data_dir "$name")"
  sub_path="$(container_value "$name" SUB_STORE_FRONTEND_BACKEND_PATH)"
  sync_cron="$(container_value "$name" SUB_STORE_BACKEND_SYNC_CRON)"
  sync_cron="${sync_cron:-55 23 * * *}"

  if [ -z "$port" ] || [ -z "$data_dir" ] || [ -z "$sub_path" ]; then
    echo "无法完整读取现有容器配置，为避免误删已停止更新。"
    exit 1
  fi

  echo
  echo "更新前会自动备份数据。"
  backup_instance "$name" 1
  backup_path="$LAST_BACKUP"
  echo "自动备份：$backup_path"

  echo "拉取最新镜像..."
  docker pull xream/sub-store

  container_running "$name" && was_running=1
  rollback_name="${name}-rollback-$(date +%Y%m%d%H%M%S)"

  UPDATE_NAME="$name"
  UPDATE_ROLLBACK_NAME="$rollback_name"
  UPDATE_WAS_RUNNING="$was_running"
  UPDATE_BACKUP_PATH="$backup_path"
  UPDATE_DATA_DIR="$data_dir"
  UPDATE_ACTIVE=1
  UPDATE_RENAMED=0
  trap update_exit_cleanup EXIT
  trap 'exit 130' INT TERM

  if [ "$was_running" -eq 1 ]; then
    docker stop "$name" >/dev/null
  fi
  docker rename "$name" "$rollback_name"
  UPDATE_RENAMED=1

  echo "启动新版本..."
  docker run -d \
    --restart=always \
    -e "SUB_STORE_BACKEND_SYNC_CRON=$sync_cron" \
    -e "SUB_STORE_FRONTEND_BACKEND_PATH=$sub_path" \
    -p "127.0.0.1:$port:3001" \
    -v "$data_dir:/opt/app/data" \
    --name "$name" \
    xream/sub-store >/dev/null

  if ! wait_health "$name" "$port" "$sub_path"; then
    echo "新版本健康检查失败。"
    docker logs --tail 100 "$name" || true
    exit 1
  fi

  if [ "$was_running" -eq 0 ]; then
    docker stop "$name" >/dev/null
  fi

  UPDATE_ACTIVE=0
  UPDATE_RENAMED=0
  trap - EXIT INT TERM
  docker rm -f "$rollback_name" >/dev/null 2>&1 || echo "警告：旧容器 $rollback_name 未能自动删除，可稍后手动删除。"

  echo "更新完成：$name"
  echo "更新前备份：$backup_path"
}

backup_menu() {
  select_instance
  backup_instance "$SELECTED_INSTANCE"
  cat <<EOF_DOWNLOAD

下载到电脑（在自己的电脑终端 / PowerShell 执行）：
scp root@服务器IP:$LAST_BACKUP .

如果 SSH 不是 22 端口，例如 2222：
scp -P 2222 root@服务器IP:$LAST_BACKUP .

手机可以使用支持 SFTP 的 SSH 工具进入 /root/ 下载这个文件。
EOF_DOWNLOAD
}

restore_exit_cleanup() {
  if [ "$RESTORE_ACTIVE" -ne 1 ]; then
    [ -n "$RESTORE_STAGE_DIR" ] && rm -rf "$RESTORE_STAGE_DIR" 2>/dev/null || true
    return 0
  fi

  echo
  echo "恢复操作未完成，正在自动回滚原数据..."
  docker stop "$RESTORE_NAME" >/dev/null 2>&1 || true

  if [ -n "$RESTORE_OLD_DIR" ] && [ -d "$RESTORE_OLD_DIR" ]; then
    rm -rf "$RESTORE_DATA_DIR" 2>/dev/null || true
    mv "$RESTORE_OLD_DIR" "$RESTORE_DATA_DIR" >/dev/null 2>&1 || true
  fi

  if [ "$RESTORE_WAS_RUNNING" -eq 1 ]; then
    docker start "$RESTORE_NAME" >/dev/null 2>&1 || true
  fi
  [ -n "$RESTORE_STAGE_DIR" ] && rm -rf "$RESTORE_STAGE_DIR" 2>/dev/null || true
}

prepare_restore_stage() {
  local backup="$1" stage="$2"
  local listing first_top

  if ! tar -tzf "$backup" >/dev/null 2>&1; then
    echo "备份压缩包无法读取或已损坏。"
    return 1
  fi

  listing="$(tar -tzf "$backup")"
  if printf '%s\n' "$listing" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    echo "备份包包含不安全路径，拒绝恢复。"
    return 1
  fi

  mkdir -p "$stage/raw"
  tar -xzf "$backup" -C "$stage/raw"

  if printf '%s\n' "$listing" | head -n1 | grep -qE '^\./'; then
    mkdir -p "$stage/data"
    cp -a "$stage/raw"/. "$stage/data"/
    return 0
  fi

  first_top="$(printf '%s\n' "$listing" | sed 's#^\./##' | cut -d/ -f1 | sed '/^$/d' | sort -u)"
  if [ "$(printf '%s\n' "$first_top" | sed '/^$/d' | wc -l)" -eq 1 ] && [[ "$first_top" =~ ^sub-store(-[0-9]+)?$ ]] && [ -d "$stage/raw/$first_top" ]; then
    mkdir -p "$stage/data"
    cp -a "$stage/raw/$first_top"/. "$stage/data"/
    return 0
  fi

  echo "无法识别这个备份的目录结构。"
  return 1
}

restore_instance() {
  select_instance
  local name="$SELECTED_INSTANCE"
  local data_dir port sub_path backup old_dir stage was_running=0

  data_dir="$(container_data_dir "$name")"
  port="$(container_port "$name")"
  sub_path="$(container_value "$name" SUB_STORE_FRONTEND_BACKEND_PATH)"

  if [ -z "$data_dir" ] || [ -z "$port" ] || [ -z "$sub_path" ] || [ ! -d "$data_dir" ]; then
    echo "无法完整读取实例配置，已停止恢复。"
    exit 1
  fi

  echo
  echo "请先把 .tar.gz 备份上传到服务器，例如 /root/xxx.tar.gz"
  read -rp "请输入服务器上的备份文件完整路径: " backup
  if [ ! -f "$backup" ]; then
    echo "找不到备份文件：$backup"
    exit 1
  fi

  stage="$(mktemp -d /tmp/sub-store-restore.XXXXXX)"
  RESTORE_STAGE_DIR="$stage"
  trap restore_exit_cleanup EXIT
  trap 'exit 130' INT TERM

  if ! prepare_restore_stage "$backup" "$stage"; then
    exit 1
  fi

  read -rp "确认用该备份恢复 $name？原数据会先完整保留一份 [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "已取消。"
    RESTORE_STAGE_DIR=""
    rm -rf "$stage"
    trap - EXIT INT TERM
    exit 0
  fi

  container_running "$name" && was_running=1
  old_dir="${data_dir}.before-restore-$(date +%Y%m%d-%H%M%S)"

  RESTORE_NAME="$name"
  RESTORE_DATA_DIR="$data_dir"
  RESTORE_OLD_DIR="$old_dir"
  RESTORE_WAS_RUNNING="$was_running"
  RESTORE_ACTIVE=1

  if [ "$was_running" -eq 1 ]; then
    docker stop "$name" >/dev/null
  fi

  mv "$data_dir" "$old_dir"
  mv "$stage/data" "$data_dir"

  docker start "$name" >/dev/null
  if ! wait_health "$name" "$port" "$sub_path"; then
    echo "恢复后的数据未通过健康检查。"
    exit 1
  fi

  if [ "$was_running" -eq 0 ]; then
    docker stop "$name" >/dev/null
  fi

  RESTORE_ACTIVE=0
  RESTORE_STAGE_DIR=""
  rm -rf "$stage"
  trap - EXIT INT TERM

  echo "恢复完成：$name"
  echo "恢复前的数据仍保留在：$old_dir"
  echo "确认一切正常后，可手动删除该目录释放空间。"
}

uninstall_instance() {
  select_instance
  local name="$SELECTED_INSTANCE"
  local data_dir site link domain=""

  data_dir="$(container_data_dir "$name")"
  site="/etc/nginx/sites-available/$name"
  link="/etc/nginx/sites-enabled/$name"
  if [ -f "$site" ]; then
    domain="$(awk '/^[[:space:]]*server_name[[:space:]]+/ {gsub(";", "", $2); print $2; exit}' "$site")"
  fi

  echo
  echo "1) 卸载服务，但保留数据目录"
  echo "2) 完全卸载，并永久删除数据"
  read -rp "请选择 [1/2]: " choice

  case "$choice" in
    1)
      read -rp "确认卸载 $name 并保留数据？[y/N]: " confirm
      [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }

      rm -f "$link"
      if ! nginx -t; then
        ln -sfn "$site" "$link"
        echo "Nginx 检查失败，已恢复站点链接，未卸载容器。"
        exit 1
      fi
      if ! systemctl reload nginx; then
        ln -sfn "$site" "$link"
        systemctl reload nginx >/dev/null 2>&1 || true
        echo "Nginx 重新加载失败，已恢复站点链接，未卸载容器。"
        exit 1
      fi
      if ! docker rm -f "$name" >/dev/null 2>&1; then
        if [ -f "$site" ]; then
          ln -sfn "$site" "$link"
          systemctl reload nginx >/dev/null 2>&1 || true
        fi
        echo "Docker 容器删除失败，已恢复 Nginx 站点，数据未删除。"
        exit 1
      fi
      rm -f "$site"

      echo "已卸载 $name。"
      echo "数据仍保留：$data_dir"
      echo "注意：保留的数据目录存在时，一键安装会把它视为已有实例数据，不会覆盖。"
      ;;
    2)
      read -rp "确认永久删除 $name 和 $data_dir？输入 DELETE 继续: " confirm
      if [ "$confirm" != "DELETE" ]; then
        echo "已取消。"
        exit 0
      fi

      rm -f "$link"
      if ! nginx -t; then
        ln -sfn "$site" "$link"
        echo "Nginx 检查失败，已恢复站点链接，未删除容器或数据。"
        exit 1
      fi
      if ! systemctl reload nginx; then
        ln -sfn "$site" "$link"
        systemctl reload nginx >/dev/null 2>&1 || true
        echo "Nginx 重新加载失败，已恢复站点链接，未删除容器或数据。"
        exit 1
      fi
      if ! docker rm -f "$name" >/dev/null 2>&1; then
        if [ -f "$site" ]; then
          ln -sfn "$site" "$link"
          systemctl reload nginx >/dev/null 2>&1 || true
        fi
        echo "Docker 容器删除失败，已恢复 Nginx 站点；数据和证书均未删除。"
        exit 1
      fi
      rm -f "$site"

      if [ -z "$data_dir" ] || [ "$data_dir" = "/" ]; then
        echo "检测到异常数据目录，已停止删除数据：$data_dir"
        exit 1
      fi
      rm -rf -- "$data_dir"

      if [ -n "$domain" ]; then
        /root/.acme.sh/acme.sh --remove -d "$domain" --ecc >/dev/null 2>&1 || true
        rm -f "/etc/nginx/ssl/$domain.cer" "/etc/nginx/ssl/$domain.key"
      fi
      echo "已完全删除：$name"
      ;;
    *)
      echo "请选择 1 或 2。"
      exit 1
      ;;
  esac
}

show_status() {
  list_instances
  printf '%-16s %-8s %-8s %-28s %s\n' "实例" "状态" "端口" "数据目录" "后端路径"
  local name state port data path
  for name in "${INSTANCES[@]}"; do
    state="停止"
    container_running "$name" && state="运行"
    port="$(container_port "$name")"
    data="$(container_data_dir "$name")"
    path="$(container_value "$name" SUB_STORE_FRONTEND_BACKEND_PATH)"
    printf '%-16s %-8s %-8s %-28s %s\n' "$name" "$state" "${port:-?}" "${data:-?}" "${path:-?}"
  done
}

cat <<'EOF_MENU'
========================================
        Sub-Store 管理脚本
========================================
1) 更新 Sub-Store
2) 备份
3) 恢复备份
4) 卸载
5) 查看实例状态
0) 退出
EOF_MENU

read -rp "请选择操作 [0-5]: " ACTION
case "$ACTION" in
  1) update_instance ;;
  2) backup_menu ;;
  3) restore_instance ;;
  4) uninstall_instance ;;
  5) show_status ;;
  0) exit 0 ;;
  *) echo "无效选择。"; exit 1 ;;
esac
