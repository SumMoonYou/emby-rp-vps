#!/bin/bash

# ==================================================
# Emby Reverse Proxy Manager
# Version: v2.5
#
# 功能:
# - OpenResty官方源安装
# - 通用URL反代
# - 自动协议判断
# - 端口协议判断
# - Emby WebSocket
# - Range流媒体
# - 多域名白名单管理
# ==================================================

VER="v2.5"

CONF="/etc/emby-rp.conf"

NGINX="/usr/local/openresty/nginx/conf/nginx.conf"

SSL="/etc/openresty/ssl"


# ==================================================
# 消息
# ==================================================

ok(){
echo
echo "================================"
echo " ✅ 成功: $1"
echo "================================"
echo
}


err(){
echo
echo "================================"
echo " ❌ 错误: $1"
echo "================================"
echo
}


info(){
echo
echo "================================"
echo " ℹ️ 信息: $1"
echo "================================"
echo
}


warn(){
echo
echo "================================"
echo " ⚠️ 警告: $1"
echo "================================"
echo
}


pause(){
read -p "回车继续..."
}


# ==================================================
# 标题
# ==================================================

header(){

clear

echo "================================"
echo " Emby Reverse Proxy Manager"
echo " Version: $VER"
echo "================================"

echo

}



# ==================================================
# 初始化
# ==================================================

init(){


if [ ! -f "$CONF" ];then


cat > "$CONF" <<EOF
DOMAIN=""
PORT="80"
FILTER="0"
ALLOW_DOMAIN=""
EOF


fi


source "$CONF"


}



# ==================================================
# 保存配置
# ==================================================

save(){


cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
PORT="$PORT"
FILTER="$FILTER"
ALLOW_DOMAIN="$ALLOW_DOMAIN"
EOF


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
gnupg \
lsb-release \
software-properties-common >/dev/null 2>&1

}



# ==================================================
# OpenResty安装
# 保留原版可用方式
# ==================================================

install_openresty(){


command -v openresty >/dev/null && {

info "OpenResty已安装"

return

}



info "安装OpenResty"



wget -qO- https://openresty.org/package/pubkey.gpg | apt-key add -



add-apt-repository \
"deb http://openresty.org/package/debian $(lsb_release -sc) main"



apt update



apt install -y openresty



if ! command -v openresty >/dev/null;then

err "OpenResty安装失败"

return 1

fi



systemctl enable openresty



ok "OpenResty安装完成"



}



# ==================================================
# Nginx配置准备
# ==================================================

prepare_nginx(){


if ! grep -q "conf.d" "$NGINX";then


sed -i '/http {/a\    include /etc/openresty/conf.d/*.conf;' "$NGINX"


fi


mkdir -p /etc/openresty/conf.d


}



# ==================================================
# 生成反代配置
# ==================================================

make_nginx(){


CONF_NGINX="/etc/openresty/conf.d/emby-rp.conf"



cat > "$CONF_NGINX" <<EOF


server {


listen $PORT;


server_name $DOMAIN;



location / {



# 默认HTTPS

set \$backend_scheme https;

set \$backend_host "";

set \$backend_uri "/";



# ======================================
# 地址解析
#
# 支持:
#
# /https://example.com
# /http://example.com
# /example.com
# /example.com/path
# /example.com:8080
#
# ======================================



# 带协议

if (\$request_uri ~ "^/(https?)://([^/]+)(.*)") {


set \$backend_scheme \$1;


set \$backend_host \$2;


set \$backend_uri \$3;


}



# 不带协议

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



EOF
# ==================================================
# 端口判断协议
# ==================================================

cat >> "$CONF_NGINX" <<'EOF'


# 80端口 HTTP

if ($backend_host ~ ":(80)$") {

set $backend_scheme http;

}


# 443端口 HTTPS

if ($backend_host ~ ":(443)$") {

set $backend_scheme https;

}


# 其他端口默认HTTP

if ($backend_host ~ ":[0-9]+$") {

set $backend_scheme http;

}


# 地址为空

if ($backend_host = "") {

return 400 "目标地址为空";

}


EOF



# ==================================================
# 白名单
# ==================================================

if [ "$FILTER" = "1" ] && [ -n "$ALLOW_DOMAIN" ];then


cat >> "$CONF_NGINX" <<EOF


# 白名单限制

if (\$backend_host !~ "(^|\\.)($ALLOW_DOMAIN)\$") {

return 403 "目标域名禁止代理";

}


EOF


fi



# ==================================================
# 代理参数
# ==================================================

cat >> "$CONF_NGINX" <<'EOF'


# 反代

proxy_pass $backend_scheme://$backend_host$backend_uri;



# HTTPS SNI

proxy_ssl_server_name on;

proxy_ssl_name $backend_host;

proxy_ssl_verify off;



# 请求头

proxy_set_header Host $backend_host;

proxy_set_header X-Real-IP $remote_addr;

proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;



# WebSocket

proxy_http_version 1.1;

proxy_set_header Upgrade $http_upgrade;

proxy_set_header Connection "upgrade";



# 视频拖动

proxy_set_header Range $http_range;

proxy_set_header If-Range $http_if_range;

proxy_force_ranges on;



# 性能优化

proxy_buffering off;

proxy_request_buffering off;


proxy_read_timeout 43200s;

proxy_send_timeout 43200s;



}

}

EOF



openresty -t || {

err "Nginx配置检测失败"

return 1

}



systemctl reload openresty



ok "配置更新完成"


}



# ==================================================
# 安装代理
# ==================================================

install(){


header


install_pkg


install_openresty || return


prepare_nginx



read -p "请输入代理域名:" DOMAIN



if [ -z "$DOMAIN" ];then

err "域名不能为空"

pause

return

fi



PORT="80"

FILTER="0"

ALLOW_DOMAIN=""


save


make_nginx



ok "Emby反代安装完成"



echo

echo "使用方式:"

echo

echo "完整地址:"
echo "http://$DOMAIN/https://example.com"

echo

echo "简写地址:"
echo "http://$DOMAIN/example.com"

echo

echo "带端口:"
echo "http://$DOMAIN/example.com:8080"


pause


}



# ==================================================
# 白名单管理
# ==================================================

white(){


while true

do


header


echo "========== 白名单管理 =========="

echo


echo "状态:"

if [ "$FILTER" = "1" ];then

echo "开启"

else

echo "关闭"

fi



echo


echo "当前域名:"



if [ -z "$ALLOW_DOMAIN" ];then

echo "暂无"

else

echo "$ALLOW_DOMAIN" | tr "|" "\n" | nl

fi



echo

echo "1. 开启"

echo "2. 关闭"

echo "3. 添加域名"

echo "4. 删除域名"

echo "5. 查看列表"

echo "6. 清空列表"

echo "0. 返回"



echo


read -p "选择:" W



case $W in


1)

FILTER=1

save

make_nginx

ok "白名单开启"

sleep 1

;;


2)

FILTER=0

save

make_nginx

info "白名单关闭"

sleep 1

;;


3)

read -p "输入域名:" ADD



ADD=$(echo "$ADD" | tr 'A-Z' 'a-z')

ADD=${ADD#.}



if [[ "|$ALLOW_DOMAIN|" == *"|$ADD|"* ]];then

warn "已存在"

else


if [ -z "$ALLOW_DOMAIN" ];then

ALLOW_DOMAIN="$ADD"

else

ALLOW_DOMAIN="$ALLOW_DOMAIN|$ADD"

fi



save

make_nginx


ok "添加成功"


fi


sleep 1

;;
4)

read -p "删除域名:" DEL


DEL=$(echo "$DEL" | tr 'A-Z' 'a-z')

DEL=${DEL#.}



NEW_LIST=""


IFS="|" read -ra LIST <<< "$ALLOW_DOMAIN"



for ITEM in "${LIST[@]}"
do

if [ "$ITEM" != "$DEL" ] && [ -n "$ITEM" ];then


if [ -z "$NEW_LIST" ];then

NEW_LIST="$ITEM"

else

NEW_LIST="$NEW_LIST|$ITEM"

fi


fi

done



ALLOW_DOMAIN="$NEW_LIST"


save

make_nginx


ok "删除成功"


sleep 1

;;


5)


echo

echo "当前白名单:"


if [ -z "$ALLOW_DOMAIN" ];then

echo "暂无"

else

echo "$ALLOW_DOMAIN" | tr "|" "\n"

fi


pause

;;


6)


ALLOW_DOMAIN=""


save

make_nginx


warn "白名单已清空"


sleep 1

;;


0)

return

;;


*)

err "错误选项"

sleep 1

;;


esac


done


}



# ==================================================
# 查看配置
# ==================================================

show(){


header


echo "========== 当前配置 =========="

echo


cat "$CONF"



pause


}



# ==================================================
# 重载
# ==================================================

reload(){


if openresty -t;then


systemctl reload openresty


ok "重载完成"


else


err "配置错误"


fi



pause


}



# ==================================================
# 状态
# ==================================================

status(){


header


systemctl status openresty --no-pager


pause


}



# ==================================================
# 卸载
# ==================================================

remove(){


header


read -p "确认卸载?(y/N): " R



[ "$R" != "y" ] && [ "$R" != "Y" ] && return



systemctl stop openresty 2>/dev/null



apt remove --purge -y openresty* 2>/dev/null



rm -rf /usr/local/openresty

rm -rf /etc/openresty/conf.d/emby-rp.conf

rm -rf "$CONF"



ok "卸载完成"



pause


}



# ==================================================
# 菜单
# ==================================================

menu(){


while true

do


header


echo "========== 管理菜单 =========="

echo

echo "1. 安装反向代理"

echo "2. 白名单管理"

echo "3. 查看配置"

echo "4. 重载服务"

echo "5. 查看状态"

echo "6. 卸载程序"

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

status

;;


6)

remove

;;


0)

exit 0

;;


*)

err "无效选择"

sleep 1

;;

esac


done


}



# ==================================================
# 启动
# ==================================================

if [ "$(id -u)" != "0" ];then

err "请使用root运行"

exit 1

fi


init

menu
