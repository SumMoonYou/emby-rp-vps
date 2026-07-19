#!/bin/bash

# ==================================================
# Emby Reverse Proxy Manager
# Version: v1.9.1
# ==================================================

VER="v1.9.1"

CONF="/etc/emby-rp.conf"
NGINX="/usr/local/openresty/nginx/conf/nginx.conf"
SSL="/etc/openresty/ssl"

green(){ echo -e "\033[32m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

pause(){
read -p "回车继续..."
}

init(){

[ -f "$CONF" ] || cat > "$CONF" <<EOF
DOMAIN=""
PORT="80"
EMAIL=""
FILTER="0"
ALLOW_DOMAIN=""
EOF

source "$CONF"

}

save(){

cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
PORT="$PORT"
EMAIL="$EMAIL"
FILTER="$FILTER"
ALLOW_DOMAIN="$ALLOW_DOMAIN"
EOF

}

header(){

clear

echo "================================"
echo " Emby Reverse Proxy Manager"
echo " Version: $VER"
echo "================================"
echo

}

install_pkg(){

apt update >/dev/null 2>&1

apt install -y curl wget socat >/dev/null 2>&1

}

install_openresty(){

command -v openresty >/dev/null && return

wget -qO- https://openresty.org/package/pubkey.gpg | apt-key add -

add-apt-repository \
"deb http://openresty.org/package/debian $(lsb_release -sc) main"

apt update

apt install -y openresty

systemctl enable openresty

}

make_nginx(){

mkdir -p "$SSL"

cat > "$NGINX" <<EOF
worker_processes auto;

events {
    worker_connections 4096;
}

http {

    include mime.types;

    default_type text/plain;

    charset utf-8;

    resolver 223.5.5.5 119.29.29.29 1.1.1.1 valid=300s ipv6=off;

    server {

        listen $PORT;

        server_name $DOMAIN;

        location / {

            set \$backend_host "";

            set \$backend_uri "/";

            if (\$request_uri ~ "^/https?://([^/]+)(.*)") {

                set \$backend_host \$1;

                set \$backend_uri \$2;

            }

            if (\$backend_host = "") {

                return 400 "请求格式错误

正确格式:

https://你的域名/https://目标地址";

            }

EOF

if [ "$FILTER" = "1" ] && [ -n "$ALLOW_DOMAIN" ];then

cat >> "$NGINX" <<EOF

            if (\$backend_host !~ "(^|\\.)$ALLOW_DOMAIN\$") {

                return 403 "目标域名不允许代理";

            }

EOF

fi

cat >> "$NGINX" <<'EOF'

            proxy_pass https://$backend_host$backend_uri;

            proxy_ssl_server_name on;

            proxy_ssl_name $backend_host;

            proxy_ssl_verify off;

            proxy_set_header Host $backend_host;

            proxy_set_header X-Real-IP $remote_addr;

            proxy_http_version 1.1;

            proxy_set_header Upgrade $http_upgrade;

            proxy_set_header Connection "upgrade";

            proxy_buffering off;

            proxy_request_buffering off;

            proxy_read_timeout 43200s;

            proxy_send_timeout 43200s;

        }

    }

}

EOF

openresty -t || return 1

systemctl restart openresty

green "OpenResty配置完成"

}
# ==================================================
# 证书
# ==================================================

cert(){

[ "$PORT" != "443" ] && {
green "80端口跳过证书"
return
}

[ -z "$EMAIL" ] && read -p "证书邮箱:" EMAIL

curl https://get.acme.sh | sh -s email="$EMAIL"

~/.acme.sh/acme.sh \
--set-default-ca \
--server letsencrypt

systemctl stop openresty

~/.acme.sh/acme.sh \
--issue \
-d "$DOMAIN" \
--standalone

if [ $? != 0 ];then

red "证书申请失败"

systemctl start openresty

return

fi

mkdir -p "$SSL"

~/.acme.sh/acme.sh \
--install-cert \
-d "$DOMAIN" \
--key-file "$SSL/key.pem" \
--fullchain-file "$SSL/fullchain.pem"

green "证书安装完成"

}

# ==================================================
# 安装
# ==================================================

install(){

header

install_pkg

install_openresty

read -p "代理域名:" DOMAIN

echo

echo "端口:"
echo "1) 80"
echo "2) 443"

read -p "选择:" P

case $P in

2)
PORT=443
;;

*)
PORT=80
;;

esac

if [ "$PORT" = "443" ];then

cert

fi

FILTER=0

save

make_nginx

green "安装完成"

echo

echo "版本:$VER"

echo "地址:"
echo "https://$DOMAIN/https://目标地址"

pause

}

# ==================================================
# 白名单
# ==================================================

white(){

header

echo "当前状态:"

if [ "$FILTER" = "1" ];then

echo "开启"

echo "允许:$ALLOW_DOMAIN"

else

echo "关闭"

fi

echo

echo "1 开启"

echo "2 关闭"

echo "3 设置根域名"

echo "0 返回"

read -p "选择:" W

case $W in

1)

FILTER=1

;;

2)

FILTER=0

;;

3)

read -p "根域名:" ALLOW_DOMAIN

;;

0)

return

;;

esac

save

make_nginx

pause

}

# ==================================================
# 查看配置
# ==================================================

show(){

header

cat "$CONF"

pause

}

# ==================================================
# 重载
# ==================================================

reload(){

openresty -t && systemctl reload openresty

pause

}

# ==================================================
# 卸载
# ==================================================

remove(){

systemctl stop openresty 2>/dev/null

apt remove --purge -y openresty* 2>/dev/null

rm -rf /usr/local/openresty

rm -rf "$CONF"

green "卸载完成"

pause

}

# ==================================================
# 菜单
# ==================================================

menu(){

while true

do

header

echo "1.安装反代"

echo "2.域名白名单"

echo "3.查看配置"

echo "4.重载OpenResty"

echo "5.卸载"

echo "0.退出"

echo

read -p "选择:" M

case $M in

1)
install
;;

2)
white
;;

3)
show
;;

4)
reload
;;

5)
remove
;;

0)
exit
;;

*)
echo "错误"
;;

esac

done

}

# ==================================================
# 启动
# ==================================================

if [ "$(id -u)" != "0" ];then

red "请使用root运行"

exit 1

fi

init

menu
