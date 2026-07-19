#!/bin/bash

# ==================================================
# Emby Reverse Proxy Manager
# Version: v2.0
#
# 更新:
# 1. 支持 /域名 自动HTTPS
# 2. 支持 /http:// /https://
# 3. 支持端口自动判断
# 4. 白名单多域名管理
# ==================================================

VER="v2.0"

CONF="/etc/emby-rp.conf"
NGINX="/usr/local/openresty/nginx/conf/nginx.conf"
SSL="/etc/openresty/ssl"


# ==============================
# 统一提示
# ==============================

green(){
echo -e "\033[32m$1\033[0m"
}

red(){
echo -e "\033[31m$1\033[0m"
}

yellow(){
echo -e "\033[33m$1\033[0m"
}


pause(){

read -p "回车继续..."

}



# ==============================
# 初始化
# ==============================

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



# ==============================
# 保存配置
# ==============================

save(){


cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
PORT="$PORT"
EMAIL="$EMAIL"
FILTER="$FILTER"
ALLOW_DOMAIN="$ALLOW_DOMAIN"
EOF


}



# ==============================
# 标题
# ==============================

header(){

clear

echo "================================"
echo " Emby Reverse Proxy Manager"
echo " Version: $VER"
echo "================================"

echo

}



# ==============================
# 安装依赖
# ==============================

install_pkg(){

apt update >/dev/null 2>&1

apt install -y curl wget socat >/dev/null 2>&1

}



# ==============================
# OpenResty安装
# 保留原版逻辑
# ==============================

install_openresty(){


command -v openresty >/dev/null && return


wget -qO- https://openresty.org/package/pubkey.gpg | apt-key add -


add-apt-repository \
"deb http://openresty.org/package/debian $(lsb_release -sc) main"


apt update


apt install -y openresty


systemctl enable openresty


}



# ==============================
# 生成Nginx配置
# ==============================

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



# 默认HTTPS

set \$backend_scheme "https";

set \$backend_host "";

set \$backend_uri "/";



# ==============================
# 完整地址
# /https://example.com
# /http://example.com
# ==============================


if (\$request_uri ~ "^/(https?)://([^/]+)(.*)") {


set \$backend_scheme \$1;

set \$backend_host \$2;

set \$backend_uri \$3;


}



# ==============================
# 简写地址
# /example.com
# 自动HTTPS
# ==============================


if (\$backend_host = "") {


if (\$request_uri ~ "^/([^/]+)(.*)") {


set \$backend_host \$1;

set \$backend_uri \$2;


}

}



# 默认路径


if (\$backend_uri = "") {

set \$backend_uri "/";

}



# ==============================
# 端口判断
# ==============================


if (\$backend_host ~ ":(80)$") {

set \$backend_scheme "http";

}



if (\$backend_host ~ ":(443)$") {

set \$backend_scheme "https";

}



if (\$backend_host ~ ":[0-9]+$") {

set \$backend_scheme "http";

}



if (\$backend_host = "") {

return 400 "目标地址错误";

}


EOF
# ==============================
# 白名单限制
# ==============================

if [ "$FILTER" = "1" ] && [ -n "$ALLOW_DOMAIN" ];then


cat >> "$NGINX" <<EOF


if (\$backend_host !~ "(^|\\.)($ALLOW_DOMAIN)\$") {

return 403 "目标域名禁止代理";

}


EOF


fi



# ==============================
# 代理参数
# ==============================

cat >> "$NGINX" <<'EOF'


proxy_pass $backend_scheme://$backend_host$backend_uri;


proxy_ssl_server_name on;

proxy_ssl_name $backend_host;

proxy_ssl_verify off;



proxy_set_header Host $backend_host;

proxy_set_header X-Real-IP $remote_addr;


proxy_http_version 1.1;


proxy_set_header Upgrade $http_upgrade;

proxy_set_header Connection "upgrade";



# Emby流媒体支持

proxy_set_header Range $http_range;

proxy_set_header If-Range $http_if_range;

proxy_force_ranges on;



proxy_buffering off;

proxy_request_buffering off;



proxy_read_timeout 43200s;

proxy_send_timeout 43200s;



}

}

EOF



openresty -t || return 1


systemctl restart openresty


green "OpenResty配置完成"


}



# ==============================
# 证书
# ==============================

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



# ==============================
# 安装
# ==============================

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


ALLOW_DOMAIN=""


save


make_nginx



green "安装完成"



echo


echo "访问方式:"


echo


echo "完整:"
echo "http://$DOMAIN/https://目标地址"


echo


echo "简写:"
echo "http://$DOMAIN/目标地址"



pause


}



# ==============================
# 白名单管理
# ==============================

white(){


while true

do


header


echo "访问控制管理"

echo

echo "状态:"


if [ "$FILTER" = "1" ];then

echo "开启"

else

echo "关闭"

fi



echo


echo "当前白名单:"


if [ -z "$ALLOW_DOMAIN" ];then

echo "暂无"

else

echo "$ALLOW_DOMAIN" | tr "|" "\n"

fi



echo

echo "1. 开启白名单"

echo "2. 关闭白名单"

echo "3. 添加域名"

echo "4. 删除域名"

echo "5. 清空白名单"

echo "0. 返回"



echo


read -p "选择:" W



case $W in


1)

FILTER=1

save

make_nginx

green "白名单开启"

;;


2)

FILTER=0

save

make_nginx

yellow "白名单关闭"

;;


3)

read -p "添加域名:" ADD



ADD=$(echo "$ADD" | tr 'A-Z' 'a-z')



if [ -z "$ALLOW_DOMAIN" ];then

ALLOW_DOMAIN="$ADD"

else

ALLOW_DOMAIN="$ALLOW_DOMAIN|$ADD"

fi



save

make_nginx


green "添加成功"


;;
4)

read -p "删除域名:" DEL


NEW=""


IFS="|" read -ra ARR <<< "$ALLOW_DOMAIN"


for i in "${ARR[@]}"
do

if [ "$i" != "$DEL" ] && [ -n "$i" ];then


if [ -z "$NEW" ];then

NEW="$i"

else

NEW="$NEW|$i"

fi


fi


done



ALLOW_DOMAIN="$NEW"



save

make_nginx



green "删除成功"


;;


5)


ALLOW_DOMAIN=""


save

make_nginx



yellow "白名单已清空"



;;


0)

return

;;


*)

red "错误选择"

;;


esac



pause


done


}



# ==============================
# 查看配置
# ==============================

show(){


header


cat "$CONF"



pause


}



# ==============================
# 重载
# ==============================

reload(){


openresty -t && systemctl reload openresty


green "重载完成"


pause


}



# ==============================
# 卸载
# ==============================

remove(){


systemctl stop openresty 2>/dev/null


apt remove --purge -y openresty* 2>/dev/null



rm -rf /usr/local/openresty

rm -rf "$CONF"



green "卸载完成"



pause


}



# ==============================
# 菜单
# ==============================

menu(){


while true

do


header



echo "1. 安装反代"

echo "2. 白名单管理"

echo "3. 查看配置"

echo "4. 重载服务"

echo "5. 卸载"

echo "0. 退出"



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

exit 0

;;


*)

red "错误"

;;

esac



done


}



# ==============================
# 启动
# ==============================

if [ "$(id -u)" != "0" ];then

red "请使用root运行"

exit 1

fi


init

menu
