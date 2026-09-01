# Sub-Store 一键搭建教程

来源：[Sub-Store](https://github.com/sub-store-org/Sub-Store)  
Docker 镜像：[xream/sub-store](https://hub.docker.com/r/xream/sub-store)

本教程适用于 **Debian / Ubuntu**。

脚本会自动完成：

- 安装 Docker
- 部署 Sub-Store
- 申请 HTTPS 证书
- 配置 Nginx
- 设置证书自动续期
- 自动管理同一台服务器上的多套 Sub-Store

Sub-Store 只绑定到 `127.0.0.1`，不会直接把服务端口暴露到公网。

---

# 部署前准备

## 1. 准备域名

域名需要托管在 Cloudflare，并提前添加：

```text
A 记录 -> 当前服务器公网 IPv4
```

Cloudflare 橙色云可以开启，不影响 DNS API 申请证书。

HTTPS 配置完成后，Cloudflare SSL/TLS 建议使用：

```text
Full (strict) / 完全（严格）
```

## 2. 创建 Cloudflare API Token

创建一个自定义 API Token。

推荐权限：

```text
Zone / DNS / Edit
Zone / Zone / Read
```

`Zone Resources` 建议只选择需要使用的域名，不要授权全部域名。

> 建议使用 API Token，不要使用权限更大的 Global API Key。

---

# 一键部署

当前版本位于测试分支：

```text
update/deployment-guide-2026
```

全新 Debian / Ubuntu 服务器直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kkx999/Sub-Store-Tutorial/update/deployment-guide-2026/install.sh)
```

以后部署第二套、第三套，**还是执行完全相同的这一条命令**。

---

# 第一次部署

第一次运行时，脚本会自动识别为：

```text
第 1 套 Sub-Store
容器名称：sub-store
本机端口：3001
数据目录：/etc/sub-store
```

这些内容全部由脚本自动处理，用户不用修改。

接下来只需要输入：

```text
请输入后端访问路径：
请输入域名：
请输入证书邮箱：
请输入 Cloudflare API Token：
```

例如：

```text
请输入后端访问路径（例如 my-path）: abc123
请输入域名（例如 sub.example.com）: sub1.example.com
请输入证书邮箱: your@email.com
请输入 Cloudflare API Token: 你的Token
```

后端路径不限制固定长度，脚本会自动处理前面的 `/`。

Cloudflare Token 输入时会正常显示，方便确认输入是否正确。

脚本会自动识别 Cloudflare Zone，不需要手动填写 Zone ID。

部署成功后会直接显示完整访问地址，例如：

```text
https://sub1.example.com?api=https://sub1.example.com/abc123
```

---

# 第二套怎么部署

非常简单。

**再次执行同一条命令：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kkx999/Sub-Store-Tutorial/update/deployment-guide-2026/install.sh)
```

脚本检测到第一套已经存在后，会自动变成：

```text
检测到本次将部署第 2 套 Sub-Store

已自动分配：
容器名称：sub-store-2
本机端口：3002
数据目录：/etc/sub-store-2
```

用户不需要自己设置 `sub-store-2`、`3002` 或 `/etc/sub-store-2`。

第二套只需要填写：

```text
请输入后端访问路径：
请输入域名：
```

证书邮箱会自动沿用第一套，不需要重复输入。

如果服务器已经保存过 Cloudflare Token，脚本会询问：

```text
检测到之前保存的 Cloudflare API Token：
1) 使用之前的 Token（默认）
2) 输入新的 Token
请选择 [1/2]:
```

如果第二个域名仍然属于旧 Token 的授权范围，直接回车使用 `1` 即可。

如果第二个域名需要另外一个 Token，输入：

```text
2
```

然后再输入新的 Cloudflare API Token。

脚本会自动检查这个 Token 能不能访问当前域名。

如果选择旧 Token，但旧 Token 没有当前域名权限，脚本也会自动提示重新输入新的 Token。

---

# 多套 Sub-Store 的数据是否独立

是。

脚本会自动给每一套分配独立的：

```text
Docker 容器
本机端口
数据目录
Nginx 配置
域名证书
后端访问路径
```

例如：

```text
第 1 套
容器：sub-store
端口：3001
数据：/etc/sub-store

第 2 套
容器：sub-store-2
端口：3002
数据：/etc/sub-store-2

第 3 套
容器：sub-store-3
端口：3003
数据：/etc/sub-store-3
```

所以第二套不会读取或覆盖第一套的数据。

以后再部署第三套、第四套，也只需要继续执行同一条安装命令。

---

# Cloudflare Token 说明

脚本会把最近一次成功使用的 Cloudflare Token 保存在服务器本地，仅供下次部署时选择复用。

保存目录权限只允许 root 访问。

申请证书时，脚本会自动识别当前域名对应的 Cloudflare Zone，并让 acme.sh 把当前域名使用的 Token 和 Zone 信息保存到该域名自己的证书配置中。

因此：

```text
第一套使用 Token A
第二套使用 Token B
```

也不会因为后来输入 Token B，就把第一套证书续期需要的 Token A 覆盖掉。

---

# 证书自动续期

acme.sh 会自动安装定时任务检查证书续期。

检查：

```bash
crontab -l | grep acme.sh
```

证书续期成功后会自动执行：

```text
systemctl reload nginx
```

> 正在使用的 Cloudflare API Token 不要在 Cloudflare 后台删除或撤销，否则对应域名以后可能无法自动续期。

---

# 常用管理命令

## 查看所有 Sub-Store 容器

```bash
docker ps -a --filter name=sub-store
```

## 第一套日志

```bash
docker logs -f -t --tail 100 sub-store
```

## 第二套日志

```bash
docker logs -f -t --tail 100 sub-store-2
```

## 重启第一套

```bash
docker restart sub-store
```

## 重启第二套

```bash
docker restart sub-store-2
```

---

# 查看后端访问路径

第一套：

```bash
docker inspect sub-store --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^SUB_STORE_FRONTEND_BACKEND_PATH='
```

第二套：

```bash
docker inspect sub-store-2 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^SUB_STORE_FRONTEND_BACKEND_PATH='
```

---

# 备份

第一套数据：

```text
/etc/sub-store
```

第二套数据：

```text
/etc/sub-store-2
```

第一套备份示例：

```bash
docker stop sub-store && \
tar -czf "/root/sub-store-backup-$(date +%Y%m%d-%H%M%S).tar.gz" -C /etc sub-store && \
docker start sub-store
```

---

# 常见故障排查

## 查看容器

```bash
docker ps -a --filter name=sub-store
```

## 检查 Nginx

```bash
nginx -t
systemctl status nginx --no-pager
```

## 检查第一套本机端口

```bash
curl -I http://127.0.0.1:3001
```

## 检查第二套本机端口

```bash
curl -I http://127.0.0.1:3002
```

---

## Sub-Store 优化脚本

```text
https://github.geekery.cn/raw.githubusercontent.com/Keywos/rule/main/rename.js
```

## 订阅转换

[边缘转换](https://bianyuan.xyz)
