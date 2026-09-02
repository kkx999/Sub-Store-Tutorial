# Sub-Store 一键搭建教程

来源：[Sub-Store](https://github.com/sub-store-org/Sub-Store)  
Docker 镜像：[xream/sub-store](https://hub.docker.com/r/xream/sub-store)

本教程适用于 **Debian / Ubuntu**，使用 Docker 部署 Sub-Store，并自动完成：

- Docker 安装
- Sub-Store 部署
- Cloudflare DNS API 申请 HTTPS 证书
- Nginx HTTPS 反向代理
- 证书自动续期
- 多实例自动分配
- 更新 / 备份 / 恢复 / 卸载管理

Sub-Store 只绑定到 `127.0.0.1`，不会直接把 3001 等内部服务端口暴露到公网。

---

# 部署前准备

## 1. 准备域名

域名需要托管在 Cloudflare，并提前添加：

```text
A 记录 -> 当前服务器公网 IPv4
```

有 IPv6 时可以添加 AAAA；没有 IPv6 不要添加。

Cloudflare 橙色云可以开启，不影响 DNS API 申请证书。

HTTPS 配置完成后，Cloudflare SSL/TLS 建议使用：

```text
Full (strict) / 完全（严格）
```

## 2. 创建 Cloudflare API Token

创建 **自定义 API Token**，权限只勾下面两个：

```text
DNS  → Edit
Zone → Read
```

**其他权限全部不要勾。**

`Zone Resources` 只选择你要部署 Sub-Store 的域名。

> 使用 API Token，不要使用 Global API Key。

---

# 一键部署

全新 Debian / Ubuntu 服务器直接执行这一条命令：

```bash
apt-get update && apt-get install -y curl wget sudo ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/kkx999/Sub-Store-Tutorial/main/install.sh)
```

这条命令会先补齐极简系统常见缺失的 `curl`、`wget`、`sudo` 和 HTTPS 证书组件，再启动安装脚本，因此不会因为全新系统缺少这些基础命令而直接报错。

脚本随后会继续自动安装所需组件，并检查 Docker、Nginx、证书和 Sub-Store 后端是否正常。

---

# 第一次部署

第一次运行时，通常会自动分配：

```text
第 1 套 Sub-Store
容器名称：sub-store
本机端口：3001
数据目录：/etc/sub-store
```

如果 `3001` 已经被其他程序占用，脚本会自动寻找下一个空闲端口，不需要用户手动处理。

接下来只需要输入：

```text
请输入后端访问路径：
请输入域名：
请输入证书邮箱：
请输入 Cloudflare API Token：
```

例如：

```text
请输入后端访问路径（仅字母和数字）: abc123
请输入域名（例如 sub.example.com）: sub1.example.com
请输入证书邮箱: your@email.com
请输入 Cloudflare API Token: 你的Token
```

后端路径：

- 不限制固定长度
- 脚本会自动补前面的 `/`
- 只允许字母和数字，避免特殊符号带来的兼容问题
- 建议设置成不容易被别人猜到的内容

Cloudflare Token 输入时会正常显示。

脚本会自动识别 Cloudflare Zone，不需要手动填写 Zone ID。

部署完成后会显示完整访问地址，例如：

```text
https://sub1.example.com?api=https://sub1.example.com/abc123
```

---

# 第二套、第三套怎么部署

仍然执行同一条命令：

```bash
apt-get update && apt-get install -y curl wget sudo ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/kkx999/Sub-Store-Tutorial/main/install.sh)
```

脚本会自动识别已有实例。

第二套通常会自动分配：

```text
容器名称：sub-store-2
本机端口：3002
数据目录：/etc/sub-store-2
```

第三套通常会自动分配：

```text
容器名称：sub-store-3
本机端口：3003
数据目录：/etc/sub-store-3
```

如果默认端口被其他程序占用，脚本会自动寻找下一个空闲端口。

用户不需要自己设置容器名称、端口或数据目录。

第二套以后只需要填写：

```text
后端访问路径
域名
Cloudflare Token 选择
```

证书邮箱会自动沿用第一次保存的邮箱。

---

# Cloudflare Token 怎么选择

如果服务器已经保存过 Token，脚本会显示：

```text
检测到之前保存的 Cloudflare API Token：
1) 使用之前的 Token（默认）
2) 输入新的 Token
请选择 [1/2]:
```

如果新域名仍然属于旧 Token 的授权范围，直接回车使用 `1`。

如果需要另外一个 Token，选择：

```text
2
```

然后输入新的 Token。

脚本会先验证 Token 是否能访问当前域名对应的 Cloudflare Zone，再申请证书。

证书签发后还会检查 acme.sh 是否确实保存了当前域名的 `CF_Token` 和 `CF_Zone_ID`。如果无法确认续期凭据已经保存，脚本会停止部署，避免出现“现在能用、以后证书却无法自动续期”的情况。

---

# 多套 Sub-Store 是否共用数据

不会。

每一套都会独立使用：

```text
Docker 容器
本机端口
数据目录
后端访问路径
Nginx 配置
HTTPS 证书
```

例如：

```text
第 1 套
容器：sub-store
数据：/etc/sub-store

第 2 套
容器：sub-store-2
数据：/etc/sub-store-2

第 3 套
容器：sub-store-3
数据：/etc/sub-store-3
```

所以第二套不会读取或覆盖第一套的数据。

---

# 日常管理

更新、备份、恢复、卸载统一使用一个管理脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kkx999/Sub-Store-Tutorial/main/manage.sh)
```

运行后会显示：

```text
========================================
        Sub-Store 管理脚本
========================================
1) 更新 Sub-Store
2) 备份
3) 恢复备份
4) 卸载
5) 查看实例状态
0) 退出
```

如果服务器有多套 Sub-Store，脚本会先列出所有实例，再让你选择要操作哪一套。

---

# 更新 Sub-Store

运行管理脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kkx999/Sub-Store-Tutorial/main/manage.sh)
```

选择：

```text
1) 更新 Sub-Store
```

然后选择实例。

更新过程会自动：

1. 读取原来的端口、数据目录、后端路径和同步定时配置
2. 自动生成一份更新前备份
3. 拉取最新 `xream/sub-store`
4. 暂时保留旧容器作为回滚版本
5. 启动新版本
6. 检查真实后端 API：
   ```text
   /你的后端路径/api/utils/env
   ```
7. 健康检查成功后才删除旧容器

更新前生成的备份会继续保存在 `/root/`，即使更新成功也不会自动删除。

如果新版本启动失败、后端健康检查失败，或者更新过程中被中断，脚本会自动恢复原来的旧容器，并使用更新前自动生成的备份恢复持久化数据。

所以不要使用：

```bash
docker restart sub-store
```

来当作更新。`docker restart` 只是重启当前旧镜像，不会拉取新版本。

---

# 备份

运行管理脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kkx999/Sub-Store-Tutorial/main/manage.sh)
```

选择：

```text
2) 备份
```

然后选择要备份的实例。

脚本会：

1. 记录容器原来的运行状态
2. 如果容器正在运行，先短暂停止
3. 打包数据
4. 无论备份成功还是失败，都尽量恢复到备份前的运行状态
5. 校验生成的压缩包是否可以正常读取
6. 成功后显示备份文件完整路径

例如：

```text
备份完成：/root/sub-store-backup-20260902-021800.tar.gz
```

第二套类似：

```text
/root/sub-store-2-backup-20260902-022000.tar.gz
```

备份文件统一保存在：

```text
/root/
```

新的备份格式只保存 Sub-Store 的持久化数据内容，所以备份可以恢复到你选择的任意 Sub-Store 实例，不要求“第二套备份只能恢复到第二套”。

旧版 README 生成的备份，管理脚本也会尽量自动兼容。

---

# 下载备份

使用自己的 SFTP / SSH 文件管理工具连接服务器，进入：

```text
/root/
```

找到对应的 `.tar.gz` 备份文件，直接下载到电脑或手机即可。

---

# 恢复备份

先把要恢复的 `.tar.gz` 备份文件放到服务器：

```text
/root/
```

然后运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kkx999/Sub-Store-Tutorial/main/manage.sh)
```

选择：

```text
3) 恢复备份
```

接下来：

1. 选择要恢复到哪一套 Sub-Store
2. 输入备份文件完整路径
3. 确认恢复

例如：

```text
/root/sub-store-backup-20260902-021800.tar.gz
```

恢复前，管理脚本会先：

- 检查压缩包能否正常读取
- 检查压缩包路径是否安全
- 先解压到临时目录
- 保留当前数据完整副本

真正替换数据后，还会启动 Sub-Store 并检查：

```text
/你的后端路径/api/utils/env
```

如果恢复失败、解压失败、后端健康检查失败，或者恢复过程中脚本异常退出，会尽量自动把恢复前的数据放回去。

恢复成功后，原来的数据不会马上删除，而是保留成类似：

```text
/etc/sub-store.before-restore-20260902-030000
```

确认恢复后的数据完全正常后，可以再手动删除这个旧目录释放空间。

---

# 换新服务器怎么恢复

备份主要保存的是 **Sub-Store 持久化数据**。

如果换了一台全新的服务器：

1. 先给新服务器准备 Cloudflare 域名
2. 使用一键安装脚本部署一套新的 Sub-Store
3. 确认新服务器 HTTPS 和 Sub-Store 可以正常打开
4. 把旧备份文件放到新服务器 `/root/`
5. 运行 `manage.sh`
6. 选择 `恢复备份`
7. 选择新服务器上的目标实例
8. 输入备份路径

新备份格式允许把以前的第二套、第三套数据恢复到新服务器的第一套，只要你明确选择目标实例即可。

域名、HTTPS、Nginx 和 Docker 容器建议在新服务器上重新由安装脚本生成，不需要从旧服务器复制。

---

# 卸载

运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kkx999/Sub-Store-Tutorial/main/manage.sh)
```

选择：

```text
4) 卸载
```

然后选择实例。

会有两个选项：

```text
1) 卸载服务，但保留数据目录
2) 完全卸载，并永久删除数据
```

## 保留数据

会删除：

```text
Docker 容器
对应 Nginx 站点
```

但保留：

```text
/etc/sub-store
```

或对应的：

```text
/etc/sub-store-2
/etc/sub-store-3
```

保留的数据不会被下一次一键安装覆盖。

## 完全卸载

需要再次输入：

```text
DELETE
```

才会继续。

完全卸载会删除：

- Docker 容器
- 对应 Nginx 配置
- 对应数据目录
- 对应安装证书文件
- 从 acme.sh 自动续期列表中移除该域名

> 完全卸载的数据不可恢复，建议先备份并下载到自己的设备。

---

# 查看实例状态

运行管理脚本后选择：

```text
5) 查看实例状态
```

会列出每一套实例的容器名称、运行状态、本机端口和数据目录。

---

# 常见故障排查

## 查看所有容器

```bash
docker ps -a --filter name=sub-store
```

## 查看第一套日志

```bash
docker logs -f -t --tail 100 sub-store
```

## 查看第二套日志

```bash
docker logs -f -t --tail 100 sub-store-2
```

## 检查 Nginx

```bash
nginx -t
systemctl status nginx --no-pager
```

## 查看真实后端健康状态

先查看对应实例的后端路径：

```bash
docker inspect sub-store --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^SUB_STORE_FRONTEND_BACKEND_PATH='
```

假设输出：

```text
SUB_STORE_FRONTEND_BACKEND_PATH=/abc123
```

第一套默认端口为 `3001` 时，可以检查：

```bash
curl -fsS http://127.0.0.1:3001/abc123/api/utils/env
```

如果安装时 3001 被占用，实际端口以安装脚本显示的端口为准，也可以运行管理脚本选择 `查看实例状态`。

---

# 证书续期

acme.sh 会自动安装定时任务检查证书续期。

检查：

```bash
crontab -l | grep acme.sh
```

每个域名使用签发时保存的 Cloudflare 凭据进行 DNS 验证。

证书续期成功后会自动执行：

```text
systemctl reload nginx
```

> 正在使用的 Cloudflare API Token 不要在 Cloudflare 后台删除或撤销，否则对应域名以后可能无法自动续期。

---

## Sub-Store 优化脚本

```text
https://github.geekery.cn/raw.githubusercontent.com/Keywos/rule/main/rename.js
```

## 订阅转换

[边缘转换](https://bianyuan.xyz)