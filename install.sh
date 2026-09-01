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

cat <<'EOF'
========================================
        Sub-Store 一键部署脚本
========================================
将自动完成：
1. 安装 Docker / Nginx / acme.sh
2. 部署独立 Sub-Store 容器
3. 使用 Cloudflare DNS API 申请证书
4. 自动配置 Nginx HTTPS 反向代理

请先确保：
- 域名已经托管到 Cloudflare
- 域名 A 记录已经指向本机公网 IPv4
- Cloudflare API Token 至少具有：Zone / DNS / Edit、Zone / Zone / Read
EOF

echo
read -rp "实例名称 [sub-store]: " INSTANCE_NAME
INSTANCE_NAME="${INSTANCE_NAME:-sub-store}"

if [[ ! "$INSTANCE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "实例名称格式不正确，只能使用字母、数字、点、下划线和短横线。"
  exit 1
fi

read -rp "Sub-Store 本机端口 [3001]: " HOST_PORT
HOST_PORT="${HOST_PORT:-3001}"

if [[ ! "$HOST_PORT" =~ ^[0-9]+$ ]] || [ "$HOST_PORT" -lt 1 ] || [ "$HOST_PORT" -gt 65535 ]; then
  echo "端口必须是 1-65535 之间的数字。"
  exit 1
fi

read -rp "请输入 Sub-Store 后端访问路径（例如 my-path）: " SUB_PATH
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

read -rp "请输入证书邮箱: " ACME_EMAIL
if [[ ! "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "邮箱格式不正确。"
  exit 1
fi

# 按用户要求，Token 输入时可见；read 输入不会作为命令写入 shell history。
read -rp "请输入 Cloudflare API Token: " CF_Token
if [ -z "$CF_Token" ]; then
  echo "Cloudflare API Token 不能为空。"
  exit 1
fi
export CF_Token

DATA_DIR="/etc/$INSTANCE_NAME"
NGINX_SITE="/etc/nginx/sites-available/$INSTANCE_NAME"
NGINX_LINK="/etc/nginx/sites-enabled/$INSTANCE_NAME"
SSL_DIR="/etc/nginx/ssl"
CERT_FILE="$SSL_DIR/$DOMAIN.cer"
KEY_FILE="$SSL_DIR/$DOMAIN.key"

cat <<EOF

---------- 配置确认 ----------
实例名称：$INSTANCE_NAME
本机端口：$HOST_PORT
数据目录：$DATA_DIR
后端路径：$SUB_PATH
域名：$DOMAIN
证书邮箱：$ACME_EMAIL
------------------------------
EOF

read -rp "确认开始部署？[Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "已取消。"
  unset CF_Token
  exit 0
fi

echo "[1/7] 安装系统依赖..."
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y curl ca-certificates cron nginx iproute2
systemctl enable --now cron nginx

echo "[2/7] 检查 Docker..."
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | bash -s docker
fi
systemctl enable --now docker

if docker inspect "$INSTANCE_NAME" >/dev/null 2>&1; then
  echo "已存在同名 Docker 容器：$INSTANCE_NAME"
  echo "为了避免覆盖现有数据，本次部署已停止。请重新运行并填写其他实例名称。"
  unset CF_Token
  exit 1
fi

if ss -lntH | awk '{print $4}' | grep -Eq "(^|:)$HOST_PORT$"; then
  echo "端口 $HOST_PORT 已被占用。请重新运行并选择其他端口。"
  unset CF_Token
  exit 1
fi

mkdir -p "$DATA_DIR"

echo "[3/7] 拉取并启动 Sub-Store..."
docker pull xream/sub-store

docker run -d \
  --restart=always \
  -e "SUB_STORE_BACKEND_SYNC_CRON=55 23 * * *" \
  -e "SUB_STORE_FRONTEND_BACKEND_PATH=$SUB_PATH" \
  -p "127.0.0.1:$HOST_PORT:3001" \
  -v "$DATA_DIR:/opt/app/data" \
  --name "$INSTANCE_NAME" \
  xream/sub-store

# 如果后续证书或 Nginx 配置失败，保留已经创建的容器和数据，方便排错，不自动删除用户数据。

echo "[4/7] 安装 acme.sh..."
if [ ! -x /root/.acme.sh/acme.sh ]; then
  curl https://get.acme.sh | sh -s "email=$ACME_EMAIL"
fi
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

echo "[5/7] 使用 Cloudflare DNS API 申请证书..."
/root/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256

mkdir -p "$SSL_DIR"
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd "systemctl reload nginx"

echo "[6/7] 自动配置 Nginx..."
NGINX_BACKUP=""
if [ -f "$NGINX_SITE" ]; then
  NGINX_BACKUP="${NGINX_SITE}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$NGINX_SITE" "$NGINX_BACKUP"
  echo "已备份原 Nginx 配置：$NGINX_BACKUP"
fi

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
  echo "Nginx 配置检查失败，正在恢复原配置..."
  rm -f "$NGINX_LINK"
  if [ -n "$NGINX_BACKUP" ] && [ -f "$NGINX_BACKUP" ]; then
    cp -a "$NGINX_BACKUP" "$NGINX_SITE"
    ln -sfn "$NGINX_SITE" "$NGINX_LINK"
  else
    rm -f "$NGINX_SITE"
  fi
  nginx -t || true
  unset CF_Token
  exit 1
fi

systemctl reload nginx

echo "[7/7] 检查服务..."
if ! docker ps --format '{{.Names}}' | grep -Fxq "$INSTANCE_NAME"; then
  echo "Sub-Store 容器未处于运行状态，请执行："
  echo "docker logs --tail 100 $INSTANCE_NAME"
  unset CF_Token
  exit 1
fi

if ! curl -fsS --max-time 10 "http://127.0.0.1:$HOST_PORT" >/dev/null 2>&1; then
  echo "警告：本机端口 $HOST_PORT 暂时没有正常响应，请检查容器日志。"
fi

unset CF_Token

cat <<EOF

========================================
              部署完成
========================================
实例名称：$INSTANCE_NAME
数据目录：$DATA_DIR
本机端口：127.0.0.1:$HOST_PORT
后端路径：$SUB_PATH

访问地址：
https://$DOMAIN?api=https://$DOMAIN$SUB_PATH

查看容器：
docker ps --filter name=$INSTANCE_NAME

查看日志：
docker logs -f -t --tail 100 $INSTANCE_NAME

证书续期：acme.sh 已安装定时任务，续期成功后会自动 reload Nginx。
========================================
EOF
