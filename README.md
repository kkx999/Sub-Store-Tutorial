# Sub-Store搭建
来源 [Sub-Store](https://github.com/sub-store-org/Sub-Store)

## 第1步  先更新系统源以及安装必要指令
```
apt upgrade -y
```
```
apt install -y curl wget sudo unzip git
```
```
apt install -y socat
```
## 第2步  安装Docker
```
curl -fsSL https://get.docker.com | bash -s docker
```
### 安装Docker完成后再复制一下内容执行
注意⚠️127.0.0.1:xxxx改为你想要的数字也可以默认
-e SUB_STORE_FRONTEND_BACKEND_PATH=/xxxxxx随机去成20位密码
```
docker run -it -d \
--restart=always \
-e "SUB_STORE_CRON=55 23 * * *" \
-e SUB_STORE_FRONTEND_BACKEND_PATH=/xxxxxxxxxx \
-p 127.0.0.1:3001:3001 \
-v /etc/sub-store:/opt/app/data \
--name sub-store \
xream/sub-store
```
## 第3步 （绑定[cloudflare](https://cloudflare.com)开启CDN）
## 第4步（利用80端口申请网站证书）
安装 Acme 脚本
```
curl https://get.acme.sh | sh
```
自行更换代码中的域名、邮箱为你解析的域名及邮箱
```
~/.acme.sh/acme.sh --register-account -m xxxx@xxxx.com
```
```
~/.acme.sh/acme.sh  --issue -d xxxxxxx.com   --standalone
```
## 第5步 安装 Nginx
```
apt install -y nginx
```
创建存放证书的文件夹
```
sudo mkdir -p /etc/nginx/ssl
```
会自动把证书和密钥复制过去，并且把 .cer 自动替换为完整的 fullchain.cer

注意⚠️修改XXXXXXX.COM为你自己申请证书的域名
```
/root/.acme.sh/acme.sh --install-cert -d XXXXXXX.COM --ecc \
--key-file       /etc/nginx/ssl/XXXXXXX.COM.key  \
--fullchain-file /etc/nginx/ssl/XXXXXXX.COM.cer \
--reloadcmd     "service nginx force-reload"
```
## 第6步  修改nginx.conf文件
注意⚠️修改XXXXXXX.COM为你的域名

127.0.0.1:xxxx改为你自己设置的端口 默认的话保持不动就行了
```
user www-data;  # 如果你的系统用户不是 www-data，这里可能需要改为 root 或 nginx
worker_processes auto;
pid /run/nginx.pid;

# 必须有的 events 块
events {
    worker_connections 768;
    # multi_accept on;
}

# 必须有的 http 块，所有的网站配置都在这里面
http {

    ##
    # 基础设置
    ##
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # MIME 类型设置 (确保网页样式加载正常)
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ##
    # SSL 全局设置
    ##
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    ##
    # 日志设置
    ##
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    ##
    # Gzip 压缩 (可选，为了速度可以开启)
    ##
    gzip on;

    # =================================================
    # 下面是你的 Sub-Store 规则配置
    # =================================================

    server {
        listen 443 ssl http2;
        server_name XXXXXXX.COM; 

        # 证书路径 (你刚才安装好的路径)
        ssl_certificate /etc/nginx/ssl/XXXXXXX.COM.cer;      
        ssl_certificate_key /etc/nginx/ssl/XXXXXXX.COM.key;  

        ssl_session_timeout 1d;
        ssl_session_cache shared:SSL:50m;
        ssl_session_tickets off;
        ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
        
        location / {
            proxy_pass http://127.0.0.1:3001; 
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_buffering off;
        }
    }

    # HTTP 强制跳转 HTTPS
    server {
        listen 80;
        server_name XXXXXXX.COM;
        location / {
            return 301 https://$host$request_uri;
        }
    }
}
```
检查配置
```
sudo nginx -t
```
如果你看到 syntax is ok 和 test is successful，说明没啥问题

然后重启 Nginx
```
sudo systemctl restart nginx

```
##  搭建完成

访问sub-store地址

注意⚠️XXXXXXX.COM改为你的域名，20位密码改为你生成的密码
```
 https://XXXXXXX.COM?api=https://XXXXXXX.COM/20位密码
```
sub-store优化脚本
```
 https://github.geekery.cn/raw.githubusercontent.com/Keywos/rule/main/rename.js
```
