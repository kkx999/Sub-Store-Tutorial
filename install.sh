#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/etc/sub-store-installer"
EMAIL_FILE="$STATE_DIR/acme-email"
TOKEN_FILE="$STATE_DIR/cloudflare-token"
SUCCESS=0
CREATED_CONTAINER=0
CREATED_DATA_DIR=0
DATA_DIR_PREEXISTED_EMPTY=0
CREATED_NGINX=0
INSTANCE_NAME=""
DATA_DIR=""
NGINX_SITE=""
NGINX_LINK=""
CF_Token=""
CF_Zone_ID=""

cleanup() {
  local rc=$?
  unset CF_Token CF_Zone_ID 2>/dev/null || true

  if [ "$SUCCESS" -ne 1 ]; then
    if [ "$CREATED_NGINX" -eq 1 ]; then
      rm -f "$NGINX_LINK" "$NGINX_SITE" 2>/dev/null || true
      nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    fi
    if [ "$CREATED_CONTAINER" -eq 1 ] && [ -n "$INSTANCE_NAME" ]; then
      docker rm -f "$INSTANCE_NAME" >/dev/null 2>&1 || true
    fi
    if [ "$CREATED_DATA_DIR" -eq 1 ] && [ -n "$DATA_DIR" ]; then
      rm -rf "$DATA_DIR" 2>/dev/null || true
    elif [ "$DATA_DIR_PREEXISTED_EMPTY" -eq 1 ] && [ -n "$DATA_DIR" ]; then
      rm -rf "$DATA_DIR" 2>/dev/null || true
      mkdir -p "$DATA_DIR" 2>/dev/null || true
    fi
  fi

  return "$rc"
}
trap cleanup EXIT

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本。"
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "当前脚本仅支持 Debian / Ubuntu。"
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "未检测到 systemctl。当前脚本需要标准 Debian / Ubuntu VPS 环境，不支持无 systemd 的精简容器环境。"
  exit 1
fi

download_stdout() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
  else
    echo "缺少 curl 和 wget，无法下载：$url" >&2
    return 1
  fi
}

ensure_https_default_reject() {
  local site="/etc/nginx/sites-available/sub-store-default-reject"
  local link="/etc/nginx/sites-enabled/sub-store-default-reject"
  local version=""
  local reject_key="/etc/nginx/ssl/sub-store-default-reject.key"
  local reject_cert="/etc/nginx/ssl/sub-store-default-reject.crt"

  if nginx -T 2>/dev/null | grep -Eq '^[[:space:]]*listen[[:space:]][^;]*443[^;]*default_server'; then
    echo "检测到已有 HTTPS 默认站点，保持现有配置。"
    return 0
  fi

  version="$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')"
  if [ -n "$version" ] && [ "$(printf '%s\n%s\n' '1.19.4' "$version" | sort -V | head -n1)" = "1.19.4" ]; then
    cat > "$site" <<'EOF_REJECT'
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF_REJECT
  else
    mkdir -p /etc/nginx/ssl
    if [ ! -s "$reject_key" ] || [ ! -s "$reject_cert" ]; then
      openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$reject_key" -out "$reject_cert" -subj '/CN=invalid.local' >/dev/null 2>&1 || return 1
      chmod 600 "$reject_key"
    fi
    cat > "$site" <<EOF_REJECT
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate $reject_cert;
    ssl_certificate_key $reject_key;
    return 444;
}
EOF_REJECT
  fi

  ln -sfn "$site" "$link"
  if ! nginx -t; then
    rm -f "$link" "$site"
    return 1
  fi
  systemctl reload nginx
  echo "HTTPS 默认拒绝站点已启用。"
}

cat <<'EOF_BANNER'
========================================
        Sub-Store 一键部署脚本
========================================
脚本会自动识别这是第几套 Sub-Store，并自动分配：
- 容器名称
- 本机端口
- 独立数据目录
- 独立 Nginx 配置

你只需要填写：
- 后端访问路径
- 域名
- Cloudflare API Token（已有 Token 时可选择沿用或输入新的）

第一次部署还会询问一次证书邮箱。

请先确保：
- 域名已经托管到 Cloudflare
- 域名 A 记录已经指向本机公网 IPv4
- Cloudflare API Token 具有：DNS / Edit、Zone / Read
EOF_BANNER

echo
echo "[1/8] 安装并检查系统依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  wget \
  sudo \
  openssl \
  cron \
  nginx \
  iproute2 \
  jq \
  tar \
  gzip \
  coreutils \
  findutils \
  grep \
  sed \
  gawk

update-ca-certificates >/dev/null 2>&1 || true

MISSING_CMD=0
for cmd in curl wget sudo openssl cron nginx jq tar gzip ss awk grep sed find seq sort head; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "依赖安装后仍缺少命令：$cmd"
    MISSING_CMD=1
  fi
done
if [ "$MISSING_CMD" -ne 0 ]; then
  echo "系统依赖不完整，已停止部署。请先检查 apt 软件源是否正常。"
  exit 1
fi

systemctl enable --now cron nginx
if ! ensure_https_default_reject; then
  echo "无法配置 HTTPS 默认拒绝站点，为避免已卸载域名串到其他 Sub-Store，本次部署已停止。"
  exit 1
fi

echo "[2/8] 检查 Docker..."
if ! command -v docker >/dev/null 2>&1; then
  download_stdout https://get.docker.com | bash -s docker
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker 安装失败或 docker 命令不可用。"
  exit 1
fi
systemctl enable --now docker

INSTANCE_NUMBER=1
while true; do
  if [ "$INSTANCE_NUMBER" -eq 1 ]; then
    INSTANCE_NAME="sub-store"
  else
    INSTANCE_NAME="sub-store-$INSTANCE_NUMBER"
  fi

  DATA_DIR="/etc/$INSTANCE_NAME"
  NGINX_SITE="/etc/nginx/sites-available/$INSTANCE_NAME"

  INSTANCE_BUSY=0
  docker inspect "$INSTANCE_NAME" >/dev/null 2>&1 && INSTANCE_BUSY=1
  [ -e "$NGINX_SITE" ] && INSTANCE_BUSY=1
  if [ -d "$DATA_DIR" ] && [ -n "$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    INSTANCE_BUSY=1
  elif [ -e "$DATA_DIR" ] && [ ! -d "$DATA_DIR" ]; then
    INSTANCE_BUSY=1
  fi

  [ "$INSTANCE_BUSY" -eq 0 ] && break
  INSTANCE_NUMBER=$((INSTANCE_NUMBER + 1))
done

HOST_PORT=$((3000 + INSTANCE_NUMBER))
while ss -lntH | awk '{print $4}' | grep -Eq "(^|:)$HOST_PORT$"; do
  HOST_PORT=$((HOST_PORT + 1))
  if [ "$HOST_PORT" -gt 65535 ]; then
    echo "没有找到可用的本机端口。"
    exit 1
  fi
done

NGINX_LINK="/etc/nginx/sites-enabled/$INSTANCE_NAME"
SSL_DIR="/etc/nginx/ssl"

cat <<EOF_INFO

----------------------------------------
检测到本次将部署第 $INSTANCE_NUMBER 套 Sub-Store

已自动分配：
容器名称：$INSTANCE_NAME
本机端口：$HOST_PORT
数据目录：$DATA_DIR
----------------------------------------
EOF_INFO

read -rp "请输入后端访问路径（仅字母和数字）: " SUB_PATH
SUB_PATH="${SUB_PATH#/}"
if [ -z "$SUB_PATH" ]; then
  echo "后端访问路径不能为空。"
  exit 1
fi
if [[ ! "$SUB_PATH" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "后端访问路径格式不正确，只能使用字母和数字。"
  exit 1
fi
SUB_PATH="/$SUB_PATH"

read -rp "请输入域名（例如 sub.example.com）: " DOMAIN
DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"
if [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "域名格式不正确。"
  exit 1
fi

if nginx -T 2>&1 | grep -Eq "^[[:space:]]*server_name[[:space:]]+$DOMAIN([[:space:];]|$)"; then
  echo "域名 $DOMAIN 已经存在于当前 Nginx 配置中，为避免冲突已停止部署。"
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

if [ -s "$EMAIL_FILE" ]; then
  ACME_EMAIL="$(cat "$EMAIL_FILE")"
  echo "证书邮箱：$ACME_EMAIL（自动沿用）"
else
  read -rp "请输入证书邮箱: " ACME_EMAIL
  if [[ ! "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "邮箱格式不正确。"
    exit 1
  fi
fi

TOKEN_SOURCE="新输入"
if [ -s "$TOKEN_FILE" ]; then
  echo
  echo "检测到之前保存的 Cloudflare API Token："
  echo "1) 使用之前的 Token（默认）"
  echo "2) 输入新的 Token"
  read -rp "请选择 [1/2]: " TOKEN_CHOICE
  TOKEN_CHOICE="${TOKEN_CHOICE:-1}"
  case "$TOKEN_CHOICE" in
    1)
      CF_Token="$(cat "$TOKEN_FILE")"
      TOKEN_SOURCE="之前保存"
      ;;
    2)
      read -rp "请输入新的 Cloudflare API Token: " CF_Token
      TOKEN_SOURCE="新输入"
      ;;
    *)
      echo "请选择 1 或 2。"
      exit 1
      ;;
  esac
else
  read -rp "请输入 Cloudflare API Token: " CF_Token
fi

if [ -z "$CF_Token" ]; then
  echo "Cloudflare API Token 不能为空。"
  exit 1
fi

detect_cf_zone() {
  local token="$1"
  local candidate="$DOMAIN"
  local response=""
  local zone_id=""

  while [[ "$candidate" == *.* ]]; do
    response="$(curl -fsS --connect-timeout 10 --max-time 20 \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones?name=$candidate&per_page=1")" || return 1

    zone_id="$(printf '%s' "$response" | jq -r 'if .success == true and (.result | length) > 0 then .result[0].id else empty end' 2>/dev/null)"
    if [ -n "$zone_id" ]; then
      CF_Zone_ID="$zone_id"
      CF_ZONE_NAME="$candidate"
      return 0
    fi
    candidate="${candidate#*.}"
  done
  return 1
}

if ! detect_cf_zone "$CF_Token"; then
  if [ "$TOKEN_SOURCE" = "之前保存" ]; then
    echo
    echo "之前保存的 Token 无法访问域名 $DOMAIN 对应的 Cloudflare Zone。"
    echo "可能是这个新域名不在旧 Token 的授权范围内。"
    read -rp "请输入新的 Cloudflare API Token: " CF_Token
    TOKEN_SOURCE="新输入"
    if [ -z "$CF_Token" ] || ! detect_cf_zone "$CF_Token"; then
      echo "新的 Token 仍无法识别该域名，请检查 Token 权限和域名是否已托管到 Cloudflare。"
      exit 1
    fi
  else
    echo "Cloudflare Token 无法识别该域名，请检查 Token 权限和域名是否已托管到 Cloudflare。"
    exit 1
  fi
fi

detect_public_ipv4() {
  local trace=""
  PUBLIC_IPV4=""

  trace="$(curl -4 -fsS --connect-timeout 10 --max-time 20 https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true)"
  PUBLIC_IPV4="$(printf '%s\n' "$trace" | awk -F= '$1=="ip" {print $2; exit}')"

  if [[ ! "$PUBLIC_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    PUBLIC_IPV4="$(curl -4 -fsS --connect-timeout 10 --max-time 20 https://api.ipify.org 2>/dev/null || true)"
  fi

  [[ "$PUBLIC_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

check_cf_a_record() {
  local response=""
  local record_ips=""

  response="$(curl -fsS --connect-timeout 10 --max-time 20 \
    -H "Authorization: Bearer $CF_Token" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$CF_Zone_ID/dns_records?type=A&name=$DOMAIN&per_page=100")" || return 2

  if [ "$(printf '%s' "$response" | jq -r '.success // false' 2>/dev/null)" != "true" ]; then
    return 2
  fi

  record_ips="$(printf '%s' "$response" | jq -r '.result[]?.content' 2>/dev/null)"
  if [ -z "$record_ips" ]; then
    return 1
  fi

  printf '%s\n' "$record_ips" | grep -Fxq "$PUBLIC_IPV4"
}

if detect_public_ipv4; then
  if check_cf_a_record; then
    echo "Cloudflare A 记录检查通过：$DOMAIN -> $PUBLIC_IPV4"
  else
    A_CHECK_RC=$?
    if [ "$A_CHECK_RC" -eq 1 ]; then
      echo "Cloudflare A 记录未指向当前服务器公网 IPv4：$PUBLIC_IPV4"
      echo "请先把 $DOMAIN 的 A 记录修改为 $PUBLIC_IPV4，再重新运行脚本。"
      exit 1
    else
      echo "警告：无法通过 Cloudflare API 自动核对 A 记录，将继续部署。"
    fi
  fi
else
  echo "警告：无法自动获取当前服务器公网 IPv4，跳过 A 记录核对。"
fi

CERT_FILE="$SSL_DIR/$DOMAIN.cer"
KEY_FILE="$SSL_DIR/$DOMAIN.key"
HEALTH_URL="http://127.0.0.1:$HOST_PORT$SUB_PATH/api/utils/env"

cat <<EOF_CONFIRM

---------- 配置确认 ----------
第几套：第 $INSTANCE_NUMBER 套
容器名称：$INSTANCE_NAME
本机端口：127.0.0.1:$HOST_PORT
数据目录：$DATA_DIR
后端路径：$SUB_PATH
域名：$DOMAIN
Cloudflare Zone：$CF_ZONE_NAME
证书邮箱：$ACME_EMAIL
Cloudflare Token：$TOKEN_SOURCE
------------------------------
EOF_CONFIRM

read -rp "确认开始部署？[Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "已取消。"
  exit 0
fi

echo "[3/8] 安装并配置 acme.sh..."
if [ ! -x /root/.acme.sh/acme.sh ]; then
  download_stdout https://get.acme.sh | sh -s "email=$ACME_EMAIL"
fi
if [ ! -x /root/.acme.sh/acme.sh ]; then
  echo "acme.sh 安装失败。"
  exit 1
fi
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

if [ ! -s "$EMAIL_FILE" ]; then
  printf '%s\n' "$ACME_EMAIL" > "$EMAIL_FILE"
  chmod 600 "$EMAIL_FILE"
fi

echo "[4/8] 使用 Cloudflare DNS API 申请证书..."
export CF_Token CF_Zone_ID

DOMAIN_CONF="/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.conf"
INTERNAL_CERT="/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer"
SAVED_CF_TOKEN=""
SAVED_CF_ZONE_ID=""

if [ -f "$DOMAIN_CONF" ]; then
  SAVED_CF_TOKEN="$(sed -n "s/^CF_Token='\(.*\)'$/\1/p" "$DOMAIN_CONF" | head -n1)"
  SAVED_CF_ZONE_ID="$(sed -n "s/^CF_Zone_ID='\(.*\)'$/\1/p" "$DOMAIN_CONF" | head -n1)"
fi

if [ -f "$DOMAIN_CONF" ] && { [ "$SAVED_CF_TOKEN" != "$CF_Token" ] || [ "$SAVED_CF_ZONE_ID" != "$CF_Zone_ID" ]; }; then
  echo "检测到这个域名已经存在 acme.sh 证书记录，但保存的 Cloudflare 凭据与本次输入不同。"
  echo "为避免错误覆盖已有证书续期凭据，本次部署已停止。"
  echo "如果这是旧的无用证书记录，请先确认后再手动清理该域名的 acme.sh 记录。"
  exit 1
fi

if [ -f "$DOMAIN_CONF" ] && [ -f "$INTERNAL_CERT" ] && openssl x509 -checkend 86400 -noout -in "$INTERNAL_CERT" >/dev/null 2>&1; then
  echo "检测到已有有效证书且 Cloudflare 凭据一致，直接复用，不重复申请。"
else
  if [ -f "$DOMAIN_CONF" ]; then
    echo "已有证书即将过期或不可用，正在强制续期..."
    /root/.acme.sh/acme.sh --renew -d "$DOMAIN" --ecc --force
  else
    /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
  fi
fi

SAVED_CF_TOKEN=""
SAVED_CF_ZONE_ID=""
if [ -f "$DOMAIN_CONF" ]; then
  SAVED_CF_TOKEN="$(sed -n "s/^CF_Token='\(.*\)'$/\1/p" "$DOMAIN_CONF" | head -n1)"
  SAVED_CF_ZONE_ID="$(sed -n "s/^CF_Zone_ID='\(.*\)'$/\1/p" "$DOMAIN_CONF" | head -n1)"
fi
if [ ! -f "$DOMAIN_CONF" ] || [ "$SAVED_CF_TOKEN" != "$CF_Token" ] || [ "$SAVED_CF_ZONE_ID" != "$CF_Zone_ID" ]; then
  echo "未能确认 Cloudflare 续期凭据已正确保存。"
  echo "为避免证书到期后续期失败，本次部署已停止。"
  echo "当前域名没有写入 Nginx，现有网站不会受影响。"
  exit 1
fi

mkdir -p "$SSL_DIR"
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd "systemctl reload nginx"

printf '%s' "$CF_Token" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
unset CF_Token CF_Zone_ID

echo "[5/8] 拉取 Sub-Store 镜像..."
docker pull xream/sub-store

if [ ! -e "$DATA_DIR" ]; then
  mkdir -p "$DATA_DIR"
  CREATED_DATA_DIR=1
elif [ ! -d "$DATA_DIR" ]; then
  echo "数据路径 $DATA_DIR 已存在但不是目录，已停止部署。"
  exit 1
elif [ -z "$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  DATA_DIR_PREEXISTED_EMPTY=1
fi

echo "[6/8] 启动 Sub-Store..."
if ! docker run -d \
  --restart=always \
  -e "SUB_STORE_BACKEND_SYNC_CRON=55 23 * * *" \
  -e "SUB_STORE_FRONTEND_BACKEND_PATH=$SUB_PATH" \
  -p "127.0.0.1:$HOST_PORT:3001" \
  -v "$DATA_DIR:/opt/app/data" \
  --name "$INSTANCE_NAME" \
  xream/sub-store; then
  docker rm -f "$INSTANCE_NAME" >/dev/null 2>&1 || true
  echo "Sub-Store 容器创建失败。"
  exit 1
fi
CREATED_CONTAINER=1

HEALTH_OK=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
    HEALTH_OK=1
    break
  fi
  sleep 2
done
if [ "$HEALTH_OK" -ne 1 ]; then
  echo "Sub-Store 后端健康检查失败：$HEALTH_URL"
  docker logs --tail 100 "$INSTANCE_NAME" || true
  exit 1
fi

echo "[7/8] 自动生成 Nginx 配置..."
cat > "$NGINX_SITE" <<EOF_NGINX
server {
    listen 80;
    server_name $DOMAIN;

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:$HOST_PORT;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF_NGINX
ln -sfn "$NGINX_SITE" "$NGINX_LINK"
CREATED_NGINX=1

if ! nginx -t; then
  echo "Nginx 配置检查失败，本次新增内容会自动回滚。"
  exit 1
fi
systemctl reload nginx

echo "[8/8] 最终检查..."
if ! docker ps --format '{{.Names}}' | grep -Fxq "$INSTANCE_NAME"; then
  echo "Sub-Store 容器未处于运行状态。"
  docker logs --tail 100 "$INSTANCE_NAME" || true
  exit 1
fi
if ! curl -fsS --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then
  echo "最终后端健康检查失败。"
  exit 1
fi

HTTPS_HEALTH_URL="https://$DOMAIN$SUB_PATH/api/utils/env"
if ! curl -fsS --max-time 10 --resolve "$DOMAIN:443:127.0.0.1" "$HTTPS_HEALTH_URL" >/dev/null 2>&1; then
  echo "Nginx HTTPS 健康检查失败：$HTTPS_HEALTH_URL"
  exit 1
fi

SUCCESS=1

cat <<EOF_DONE

========================================
              部署完成
========================================
第几套：第 $INSTANCE_NUMBER 套
容器名称：$INSTANCE_NAME
数据目录：$DATA_DIR
本机端口：127.0.0.1:$HOST_PORT
后端路径：$SUB_PATH

访问地址：
https://$DOMAIN?api=https://$DOMAIN$SUB_PATH

以后要部署下一套：
重新执行同一条安装命令即可，脚本会自动分配下一套。

日常更新 / 备份 / 恢复 / 卸载：
bash <(curl -fsSL https://raw.githubusercontent.com/kkx999/Sub-Store-Tutorial/main/manage.sh)
========================================
EOF_DONE
