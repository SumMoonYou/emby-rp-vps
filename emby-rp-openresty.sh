#!/bin/bash

# ==================================================
# Emby Reverse Proxy Manager
# Version: v2.3
# Mode: HTTP ONLY
#
# 功能:
# 1. OpenResty反向代理
# 2. 支持 /域名 和 /http(s)://域名
# 3. 自动协议判断
# 4. 支持端口判断
# 5. Emby WebSocket
# 6. Range流媒体播放
# 7. 多域名白名单
# ==================================================

VER="v2.3"
CONF="/etc/emby-rp.conf"
NGINX_DIR="/etc/openresty/conf.d"
NGINX_CONF="$NGINX_DIR/emby-rp.conf"

# ==============================
# 统一消息
# ==============================

msg_ok(){
echo
echo "================================"
echo " ✅ 成功: $1"
echo "================================"
echo
}

msg_err(){
echo
echo "================================"
echo " ❌ 错误: $1"
echo "================================"
echo
}

msg_warn(){
echo
echo "================================"
echo " ⚠️  警告: $1"
echo "================================"
echo
}

msg_info(){
echo
echo "================================"
echo " ℹ️  信息: $1"
echo "================================"
echo
}

pause(){
read -p "回车继续..."
}

# ==============================
# 标题
# ==============================

header(){
clear
echo "================================"
echo " Emby Reverse Proxy Manager"
echo " Version: $VER"
echo " Mode: HTTP ONLY"
echo "================================"
echo
}

# ==============================
# 初始化配置
# ==============================

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

# ==============================
# 保存配置
# ==============================

save(){

cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
PORT="80"
FILTER="$FILTER"
ALLOW_DOMAIN="$ALLOW_DOMAIN"
EOF

}

# ==============================
# 安装依赖
# ==============================

install_pkg(){

apt update

apt install -y \
curl \
wget \
gnupg \
lsb-release \
software-properties-common

}

# ==============================
# 安装OpenResty
# ==============================

install_openresty(){

command -v openresty >/dev/null && return

wget -qO- https://openresty.org/package/pubkey.gpg | apt-key add -

CODENAME=$(lsb_release -sc)

echo "deb http://openresty.org/package/debian $CODENAME main" \
> /etc/apt/sources.list.d/openresty.list

apt update
apt install -y openresty

systemctl enable openresty

}

# ==============================
# 准备Nginx配置
# ==============================

prepare_nginx(){

mkdir -p "$NGINX_DIR"

MAIN="/usr/local/openresty/nginx/conf/nginx.conf"

if ! grep -q "conf.d" "$MAIN";then
sed -i '/http {/a\    include /etc/openresty/conf.d/*.conf;' "$MAIN"
fi

}

# ==============================
# 生成反代配置
# ==============================

make_nginx(){

cat > "$NGINX_CONF" <<EOF
server {
listen 80;
server_name $DOMAIN;

client_max_body_size 0;

location / {

# 默认HTTPS
set \$backend_scheme "https";
set \$backend_host "";
set \$backend_uri "/";

# ==================================
# 解析目标地址
#
# 支持:
# /https://example.com
# /http://example.com
# /example.com
# /example.com/path
# /example.com:8080
# ==================================

# 带协议解析
if (\$request_uri ~ "^/(https?)://([^/]+)(.*)") {
set \$backend_scheme \$1;
set \$backend_host \$2;
set \$backend_uri \$3;
}

# 不带协议解析
if (\$backend_host = "") {
if (\$request_uri ~ "^/([^/]+)(.*)") {
set \$backend_host \$1;
set \$backend_uri \$2;
}
}

# 空路径补/
if (\$backend_uri = "") {
set \$backend_uri "/";
}

# ==============================
# 根据端口判断协议
# ==============================

# 80端口 HTTP
if (\$backend_host ~ ":(80)\$") {
set \$backend_scheme "http";
}

# 443端口 HTTPS
if (\$backend_host ~ ":(443)\$") {
set \$backend_scheme "https";
}

# 其他端口默认HTTP
if (\$backend_host ~ ":[0-9]+\$") {
set \$backend_scheme "http";
}

# 地址为空禁止
if (\$backend_host = "") {
return 400 "目标地址为空";
}

EOF

# ==============================
# 白名单
# ==============================

if [ "$FILTER" = "1" ] && [ -n "$ALLOW_DOMAIN" ];then

RULE="$ALLOW_DOMAIN"

cat >> "$NGINX_CONF" <<EOF

if (\$backend_host !~ "(^\\.?)($RULE)\$") {
return 403 "目标域名禁止代理";
}

EOF

fi

cat >> "$NGINX_CONF" <<'EOF'

# ==============================
# 代理参数
# ==============================

proxy_pass $backend_scheme://$backend_host$backend_uri;

proxy_ssl_server_name on;
proxy_ssl_name $backend_host;
proxy_ssl_verify off;

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

# 缓冲优化
proxy_buffering on;
proxy_buffers 16 32k;
proxy_buffer_size 64k;

proxy_read_timeout 43200s;
proxy_send_timeout 43200s;

sendfile on;
tcp_nodelay on;

}
}
EOF

openresty -t || {
msg_err "Nginx配置检测失败"
return 1
}

systemctl reload openresty

msg_ok "OpenResty配置完成"

}
# ==================================================
# 安装代理服务
# ==================================================

install(){

header

install_pkg
install_openresty
prepare_nginx

read -p "请输入反代域名:" DOMAIN

if [ -z "$DOMAIN" ];then
msg_err "域名不能为空"
pause
return
fi

PORT="80"
FILTER="0"
ALLOW_DOMAIN=""

save
make_nginx

msg_ok "Emby代理安装完成"

echo "访问方式:"
echo
echo "1. https://目标"
echo "   http://$DOMAIN/https://example.com"
echo
echo "2. 自动HTTPS"
echo "   http://$DOMAIN/example.com"
echo
echo "3. 指定端口"
echo "   http://$DOMAIN/example.com:8080"

pause

}


# ==================================================
# 白名单管理
# ==================================================

white(){

while true
do

header

echo "========== 访问控制管理 =========="
echo

echo "当前状态:"

if [ "$FILTER" = "1" ];then
echo "白名单: 开启"
else
echo "白名单: 关闭"
fi

echo

echo "当前域名:"

if [ -z "$ALLOW_DOMAIN" ];then
echo "暂无"
else
echo "$ALLOW_DOMAIN" | tr "|" "\n" | nl
fi

echo

echo "1. 开启白名单"
echo "2. 关闭白名单"
echo "3. 添加域名"
echo "4. 删除域名"
echo "5. 查看列表"
echo "6. 清空列表"
echo "0. 返回"

echo

read -p "请选择 [0-6]: " W


case $W in

1)

FILTER=1
save
make_nginx
msg_ok "白名单已开启"
sleep 1

;;


2)

FILTER=0
save
make_nginx
msg_info "白名单已关闭"
sleep 1

;;


3)

read -p "输入域名:" ADD

if [ -z "$ADD" ];then
msg_err "域名不能为空"
sleep 1
continue
fi

# 小写处理
ADD=$(echo "$ADD" | tr 'A-Z' 'a-z')

# 删除前导点
ADD=${ADD#.}


if [[ "|$ALLOW_DOMAIN|" == *"|$ADD|"* ]];then

msg_warn "域名已存在"

else

if [ -z "$ALLOW_DOMAIN" ];then
ALLOW_DOMAIN="$ADD"
else
ALLOW_DOMAIN="$ALLOW_DOMAIN|$ADD"
fi

save
make_nginx

msg_ok "添加成功"

fi

sleep 1

;;


4)

read -p "输入删除域名:" DEL


DEL=$(echo "$DEL" | tr 'A-Z' 'a-z')
DEL=${DEL#.}


NEW_LIST=""


IFS="|" read -ra ARR <<< "$ALLOW_DOMAIN"


for ITEM in "${ARR[@]}"
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

msg_ok "删除成功"

sleep 1

;;


5)

if [ -z "$ALLOW_DOMAIN" ];then

msg_info "暂无白名单"

else

echo
echo "当前白名单:"
echo "$ALLOW_DOMAIN" | tr "|" "\n"

fi

pause

;;


6)

ALLOW_DOMAIN=""

save
make_nginx

msg_warn "白名单已清空"

sleep 1

;;


0)

return

;;


*)

msg_err "无效选项"
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

echo

echo "========== Nginx配置 =========="
echo

cat "$NGINX_CONF"

pause

}


# ==================================================
# 重载OpenResty
# ==================================================

reload(){

if openresty -t;then

systemctl reload openresty

msg_ok "配置刷新完成"

else

msg_err "配置检测失败"

fi

pause

}
# ==================================================
# 查看服务状态
# ==================================================

status(){

header

echo "========== OpenResty状态 =========="

systemctl status openresty --no-pager

pause

}


# ==================================================
# 卸载
# ==================================================

remove(){

header

read -p "确认卸载? (y/N): " R


if [ "$R" != "y" ] && [ "$R" != "Y" ];then

msg_info "取消卸载"

pause

return

fi


systemctl stop openresty 2>/dev/null

apt remove --purge -y openresty* 2>/dev/null


rm -rf /usr/local/openresty

rm -rf "$NGINX_CONF"

rm -rf "$CONF"


msg_ok "卸载完成"

pause

}


# ==================================================
# 主菜单
# ==================================================

menu(){

while true
do

header


echo "========== 功能菜单 =========="

echo

echo "1. 安装代理服务"

echo "2. 访问控制管理"

echo "3. 配置文件查看"

echo "4. 服务配置刷新"

echo "5. 服务运行监控"

echo "6. 系统卸载"

echo "0. 退出管理程序"


echo

read -p "请选择 [0-6]: " M


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

msg_info "退出管理程序"

exit 0

;;

*)

msg_err "无效选项"

sleep 1

;;

esac

done

}


# ==================================================
# 启动入口
# ==================================================

if [ "$(id -u)" != "0" ];then

msg_err "请使用root权限运行"

exit 1

fi


init

menu
