#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本。"
  exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
  echo "当前脚本仅支持 Debian / Ubuntu。"
  exit 1
fi

STATE_DIR="/etc/sub-store-installer"
EMAIL_FILE="$STATE_DIR/acme-email"
TOKEN_FILE="$STATE_DIR/cloudflare-token"

cat <<'EOF'
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
- Cloudflare API Token（可选择沿用之前的）

第一次部署还会询问一次证书邮箱。

请先确保：
- 域名已经托管到 Cloudflare
- 域名 A 记录已经指向本机公网 IPv4
- Cloudflare API Token 具有：Zone / DNS / Edit、Zone / Zone / Read
EOF

echo
echo "[1/7] 安装系统依赖..."
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y curl ca-certificates cron nginx iproute2 jq
systemctl enable --now cron nginx

echo "[2/7] 检查 Docker..."
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | bash -s docker
fi
systemctl enable --now docker

# 自动寻找下一套可用实例。
INSTANCE_NUMBER=1
while true; do
  if [ "$INSTANCE_NUMBER" -eq 1 ]; then
    INSTANCE_NAME="sub-store"
    HOST_PORT=3001
  else
    INSTANCE_NAME="sub-store-$INSTANCE_NUMBER"
    HOST_PORT=$((3000 + INSTANCE_NUMBER))
  fi

  DATA_DIR="/etc/$INSTANCE_NAME"
  NGINX_SITE="/etc/nginx/sites-available/$INSTANCE_NAME"

  INSTANCE_BUSY=0
  docker inspect "$INSTANCE_NAME" >/dev/null 2>&1 && INSTANCE_BUSY=1
  [ -e "$DATA_DIR" ] && INSTANCE_BUSY=1
  [ -e "$NGINX_SITE" ] && INSTANCE_BUSY=1
  ss -lntH | awk '{print $4}' | grep -Eq "(^|:)$HOST_PORT$" && INSTANCE_BUSY=1

  if [ "$INSTANCE_BUSY" -eq 0 ]; then
    break
  fi

  INSTANCE_NUMBER=$((INSTANCE_NUMBER + 1))
done

NGINX_LINK="/etc/nginx/sites-enabled/$INSTANCE_NAME"
SSL_DIR="/etc/nginx/ssl"

cat <<EOF

----------------------------------------
检测到本次将部署第 $INSTANCE_NUMBER 套 Sub-Store

已自动分配：
容器名称：$INSTANCE_NAME
本机端口：$HOST_PORT
数据目录：$DATA_DIR
----------------------------------------
EOF

read -rp "请输入后端访问路径（例如 my-path）: " SUB_PATH
SUB_PATH="${SUB_PATH#/}"
if [ -z "$SUB_PATH" ]; then
  echo "后端访问路径不能为空。"
  exit 1
fi
if [[ ! "$SUB_PATH" =~ ^[A-Za-z0-9._~/-]+$ ]]; then
  echo "后端访问路径包含不支持的字符。建议只使用字母、数字、点、下划线、短横线或 /。"
  exit 1
fi
SUB_PATH="/$SUB_PATH"

read -rp "请输入域名（例如 sub.example.com）: " DOMAIN
DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"
if [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
  echo "域名格式不正确。"
  exit 1
fi

if grep -RqsE "^[[:space:]]*server_name[[:space:]]+$DOMAIN([[:space:];]|$)" /etc/nginx/sites-enabled 2>/dev/null; then
  echo "域名 $DOMAIN 已经存在于 Nginx 配置中，为避免冲突已停止部署。"
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# 第一次询问邮箱，以后自动沿用。
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

# 通过 Token 自动定位当前域名所属的 Cloudflare Zone。
detect_cf_zone() {
  local token="$1"
  local candidate="$DOMAIN"
  local response=""
  local zone_id=""

  while [[ "$candidate" == *.* ]]; do
    response="$(curl -sS --connect-timeout 10 --max-time 20 \
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

CERT_FILE="$SSL_DIR/$DOMAIN.cer"
KEY_FILE="$SSL_DIR/$DOMAIN.key"

cat <<EOF

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
EOF

read -rp "确认开始部署？[Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "已取消。"
  unset CF_Token CF_Zone_ID
  exit 0
fi

echo "[3/7] 安装并配置 acme.sh..."
if [ ! -x /root/.acme.sh/acme.sh ]; then
  curl https://get.acme.sh | sh -s "email=$ACME_EMAIL"
fi
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 首次保存邮箱。
if [ ! -s "$EMAIL_FILE" ]; then
  printf '%s\n' "$ACME_EMAIL" > "$EMAIL_FILE"
  chmod 600 "$EMAIL_FILE"
fi

echo "[4/7] 使用 Cloudflare DNS API 申请证书..."
export CF_Token CF_Zone_ID
/root/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256

mkdir -p "$SSL_DIR"
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd "systemctl reload nginx"

# 证书申请成功后，把本次使用的 Token 保存为下次可选择的旧 Token。
printf '%s' "$CF_Token" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

# 因为同时传入了 CF_Zone_ID，acme.sh 会把 Token/Zone 信息保存到当前域名配置中，
# 后续更换默认 Token 不会覆盖已经签发域名自己的续期凭据。
unset CF_Token CF_Zone_ID

echo "[5/7] 自动生成 Nginx 配置..."
cat > "$NGINX_SITE" <<EOF
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
EOF

ln -sfn "$NGINX_SITE" "$NGINX_LINK"
if ! nginx -t; then
  echo "Nginx 配置检查失败，已撤销本次新增的 Nginx 配置。"
  rm -f "$NGINX_LINK" "$NGINX_SITE"
  nginx -t || true
  exit 1
fi

echo "[6/7] 部署 Sub-Store..."
docker pull xream/sub-store
mkdir -p "$DATA_DIR"

if ! docker run -d \
  --restart=always \
  -e "SUB_STORE_BACKEND_SYNC_CRON=55 23 * * *" \
  -e "SUB_STORE_FRONTEND_BACKEND_PATH=$SUB_PATH" \
  -p "127.0.0.1:$HOST_PORT:3001" \
  -v "$DATA_DIR:/opt/app/data" \
  --name "$INSTANCE_NAME" \
  xream/sub-store; then
  echo "Sub-Store 容器创建失败，已撤销本次 Nginx 配置。"
  rm -f "$NGINX_LINK" "$NGINX_SITE"
  nginx -t || true
  exit 1
fi

systemctl reload nginx

echo "[7/7] 检查服务..."
if ! docker ps --format '{{.Names}}' | grep -Fxq "$INSTANCE_NAME"; then
  echo "Sub-Store 容器未处于运行状态，请执行："
  echo "docker logs --tail 100 $INSTANCE_NAME"
  exit 1
fi

if ! curl -fsS --max-time 10 "http://127.0.0.1:$HOST_PORT" >/dev/null 2>&1; then
  echo "警告：本机端口 $HOST_PORT 暂时没有正常响应，请检查容器日志。"
fi

cat <<EOF

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

查看日志：
docker logs -f -t --tail 100 $INSTANCE_NAME

证书续期：acme.sh 已安装定时任务，当前域名会使用签发时保存的 Cloudflare 凭据自动续期。
========================================
EOF
