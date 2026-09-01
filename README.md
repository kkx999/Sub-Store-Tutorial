# Sub-Store 搭建教程

来源：[Sub-Store](https://github.com/sub-store-org/Sub-Store)  
Docker 镜像：[xream/sub-store](https://hub.docker.com/r/xream/sub-store)

> 本教程以 Debian / Ubuntu、root 用户为例。Sub-Store 只监听本机 `127.0.0.1`，公网访问统一通过 Nginx + HTTPS。

---

## 第 1 步：更新系统并安装必要组件

```bash
apt update -y && apt install -y curl ca-certificates openssl cron nginx
```

启动并设置 Nginx、cron 开机自启：

```bash
systemctl enable --now nginx cron
```

---

## 第 2 步：安装 Docker

```bash
curl -fsSL https://get.docker.com | bash -s docker
```

检查 Docker：

```bash
docker --version
```

---

## 第 3 步：部署 Sub-Store

### 1. 生成后端安全随机路径

下面会生成一个 64 位随机字符串：

```bash
SUB_PATH="$(openssl rand -hex 32)"
echo "你的后端安全随机路径：/$SUB_PATH"
```

> ⚠️ 请保存好显示出来的路径。它是 `SUB_STORE_FRONTEND_BACKEND_PATH`，准确来说是“后端访问路径前缀”，不是账号密码，但仍然不建议公开。

如果以后忘记，可以用下面的命令从容器中查看：

```bash
docker inspect sub-store --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^SUB_STORE_FRONTEND_BACKEND_PATH='
```

### 2. 启动容器

下面的命令会检查 `SUB_PATH`，如果当前 shell 中没有刚才生成的值，会自动重新生成一个，避免误用空路径：

```bash
[ -n "$SUB_PATH" ] || SUB_PATH="$(openssl rand -hex 32)"
echo "本次使用的后端安全随机路径：/$SUB_PATH"

docker run -d \
  --restart=always \
  -e "SUB_STORE_BACKEND_SYNC_CRON=55 23 * * *" \
  -e "SUB_STORE_FRONTEND_BACKEND_PATH=/$SUB_PATH" \
  -p 127.0.0.1:3001:3001 \
  -v /etc/sub-store:/opt/app/data \
  --name sub-store \
  xream/sub-store
```

说明：

- `SUB_STORE_BACKEND_SYNC_CRON=55 23 * * *`：每天 23:55 执行 Sub-Store 后端同步任务。
- `SUB_STORE_FRONTEND_BACKEND_PATH`：前端访问后端时使用的随机路径前缀。
- `127.0.0.1:3001:3001`：只允许服务器本机访问 3001，不直接暴露到公网。
- `/etc/sub-store:/opt/app/data`：持久化保存 Sub-Store 数据。
- 容器内部端口固定为 `3001`。如果要修改宿主机端口，只修改左边，例如 `127.0.0.1:3002:3001`。

> ⚠️ 旧环境变量 `SUB_STORE_CRON` 已进入淘汰路径，新部署请使用 `SUB_STORE_BACKEND_SYNC_CRON`。

检查容器是否正常：

```bash
docker ps --filter name=sub-store
```

查看日志：

```bash
docker logs -f -t --tail 100 sub-store
```

---

## 第 4 步：在 Cloudflare 添加域名

1. 在 Cloudflare 给准备使用的域名添加 `A` 记录，指向这台服务器的公网 IPv4。
2. 有 IPv6 时也可以添加 `AAAA` 记录；没有 IPv6 不要添加。
3. Cloudflare 橙色云（代理/CDN）可以开启，DNS API 申请证书不需要关闭代理。
4. HTTPS 配置完成后，建议在 Cloudflare 的 SSL/TLS 中使用 **Full (strict) / 完全（严格）** 模式。

下面统一用 `sub.example.com` 作为示例，请替换成你自己的域名。

---

## 第 5 步：使用 Cloudflare DNS API 申请 HTTPS 证书

这里不再使用占用 80 端口的 standalone 模式，改用 Cloudflare DNS API 验证。这样 Nginx 不需要停止，后续自动续期也不会和 80 端口冲突。

### 1. 创建 Cloudflare API Token

在 Cloudflare 创建一个自定义 API Token，只授权给你要申请证书的那个根域名。

推荐权限：

- `Zone / DNS / Edit`
- `Zone / Zone / Read`
- Zone Resources：只选择需要使用的那个域名，不要授权全部域名。

同时在 Cloudflare 域名概览页面找到该域名的 **Zone ID**。

> ⚠️ 使用 API Token，不建议使用权限更大的 Global API Key。

### 2. 安装 acme.sh

把邮箱替换成你自己的：

```bash
curl https://get.acme.sh | sh -s email=your@email.com
```

本教程使用 Let's Encrypt：

```bash
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
```

### 3. 输入 Cloudflare API Token

下面的输入方式不会把 Token 明文写进当前 shell 的历史命令：

```bash
read -rsp "请输入 Cloudflare API Token: " CF_Token; export CF_Token; echo
```

填写 Zone ID：

```bash
export CF_Zone_ID="你的_ZONE_ID"
```

### 4. 申请证书

注意把 `sub.example.com` 改成自己的域名：

```bash
/root/.acme.sh/acme.sh --issue --dns dns_cf -d sub.example.com --keylength ec-256
```

### 5. 安装证书到 Nginx 使用的目录

```bash
mkdir -p /etc/nginx/ssl
```

```bash
/root/.acme.sh/acme.sh --install-cert -d sub.example.com --ecc \
  --key-file /etc/nginx/ssl/sub.example.com.key \
  --fullchain-file /etc/nginx/ssl/sub.example.com.cer \
  --reloadcmd "systemctl reload nginx"
```

申请完成后可以清掉当前 shell 中的变量：

```bash
unset CF_Token CF_Zone_ID
```

acme.sh 安装时会创建定时任务检查证书续期；`--install-cert` 中设置的 reload 命令会在证书更新后重新加载 Nginx。

检查 acme.sh 定时任务：

```bash
crontab -l | grep acme.sh
```

> ⚠️ Cloudflare API Token 后续续期仍然需要使用，不要在 Cloudflare 后台删除或撤销这个 Token。建议始终只给目标域名最小 DNS 权限。

---

## 第 6 步：配置 Nginx

不建议直接覆盖整个 `/etc/nginx/nginx.conf`。这里单独创建一个 Sub-Store 站点配置，后续升级系统或增加其他网站更安全。

创建配置：

```bash
nano /etc/nginx/sites-available/sub-store
```

写入下面内容，并把所有 `sub.example.com` 改成自己的域名：

```nginx
server {
    listen 80;
    server_name sub.example.com;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name sub.example.com;

    ssl_certificate     /etc/nginx/ssl/sub.example.com.cer;
    ssl_certificate_key /etc/nginx/ssl/sub.example.com.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

启用配置：

```bash
ln -sf /etc/nginx/sites-available/sub-store /etc/nginx/sites-enabled/sub-store
rm -f /etc/nginx/sites-enabled/default
```

检查配置：

```bash
nginx -t
```

如果看到 `syntax is ok` 和 `test is successful`，重新加载 Nginx：

```bash
systemctl reload nginx
```

> ⚠️ 如果你把 Docker 的宿主机端口从 `3001` 改成其他端口，这里的 `proxy_pass http://127.0.0.1:3001;` 也必须改成同一个端口，否则会出现 `502 Bad Gateway`。

---

## 第 7 步：访问 Sub-Store

假设：

- 域名：`sub.example.com`
- 后端安全随机路径：`/你的随机路径`

访问：

```text
https://sub.example.com?api=https://sub.example.com/你的随机路径
```

也可以先查看当前容器使用的随机路径：

```bash
docker inspect sub-store --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^SUB_STORE_FRONTEND_BACKEND_PATH='
```

---

## 第 8 步：更新 Sub-Store

`docker restart` 只会重启旧容器，不会拉取新镜像。

下面的更新方式会先自动读取你当前的后端随机路径，再重新创建容器。`/etc/sub-store` 是持久化目录，所以正常情况下不会丢失数据。

```bash
SUB_PATH="$(docker inspect sub-store --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^SUB_STORE_FRONTEND_BACKEND_PATH=//p')"

if [ -z "$SUB_PATH" ]; then
  echo "无法读取原来的 SUB_STORE_FRONTEND_BACKEND_PATH，已停止更新；现有容器不会被删除。"
else
  docker pull xream/sub-store && \
  docker rm -f sub-store && \
  docker run -d \
    --restart=always \
    -e "SUB_STORE_BACKEND_SYNC_CRON=55 23 * * *" \
    -e "SUB_STORE_FRONTEND_BACKEND_PATH=$SUB_PATH" \
    -p 127.0.0.1:3001:3001 \
    -v /etc/sub-store:/opt/app/data \
    --name sub-store \
    xream/sub-store
fi
```

这段更新命令不会因为读取路径失败而执行 `exit`，也不会在读取失败时删除现有容器。

更新后检查：

```bash
docker ps --filter name=sub-store
docker logs --tail 50 sub-store
```

---

## 第 9 步：备份与恢复

### 备份

为了避免备份时数据正在写入，推荐短暂停止容器：

```bash
docker stop sub-store
tar -czf "/root/sub-store-backup-$(date +%Y%m%d-%H%M%S).tar.gz" -C /etc sub-store
docker start sub-store
```

备份文件会保存在 `/root/`。

查看备份：

```bash
ls -lh /root/sub-store-backup-*.tar.gz
```

### 恢复

把下面的备份文件名改成你实际的文件：

```bash
docker stop sub-store
rm -rf /etc/sub-store
tar -xzf /root/sub-store-backup-YYYYMMDD-HHMMSS.tar.gz -C /etc
docker start sub-store
```

---

## 第 10 步：卸载

### 只卸载容器，保留数据

```bash
docker rm -f sub-store
```

数据仍然保存在：

```text
/etc/sub-store
```

### 完全删除 Sub-Store 数据

> ⚠️ 下面命令不可恢复，请确认已经备份。

```bash
docker rm -f sub-store 2>/dev/null || true
rm -rf /etc/sub-store
```

如果这个域名以后也不再使用，可以再删除对应 Nginx 配置：

```bash
rm -f /etc/nginx/sites-enabled/sub-store /etc/nginx/sites-available/sub-store
nginx -t && systemctl reload nginx
```

---

## 第 11 步：常见故障排查

### 查看容器状态

```bash
docker ps -a --filter name=sub-store
```

### 查看最近 100 行日志

```bash
docker logs -t --tail 100 sub-store
```

### 持续查看日志

```bash
docker logs -f -t --tail 100 sub-store
```

### 检查本机 3001 是否可以访问

```bash
curl -I http://127.0.0.1:3001
```

### 检查端口监听

```bash
ss -lntp | grep -E ':80|:443|:3001'
```

### 检查 Nginx

```bash
nginx -t
systemctl status nginx --no-pager
```

### 出现 502 Bad Gateway

优先检查：

1. `docker ps` 中 Sub-Store 是否正在运行。
2. Docker 映射的宿主机端口是否和 Nginx `proxy_pass` 一致。
3. `curl -I http://127.0.0.1:3001` 是否有响应。

---

## 第 12 步：同一台服务器部署两个 Sub-Store

可以部署多个实例，但必须使用不同的：

- 容器名
- 宿主机端口
- 数据目录
- 后端安全随机路径
- 推荐使用不同域名

第一套如果已经使用：

```text
容器：sub-store
端口：127.0.0.1:3001
数据：/etc/sub-store
```

第二套可以这样部署：

```bash
SUB_PATH2="$(openssl rand -hex 32)"
echo "第二套后端安全随机路径：/$SUB_PATH2"

docker run -d \
  --restart=always \
  -e "SUB_STORE_BACKEND_SYNC_CRON=50 23 * * *" \
  -e "SUB_STORE_FRONTEND_BACKEND_PATH=/$SUB_PATH2" \
  -p 127.0.0.1:3002:3001 \
  -v /etc/sub-store-2:/opt/app/data \
  --name sub-store-2 \
  xream/sub-store
```

注意这里是：

```text
127.0.0.1:3002:3001
          ↑    ↑
       宿主机  容器内部
```

容器内部仍然固定使用 `3001`，第二套只把宿主机端口改成 `3002`。

第二套建议使用另外一个域名，例如：

```text
sub1.example.com -> 127.0.0.1:3001
sub2.example.com -> 127.0.0.1:3002
```

第二个域名重复执行上面的 Cloudflare DNS API 证书申请步骤，然后再创建第二个 Nginx 站点，并把：

```nginx
proxy_pass http://127.0.0.1:3002;
```

指向第二套容器即可。

如果两个子域名属于同一个 Cloudflare 根域名，可以使用同一个受限 API Token；如果属于不同根域名，需要确保 Token 对对应 Zone 有权限。

---

## 可选：HTTP-META 镜像

普通订阅管理、重命名、过滤、合并、转换等场景继续使用：

```text
xream/sub-store
```

如果明确需要依赖 HTTP-META 的节点测活、落地检测等脚本，可以在部署时把镜像替换成：

```text
xream/sub-store:http-meta
```

不要因为暂时用不到 HTTP-META 就盲目更换，基础使用保持 `xream/sub-store` 即可。

---

## Sub-Store 优化脚本

```text
https://github.geekery.cn/raw.githubusercontent.com/Keywos/rule/main/rename.js
```

## 订阅转换

[边缘转换](https://bianyuan.xyz)
