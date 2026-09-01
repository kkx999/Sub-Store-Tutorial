# Sub-Store 一键搭建教程

来源：[Sub-Store](https://github.com/sub-store-org/Sub-Store)  
Docker 镜像：[xream/sub-store](https://hub.docker.com/r/xream/sub-store)

本教程适用于 **Debian / Ubuntu**，使用 Docker 部署 Sub-Store，并自动完成 Cloudflare DNS API 证书申请和 Nginx HTTPS 反向代理。

Sub-Store 端口只绑定在 `127.0.0.1`，不会直接暴露到公网。

---

## 部署前准备

### 1. 准备域名

域名需要托管在 Cloudflare，并提前添加：

```text
A 记录 -> 当前服务器公网 IPv4
```

Cloudflare 橙色云可以开启，不影响 DNS API 申请证书。

HTTPS 配置完成后，Cloudflare SSL/TLS 建议使用：

```text
Full (strict) / 完全（严格）
```

### 2. 创建 Cloudflare API Token

创建一个自定义 API Token。

推荐只给当前域名以下权限：

```text
Zone / DNS / Edit
Zone / Zone / Read
```

`Zone Resources` 只选择需要部署 Sub-Store 的域名，不建议授权全部域名。

> 建议使用 API Token，不要使用权限更大的 Global API Key。

---

# 一键部署

当前修改正在测试分支 `update/deployment-guide-2026`，全新 Debian / Ubuntu 机器可以执行：

```bash
apt update -y && apt install -y git && \
git clone -b update/deployment-guide-2026 --single-branch https://github.com/kkx999/Sub-Store-Tutorial.git && \
cd Sub-Store-Tutorial && \
bash install.sh
```

脚本会自动完成：

1. 安装必要系统组件
2. 安装或检查 Docker
3. 部署 Sub-Store
4. 安装 acme.sh
5. 使用 Cloudflare DNS API 申请 HTTPS 证书
6. 自动生成 Nginx 配置
7. 检查 Nginx 配置并重新加载
8. 设置证书自动续期

---

## 脚本需要输入什么

运行后按提示填写即可。

### 实例名称

第一套直接回车即可：

```text
实例名称 [sub-store]:
```

默认使用：

```text
sub-store
```

对应数据目录：

```text
/etc/sub-store
```

### Sub-Store 本机端口

第一套直接回车即可：

```text
Sub-Store 本机端口 [3001]:
```

默认：

```text
3001
```

容器内部端口始终是 `3001`，脚本只会把宿主机端口绑定到 `127.0.0.1`。

### 后端访问路径

自己填写想使用的内容即可，例如：

```text
请输入 Sub-Store 后端访问路径（例如 my-path）: abc123
```

脚本会自动处理前面的 `/`，最终使用：

```text
/abc123
```

不限制固定长度。

建议使用自己容易保存、但不容易被别人猜到的内容。

### 域名

例如：

```text
请输入域名（例如 sub.example.com）: sub.example.com
```

只填写域名即可，不需要输入 `https://`。

### 证书邮箱

例如：

```text
请输入证书邮箱: your@email.com
```

### Cloudflare API Token

例如：

```text
请输入 Cloudflare API Token: 你的Token
```

Token 输入时会正常显示，方便检查是否输入正确。

脚本不会要求手动填写 Cloudflare Zone ID，acme.sh 会通过 Token 自动识别对应 Zone。

---

# 部署完成

脚本成功后会直接显示 Sub-Store 访问地址，例如：

```text
https://sub.example.com?api=https://sub.example.com/abc123
```

同时会显示：

```text
实例名称
数据目录
本机端口
后端访问路径
```

建议保存这些信息。

---

# 同一台服务器部署两个 Sub-Store

可以。

重新执行一次 `install.sh` 即可，但是第二套必须使用不同的：

```text
实例名称
本机端口
数据目录
后端访问路径
域名
```

例如：

| 配置 | 第一套 | 第二套 |
| --- | --- | --- |
| 实例名称 | `sub-store` | `sub-store-2` |
| 本机端口 | `3001` | `3002` |
| 数据目录 | `/etc/sub-store` | `/etc/sub-store-2` |
| 后端路径 | `/path-one` | `/path-two` |
| 域名 | `sub1.example.com` | `sub2.example.com` |

第二套运行脚本时填写：

```text
实例名称 [sub-store]: sub-store-2
Sub-Store 本机端口 [3001]: 3002
请输入 Sub-Store 后端访问路径（例如 my-path）: path-two
请输入域名（例如 sub.example.com）: sub2.example.com
```

脚本会自动创建：

```text
/etc/sub-store-2
```

所以两套 Sub-Store **不会共用数据**。

Nginx 配置、证书和 Docker 容器也会分别创建，不会使用第一套的配置。

---

# 常用管理命令

假设实例名称是：

```text
sub-store
```

## 查看容器状态

```bash
docker ps -a --filter name=sub-store
```

## 查看日志

```bash
docker logs -f -t --tail 100 sub-store
```

## 重启

```bash
docker restart sub-store
```

## 停止

```bash
docker stop sub-store
```

## 启动

```bash
docker start sub-store
```

## 查看后端访问路径

```bash
docker inspect sub-store --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^SUB_STORE_FRONTEND_BACKEND_PATH='
```

---

# 备份

第一套默认数据目录：

```text
/etc/sub-store
```

推荐停止容器后备份：

```bash
docker stop sub-store && \
tar -czf "/root/sub-store-backup-$(date +%Y%m%d-%H%M%S).tar.gz" -C /etc sub-store && \
docker start sub-store
```

查看备份：

```bash
ls -lh /root/sub-store-backup-*.tar.gz
```

如果是第二套 `sub-store-2`，对应备份目录就是：

```text
/etc/sub-store-2
```

---

# 卸载

## 删除容器但保留数据

```bash
docker rm -f sub-store
```

数据仍然保存在：

```text
/etc/sub-store
```

## 完全删除数据

> 以下操作不可恢复，确认备份以后再执行。

```bash
docker rm -f sub-store 2>/dev/null || true
rm -rf /etc/sub-store
```

对应 Nginx 配置可以删除：

```bash
rm -f /etc/nginx/sites-enabled/sub-store /etc/nginx/sites-available/sub-store
nginx -t && systemctl reload nginx
```

---

# 常见故障排查

## 查看本机端口

第一套默认：

```bash
curl -I http://127.0.0.1:3001
```

## 查看端口监听

```bash
ss -lntp | grep -E ':80|:443|:3001'
```

## 检查 Nginx

```bash
nginx -t
systemctl status nginx --no-pager
```

## 出现 502 Bad Gateway

检查：

```bash
docker ps -a --filter name=sub-store
docker logs --tail 100 sub-store
curl -I http://127.0.0.1:3001
```

脚本生成的 Nginx 配置会自动使用部署时填写的端口，一般不需要手动修改 `proxy_pass`。

---

# 证书续期

acme.sh 会自动安装定时任务检查证书续期。

检查：

```bash
crontab -l | grep acme.sh
```

证书续期成功后会自动执行：

```text
systemctl reload nginx
```

Cloudflare API Token 后续续期仍然需要使用，所以不要在 Cloudflare 后台删除或撤销正在使用的 Token。

---

## Sub-Store 优化脚本

```text
https://github.geekery.cn/raw.githubusercontent.com/Keywos/rule/main/rename.js
```

## 订阅转换

[边缘转换](https://bianyuan.xyz)
