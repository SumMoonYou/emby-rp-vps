#!/bin/bash

# ==================================================
# Emby Reverse Proxy Manager
# Version: v2.1
#
# 基于 v1.9.1
# 功能:
# 1. 固定80端口
# 2. 自动HTTPS解析
# 3. 支持HTTP/HTTPS目标
# 4. 支持端口判断
# 5. 白名单多域名管理
# 6. OpenResty官方源修复
# ==================================================

VER="v2.2"

CONF="/etc/emby-rp.conf"
NGINX="/usr/local/openresty/nginx/conf/nginx.conf"

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


init(){

[ -f "$CONF" ] || cat > "$CONF" <<EOF
DOMAIN=""
PORT="80"
FILTER="0"
ALLOW_DOMAIN=""
EOF

source "$CONF"

}


save(){

cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
PORT="$PORT"
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



# ==================================================
# 安装依赖
# ==================================================

install_pkg(){

apt update >/dev/null 2>&1

apt install -y \
curl \
wget \
socat \
gnupg2 \
ca-certificates \
software-properties-common \
lsb-release >/dev/null 2>&1

}



# ==================================================
# OpenResty安装
# ==================================================

install_openresty(){

command -v openresty >/dev/null && return


# 删除旧错误源
rm -f /etc/apt/sources.list.d/openresty.list


# 导入官方密钥
wget -qO- https://openresty.org/package/pubkey.gpg | apt-key add -


# 添加官方源
echo "deb http://openresty.org/package/debian $(lsb_release -sc) openresty" \
> /etc/apt/sources.list.d/openresty.list


# 更新本地源
apt update


# 安装
apt install -y openresty


if ! command -v openresty >/dev/null;then

red "OpenResty安装失败"

return 1

fi


systemctl enable openresty

}



# ==================================================
# 生成Nginx配置
# ==================================================

make_nginx(){

cat > "$NGINX" <<EOF

worker_processes auto;


events {

    worker_connections 4096;

}


http {


    include mime.types;


    default_type text/plain;


    charset utf-8;


    # 国外DNS
    resolver 1.1.1.1 8.8.8.8 208.67.222.222 valid=300s ipv6=off;



    server {


        listen 80;


        server_name $DOMAIN;



        location / {


            set \$backend_scheme "https";

            set \$backend_host "";

            set \$backend_uri "/";



            # 带协议

            if (\$request_uri ~ "^/(https?)://([^/]+)(.*)") {

                set \$backend_scheme \$1;

                set \$backend_host \$2;

                set \$backend_uri \$3;

            }



            # 不带协议默认HTTPS

            if (\$backend_host = "") {

                if (\$request_uri ~ "^/([^/]+)(.*)") {

                    set \$backend_host \$1;

                    set \$backend_uri \$2;

                }

            }



            if (\$backend_uri = "") {

                set \$backend_uri "/";

            }



            # 有端口默认HTTP
            if (\$backend_host ~ ":[0-9]+$") {

                set \$backend_scheme "http";

            }



            if (\$backend_host = "") {

                return 400 "目标地址为空";

            }

EOF
# ==================================================
# 白名单过滤
# ==================================================

if [ "$FILTER" = "1" ] && [ -n "$ALLOW_DOMAIN" ];then


cat >> "$NGINX" <<EOF

            if (\$backend_host !~ "(^|\\.)($ALLOW_DOMAIN)\$") {

                return 403 "目标域名不允许代理";

            }

EOF

fi



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
# 安装反代
# ==================================================

install(){


header


install_pkg


install_openresty


if [ $? != 0 ];then

red "安装失败"

pause

return

fi



read -p "代理域名:" DOMAIN



PORT="80"


FILTER="0"


ALLOW_DOMAIN=""


save


make_nginx



green "安装完成"


echo


echo "访问地址:"


echo "http://$DOMAIN/目标地址"


echo


echo "例如:"


echo "http://$DOMAIN/cdn.zhezhi.art"


pause


}



# ==================================================
# 白名单管理
# ==================================================

white(){


while true

do


header


echo "白名单管理"


echo


echo "当前状态:"


if [ "$FILTER" = "1" ];then

echo "开启"

else

echo "关闭"

fi



echo


echo "当前列表:"


if [ -z "$ALLOW_DOMAIN" ];then

echo "暂无"

else

echo "$ALLOW_DOMAIN" | tr "|" "\n"

fi



echo


echo "1.开启"

echo "2.关闭"

echo "3.添加域名"

echo "4.删除域名"

echo "5.清空列表"

echo "0.返回"



echo


read -p "选择:" W



case $W in



1)

FILTER=1

;;



2)

FILTER=0

;;



3)

read -p "输入域名:" ADD


if [ -z "$ALLOW_DOMAIN" ];then

ALLOW_DOMAIN="$ADD"

else

ALLOW_DOMAIN="$ALLOW_DOMAIN|$ADD"

fi

;;



4)

read -p "删除域名:" DEL


NEW=""


IFS="|" read -ra ARR <<< "$ALLOW_DOMAIN"


for ITEM in "${ARR[@]}"
do

if [ "$ITEM" != "$DEL" ] && [ -n "$ITEM" ];then


if [ -z "$NEW" ];then

NEW="$ITEM"

else

NEW="$NEW|$ITEM"

fi


fi

done


ALLOW_DOMAIN="$NEW"

;;



5)

ALLOW_DOMAIN=""

;;



0)

return

;;


*)

red "错误"

;;

esac



save


make_nginx


pause


done


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
# 重载配置
# ==================================================

reload(){

if openresty -t;then

systemctl reload openresty

green "重载成功"

else

red "配置错误"

fi

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

echo "2.白名单管理"

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

exit 0

;;


*)

red "错误"

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
