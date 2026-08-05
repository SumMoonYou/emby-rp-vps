#!/bin/bash

# ==================================================
# Emby 动态反代管理脚本
# Version: v2.1
# ==================================================
#
# 更新：
# 1. 支持固定 Emby 反代模式
# 2. 保留动态 URL 代理模式
# 3. 修复 Emby APP / TV 客户端兼容问题
# 4. WebSocket / Range 优化
# 5. SSRF 防护
# 6. IPv4 + IPv6
# 7. HTTPS 自动证书
#
# 系统:
# Debian / Ubuntu
#
# ==================================================

VER="v2.1"

# ================= 路径 =================

CONF="/etc/emby-rp.conf"

NGINX="/usr/local/openresty/nginx/conf/nginx.conf"

LUA="/usr/local/openresty/nginx/conf/lua_init.lua"

SSL_DIR="/usr/local/openresty/nginx/conf/ssl"

ACME_HOME="/root/.acme.sh"

ACME_WEBROOT="/var/www/acme"


# ================= 颜色 =================

green(){
echo -e "\033[32m$1\033[0m"
}

red(){
echo -e "\033[31m$1\033[0m"
}

yellow(){
echo -e "\033[33m$1\033[0m"
}

blue(){
echo -e "\033[36m$1\033[0m"
}


pause(){

echo

read -p "💡 按回车返回菜单..."

}


header(){

clear

echo "=================================================="
echo " 🚀 Emby 动态反代管理面板 $VER"
echo "=================================================="
echo

}



# ================= 初始化配置 =================

init(){

if [ ! -f "$CONF" ];then

cat > "$CONF" <<EOF
DOMAIN=""
HTTPS="0"
FILTER="1"
ALLOW_DOMAIN=""
EMBY_TARGET=""
EOF

fi


source "$CONF"


[ -z "$HTTPS" ] && HTTPS="0"

[ -z "$FILTER" ] && FILTER="1"

[ -z "$ALLOW_DOMAIN" ] && ALLOW_DOMAIN=""

[ -z "$EMBY_TARGET" ] && EMBY_TARGET=""


}



save(){

cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
HTTPS="$HTTPS"
FILTER="$FILTER"
ALLOW_DOMAIN="$ALLOW_DOMAIN"
EMBY_TARGET="$EMBY_TARGET"
EOF

}



# ================= 基础依赖 =================

install_pkg(){

blue "正在安装系统依赖..."


apt update >/dev/null 2>&1


apt install -y \
curl \
wget \
socat \
gnupg2 \
ca-certificates \
lsb-release \
cron \
openssl \
logrotate \
fuser \
>/dev/null 2>&1


green "依赖安装完成"

}



# ================= OpenResty =================


install_openresty(){


if command -v openresty >/dev/null 2>&1;then

green "OpenResty 已安装"

return

fi



blue "正在安装 OpenResty..."



CODENAME=$(lsb_release -sc)



wget -qO- https://openresty.org/package/pubkey.gpg \
| gpg --dearmor \
-o /usr/share/keyrings/openresty.gpg



echo \
"deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/debian $CODENAME openresty" \
> /etc/apt/sources.list.d/openresty.list



apt update

apt install -y openresty



if ! command -v openresty >/dev/null;then

red "OpenResty安装失败"

return 1

fi



systemctl enable openresty >/dev/null 2>&1


green "OpenResty安装完成"


}



# ================= acme.sh =================


install_acme(){


if [ -f "$ACME_HOME/acme.sh" ];then

return

fi



blue "安装 acme.sh..."


curl https://get.acme.sh | sh \
-s email=admin@$DOMAIN \
>/dev/null 2>&1



"$ACME_HOME/acme.sh" \
--set-default-ca \
--server letsencrypt \
>/dev/null 2>&1



}


# ================= 证书申请 =================

issue_cert(){

local domain="$1"

mkdir -p "$SSL_DIR"
mkdir -p "$ACME_WEBROOT"


blue "正在申请 HTTPS 证书: $domain"



# 备份当前配置

[ -f "$NGINX" ] && cp "$NGINX" "$NGINX.bak"



cat > "$NGINX" <<EOF
worker_processes auto;

events {
    worker_connections 1024;
}

http {

server {

listen 80;
listen [::]:80;

server_name $domain;


location /.well-known/acme-challenge/ {

root $ACME_WEBROOT;

}


location / {

return 200 "acme";

}

}

}
EOF



systemctl restart openresty


sleep 2



"$ACME_HOME/acme.sh" \
--issue \
-d "$domain" \
-w "$ACME_WEBROOT" \
--keylength 2048 \
--force



if [ $? -ne 0 ];then


yellow "webroot失败，尝试standalone"


systemctl stop openresty


"$ACME_HOME/acme.sh" \
--issue \
-d "$domain" \
--standalone \
--keylength 2048 \
--force



if [ $? -ne 0 ];then

red "证书申请失败"


# 恢复配置

[ -f "$NGINX.bak" ] && mv "$NGINX.bak" "$NGINX"


systemctl restart openresty


return 1

fi


fi




"$ACME_HOME/acme.sh" \
--install-cert \
-d "$domain" \
--key-file "$SSL_DIR/$domain.key" \
--fullchain-file "$SSL_DIR/$domain.fullchain.pem" \
--reloadcmd "systemctl reload openresty"



chmod 600 "$SSL_DIR/$domain.key"


green "证书安装成功"


}



# ================= Lua初始化 =================


write_lua(){


mkdir -p "$(dirname "$LUA")"


cat > "$LUA" <<EOF

local dict=ngx.shared.emby_config


dict:set(
"filter",
"$FILTER"
)


dict:set(
"domains",
"$ALLOW_DOMAIN"
)


dict:set(
"emby",
"$EMBY_TARGET"
)


EOF


}



# ================= 日志管理 =================


write_logrotate(){


cat > /etc/logrotate.d/emby-proxy <<EOF

/usr/local/openresty/nginx/logs/*.log {

daily

rotate 7

compress

missingok

notifempty

}

EOF


}



# ================= 配置备份 =================


backup_nginx(){


if [ -f "$NGINX" ];then

cp "$NGINX" "$NGINX.bak"

fi


}



# ================= Emby配置管理 =================


emby_manage(){


while true

do


header


echo "🎬 Emby源站管理"

echo "------------------------------"


if [ -z "$EMBY_TARGET" ];then

yellow "当前: 未启用固定模式"

else

green "当前: $EMBY_TARGET"

fi



echo

echo "[1] 设置Emby源站"

echo "[2] 清除固定模式"

echo "[0] 返回"



read -p "选择: " E



case $E in


1)

read -p "输入Emby地址:
" EMBY_TARGET


save

make_nginx


;;


2)

EMBY_TARGET=""

save

make_nginx


;;


0)

return


;;


esac



done


}


# ================= 动态反代核心 =================

gen_proxy_location(){

cat <<'LOC'

location / {


set $upstream "";
set $target_host "";
set $target_scheme "";


rewrite_by_lua_block {


local uri=ngx.var.request_uri

local path,args=uri:match("^([^?]*)%??(.*)$")


local dict=ngx.shared.emby_config


local target=""


------------------------------------------------
-- 固定 Emby 模式
------------------------------------------------


local emby=dict:get("emby")


if emby and emby~="" then


    if path=="/" then

        target=emby

    else

        target=emby..path

    end


else


------------------------------------------------
-- 动态 URL 模式
------------------------------------------------


    target=path:sub(2)


    if target=="" then


        ngx.status=400

        ngx.header.content_type="text/plain;charset=utf-8"

        ngx.say(
        "❌ 缺少目标地址\n\n格式:\nhttps://域名/https://目标地址"
        )

        return ngx.exit(400)

    end



    if not target:match("^https?://") then

        target="https://"..target

    end


end




------------------------------------------------
-- URL解析
------------------------------------------------


local scheme,host,newpath=
target:match("^(https?://)([^/]+)(.*)")



if not host then


ngx.status=400

ngx.say("❌ 地址解析失败")

return ngx.exit(400)


end



host=host:lower()



------------------------------------------------
-- SSRF 防护
------------------------------------------------


local block={

"localhost",

"127.",

"10.",

"192.168.",

"169.254.",

"172.16.",

"172.17.",

"172.18.",

"172.19.",

"172.20.",

"172.21.",

"172.22.",

"172.23.",

"172.24.",

"172.25.",

"172.26.",

"172.27.",

"172.28.",

"172.29.",

"172.30.",

"172.31."

}



for _,v in ipairs(block) do


if host:find(v,1,true) then


ngx.status=403

ngx.say("❌ 禁止访问内网地址")

return ngx.exit(403)


end


end




------------------------------------------------
-- 白名单
------------------------------------------------


if dict:get("filter")=="1" then


local allow=false


for d in string.gmatch(
dict:get("domains") or "",
"[^|]+"
)
do


d=d:lower()


if host==d or
host:sub(-#d-1)=="."..d then


allow=true

break


end


end



if not allow then


ngx.status=403

ngx.say("❌ 域名不在白名单")

return ngx.exit(403)


end


end




if newpath=="" then

newpath="/"

end



ngx.req.set_uri(newpath)



if args and args~="" then

ngx.req.set_uri_args(args)

end




ngx.var.target_host=host

ngx.var.target_scheme=
scheme:gsub("://","")

ngx.var.upstream=
scheme..host



}



proxy_pass $upstream;



# Emby Header

proxy_set_header Host $target_host;


proxy_set_header X-Real-IP $remote_addr;


proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;


proxy_set_header X-Forwarded-Host $host;


proxy_set_header X-Forwarded-Port $server_port;


proxy_set_header X-Forwarded-Proto $scheme;



# WebSocket

proxy_http_version 1.1;


proxy_set_header Upgrade $http_upgrade;


proxy_set_header Connection $connection_upgrade;



# 视频播放

proxy_set_header Range $http_range;


proxy_set_header If-Range $http_if_range;


proxy_force_ranges on;



# 性能

proxy_buffering off;


proxy_request_buffering off;


proxy_max_temp_file_size 0;



proxy_connect_timeout 10s;


proxy_send_timeout 86400s;


proxy_read_timeout 86400s;



# HTTPS源站

proxy_ssl_server_name on;


proxy_ssl_name $target_host;


proxy_ssl_verify off;



}



LOC

}

# ================= nginx配置生成 =================

make_nginx(){


write_lua

backup_nginx


PROXY_LOC=$(gen_proxy_location)



if [ "$HTTPS" = "1" ];then


cat > "$NGINX" <<EOF

worker_processes auto;


events {

worker_connections 4096;

}


http {


include mime.types;

default_type application/octet-stream;



# WebSocket

map \$http_upgrade \$connection_upgrade {

default upgrade;

'' close;

}



lua_shared_dict emby_config 10m;


init_by_lua_file $LUA;



# DNS解析

resolver 1.1.1.1 8.8.8.8 valid=300s;


resolver_timeout 5s;




sendfile on;

tcp_nopush on;

tcp_nodelay on;


keepalive_timeout 65;


client_max_body_size 0;



server {


listen 80;

listen [::]:80;


server_name $DOMAIN;



location /.well-known/acme-challenge/ {


root $ACME_WEBROOT;


}



location / {


return 301 https://\$host\$request_uri;


}


}




server {


listen 443 ssl;

listen [::]:443 ssl;


http2 on;



server_name $DOMAIN;



ssl_certificate $SSL_DIR/$DOMAIN.fullchain.pem;


ssl_certificate_key $SSL_DIR/$DOMAIN.key;




ssl_protocols TLSv1.2 TLSv1.3;



ssl_session_cache shared:SSL:10m;


ssl_session_timeout 1d;


ssl_session_tickets off;




add_header Strict-Transport-Security "max-age=31536000" always;




$PROXY_LOC



}



}


EOF



else



cat > "$NGINX" <<EOF


worker_processes auto;



events {

worker_connections 4096;

}



http {



include mime.types;


default_type application/octet-stream;




map \$http_upgrade \$connection_upgrade {


default upgrade;


'' close;


}





lua_shared_dict emby_config 10m;



init_by_lua_file $LUA;



resolver 1.1.1.1 8.8.8.8 valid=300s;


resolver_timeout 5s;



sendfile on;


tcp_nopush on;


tcp_nodelay on;



keepalive_timeout 65;



client_max_body_size 0;




server {


listen 80;


listen [::]:80;



server_name $DOMAIN;



$PROXY_LOC



}



}



EOF



fi




# 检查配置


if ! openresty -t;then


red "❌ nginx配置错误"


return 1


fi



systemctl reload openresty



write_logrotate



green "✅ OpenResty配置更新完成"


}

# ================= 安装初始化 =================

install(){

header


install_pkg


install_openresty || {
pause
return
}



read -p "🌐 输入反代域名: " DOMAIN


if [ -z "$DOMAIN" ];then

red "域名不能为空"

pause

return

fi



echo

read -p "🎬 Emby源站地址(可选，例如 https://emby.xxx.com): " EMBY_TARGET



echo

read -p "是否开启HTTPS证书?(y/N): " SSL



if [[ "$SSL" == "y" || "$SSL" == "Y" ]];then

HTTPS="1"

else

HTTPS="0"

fi




FILTER="1"


save



if [ "$HTTPS" = "1" ];then


install_acme


issue_cert "$DOMAIN"



if [ $? -ne 0 ];then

yellow "证书失败，切换HTTP"

HTTPS="0"

save

fi



fi



make_nginx



green "================================"

green "🎉 部署完成"


echo


if [ -n "$EMBY_TARGET" ];then


echo "Emby访问地址:"


echo "https://$DOMAIN"



else


echo "动态代理地址:"


echo "https://$DOMAIN/https://目标地址"



fi



green "================================"



pause


}



# ================= 白名单管理 =================

white(){


while true

do


header


echo "🛡 白名单管理"

echo "-----------------------------"



echo "当前状态: $FILTER"


echo


echo "当前域名:"


echo "${ALLOW_DOMAIN:-无}"



echo


echo "[1] 开启"

echo "[2] 关闭"

echo "[3] 添加"

echo "[4] 删除"

echo "[5] 清空"

echo "[0] 返回"



read -p "选择: " W



case $W in



1)

FILTER="1"

;;



2)

FILTER="0"

;;



3)


read -p "输入域名: " ADD



if [ -n "$ADD" ];then


if [ -z "$ALLOW_DOMAIN" ];then

ALLOW_DOMAIN="$ADD"

else

ALLOW_DOMAIN="$ALLOW_DOMAIN|$ADD"

fi



fi



;;



4)


read -p "删除域名: " DEL


NEW=""


IFS="|" read -ra ARR <<< "$ALLOW_DOMAIN"



for d in "${ARR[@]}"

do


[ "$d" = "$DEL" ] && continue



[ -z "$NEW" ] && NEW="$d" || NEW="$NEW|$d"



done



ALLOW_DOMAIN="$NEW"



;;



5)

ALLOW_DOMAIN=""

;;



0)

save

make_nginx

return

;;



esac



save

make_nginx



done


}



# ================= 查看配置 =================

show(){


header



echo "当前配置"

echo "----------------------"


echo "域名: $DOMAIN"


echo "HTTPS: $HTTPS"


echo "白名单: $FILTER"


echo "允许域名: ${ALLOW_DOMAIN:-无}"


echo "Emby源站: ${EMBY_TARGET:-未设置}"



echo



if [ -f "$SSL_DIR/$DOMAIN.fullchain.pem" ];then


echo "证书:"


openssl x509 \
-in "$SSL_DIR/$DOMAIN.fullchain.pem" \
-noout \
-enddate 2>/dev/null


fi



pause



}


# ================= 重载服务 =================

reload(){

header


if openresty -t;then


systemctl reload openresty


green "✅ 重载成功"


else


red "❌ 配置检测失败"


fi



pause


}



# ================= 更新证书 =================

renew_cert(){


header



if [ -z "$DOMAIN" ];then


red "请先安装配置"



pause

return


fi



install_acme


issue_cert "$DOMAIN"



if [ $? -eq 0 ];then


make_nginx


green "✅ 证书更新完成"


else


red "❌ 更新失败"


fi



pause


}



# ================= 卸载 =================

remove(){


header


yellow "即将删除："

echo

echo "OpenResty"

echo "反代配置"

echo "SSL证书"

echo "acme.sh"

echo "配置文件"



echo


read -p "确认卸载?(y/N): " R



if [[ "$R" != "y" && "$R" != "Y" ]];then

return

fi



systemctl stop openresty 2>/dev/null


systemctl disable openresty 2>/dev/null



apt remove --purge -y openresty* \
>/dev/null 2>&1



apt autoremove -y \
>/dev/null 2>&1



rm -rf \

"$SSL_DIR" \

"$ACME_HOME" \

"$ACME_WEBROOT" \

"$CONF"



rm -f "$NGINX"



rm -f /etc/logrotate.d/emby-proxy


green "卸载完成"


pause



}



# ================= 主菜单 =================

menu(){


while true

do


header


echo "[1] 🚀 安装/初始化"

echo "[2] 🎬 Emby源站管理"

echo "[3] 🛡 白名单管理"

echo "[4] 🔍 查看配置"

echo "[5] 🔄 重载服务"

echo "[6] 🔐 更新证书"

echo "[7] 🗑 卸载"

echo "[0] 退出"



echo


read -p "请选择: " M



case $M in


1)

install

;;


2)

emby_manage

;;


3)

white

;;


4)

show

;;


5)

reload

;;


6)

renew_cert

;;


7)

remove

;;


0)

clear

exit 0

;;


*)

red "输入错误"

;;


esac



done


}



# ================= 入口 =================


if [ "$(id -u)" != "0" ];then


red "❌ 请使用root运行"


exit 1


fi



init


menu
