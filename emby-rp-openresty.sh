#!/bin/bash

# ==================================================
# Emby Proxy Lite v1.4
# OpenResty + Lua Dynamic Proxy
# SSL Webroot
# Universal Linux
# ==================================================

set -e


APP_NAME="Emby Proxy Lite"

VERSION="1.4"


BASE_DIR="/etc/emby-proxy"

CONFIG_FILE="$BASE_DIR/config.conf"

WHITE_FILE="$BASE_DIR/whitelist.conf"


SSL_DIR="/etc/emby-proxy/ssl"


WEBROOT="/var/www/html"



NGINX_CONF=""

NGINX_DIR=""

CONF_DIR=""

LUA_DIR=""



DOMAIN=""





# ===============================
# 基础函数
# ===============================


pause(){

echo

read -p "按回车继续..."

}





check_root(){

if [ "$(id -u)" != "0" ]; then

echo "错误: 请使用root运行"

exit 1

fi

}





check_system(){


if [ ! -f /etc/os-release ]; then

echo "无法识别系统"

exit 1

fi



source /etc/os-release


OS=$ID



echo

echo "系统: $PRETTY_NAME"

}





# ===============================
# OpenResty路径自动检测
# ===============================


detect_path(){


if [ -f /usr/local/openresty/nginx/conf/nginx.conf ]; then


NGINX_DIR="/usr/local/openresty/nginx"

NGINX_CONF="/usr/local/openresty/nginx/conf/nginx.conf"



elif [ -f /etc/openresty/nginx.conf ]; then


NGINX_DIR="/etc/openresty"

NGINX_CONF="/etc/openresty/nginx.conf"



else


NGINX_DIR="/usr/local/openresty/nginx"

NGINX_CONF="/usr/local/openresty/nginx/conf/nginx.conf"



fi



CONF_DIR="$NGINX_DIR/conf.d"

LUA_DIR="$NGINX_DIR/lua"



}



# ===============================
# 状态检测
# ===============================


check_status(){


detect_path



if command -v openresty >/dev/null 2>&1

then

OPENRESTY=1

else

OPENRESTY=0

fi



}





status(){


check_status



echo

echo "=============================="

echo "$APP_NAME v$VERSION"

echo "=============================="



if [ "$OPENRESTY" = "1" ]; then

echo "OpenResty: 已安装"

else

echo "OpenResty: 未安装"

fi



if systemctl is-active --quiet openresty

then

echo "服务: 运行中"

else

echo "服务: 未运行"

fi



if [ -f "$SSL_DIR/fullchain.pem" ]

then

echo "SSL: 已存在"

else

echo "SSL: 未生成"

fi



echo

echo "配置文件:"

echo "$NGINX_CONF"



pause

}





# ===============================
# 创建目录
# ===============================


init_dir(){


detect_path



mkdir -p "$BASE_DIR"

mkdir -p "$CONF_DIR"

mkdir -p "$LUA_DIR"

mkdir -p "$SSL_DIR"

mkdir -p "$WEBROOT/.well-known/acme-challenge"



}





# ===============================
# 端口检查
# ===============================


check_port(){


echo "检测端口..."



if ss -lntp | grep -q ":80 "

then

echo

echo "注意:80端口已占用"

ss -lntp | grep ":80 "

fi




if ss -lntp | grep -q ":443 "

then

echo

echo "注意:443端口已占用"

ss -lntp | grep ":443 "

fi



}
# ===============================
# OpenResty安装
# ===============================

install_openresty(){


check_status



if [ "$OPENRESTY" = "1" ]; then

echo "检测到 OpenResty 已安装"

return

fi



echo "开始安装 OpenResty..."



case "$OS" in



debian|ubuntu)


apt update


apt install -y \
curl \
gnupg2 \
ca-certificates \
lsb-release



curl -fsSL https://openresty.org/package/pubkey.gpg \
| gpg --dearmor \
-o /usr/share/keyrings/openresty.gpg



echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] \
http://openresty.org/package/debian \
$(lsb_release -sc) openresty" \
> /etc/apt/sources.list.d/openresty.list



apt update


apt install -y openresty


;;



centos|rocky|almalinux)


if command -v dnf >/dev/null 2>&1

then


dnf install -y yum-utils curl


yum-config-manager \
--add-repo \
https://openresty.org/package/centos/openresty.repo


dnf install -y openresty



else


yum install -y yum-utils curl


yum-config-manager \
--add-repo \
https://openresty.org/package/centos/openresty.repo


yum install -y openresty



fi


;;



*)

echo "暂不支持系统:$OS"

exit 1

;;


esac


}




# ===============================
# 完全卸载
# ===============================

uninstall(){


echo

echo "将删除:"
echo "OpenResty"
echo "Emby Proxy配置"
echo "SSL证书"
echo "acme.sh"


read -p "输入 YES 确认:" OK



if [ "$OK" != "YES" ]; then

echo "取消"

pause

return

fi




echo "停止服务"



systemctl stop openresty 2>/dev/null || true


systemctl disable openresty 2>/dev/null || true




echo "删除配置"



rm -rf "$BASE_DIR"

rm -rf /usr/local/openresty

rm -rf /etc/openresty



echo "删除acme"



rm -rf /root/.acme.sh




echo "卸载软件"



case "$OS" in


debian|ubuntu)


apt purge -y openresty* 2>/dev/null || true

apt autoremove -y


;;



centos|rocky|almalinux)


dnf remove -y openresty* 2>/dev/null || true


;;



esac




systemctl daemon-reload



echo

echo "卸载完成"



pause


}





# ===============================
# 生成基础配置
# ===============================

create_config(){



cat > "$CONFIG_FILE" <<EOF

DOMAIN=$DOMAIN

EOF





cat > "$WHITE_FILE" <<EOF

# Emby Proxy 白名单

# ENABLE=0 默认不限

# ENABLE=1 开启限制


ENABLE=0



# 添加允许域名

# emby.example.com


EOF


}

# ===============================
# Lua动态代理
# ===============================

create_lua(){


cat > "$LUA_DIR/proxy.lua" <<'LUA'


local cache = ngx.shared.domain_cache



local function white_enable()


local v = cache:get("white_enable")



if v then

return v=="1"

end



local f=io.open(
"/etc/emby-proxy/whitelist.conf",
"r"
)



if not f then

return false

end



local enable=false



for line in f:lines() do


line=line:gsub("%s+","")



if line=="ENABLE=1" then

enable=true

break

end


end



f:close()



cache:set(
"white_enable",
enable and "1" or "0",
60
)



return enable


end






local function check_white(host)



if not white_enable() then

return true

end



local f=io.open(
"/etc/emby-proxy/whitelist.conf",
"r"
)



if not f then

return false

end



local ok=false



for line in f:lines() do


line=line:gsub("%s+","")



if line==host then

ok=true

break

end


end



f:close()



return ok


end






local uri=ngx.var.uri



local target=string.sub(uri,2)




if target=="" then

ngx.exit(400)

end





if not ngx.re.match(
target,
"^https?://"
)

then

ngx.exit(403)

end





local m=ngx.re.match(
target,
"^https?://([^/]+)"
)



if not m then

ngx.exit(400)

end





local host=m[1]




if not check_white(host) then


ngx.status=403

ngx.say("Domain blocked")

ngx.exit(403)


end





ngx.var.backend_host=host




if string.sub(target,1,8)=="https://" then


ngx.var.backend_scheme="https"


else


ngx.var.backend_scheme="http"


end




ngx.req.set_header(
"Host",
host
)



LUA


}







# ===============================
# HTTP临时配置
# 用于申请证书
# ===============================

create_nginx_http(){


cat > "$NGINX_CONF" <<EOF


worker_processes auto;


events {

worker_connections 65535;

}



http {


include mime.types;


server {


listen 80;


server_name $DOMAIN;



location /.well-known/acme-challenge/ {


root $WEBROOT;


}



location / {


return 200 "Emby Proxy SSL Setup";


}



}



}


EOF


}







# ===============================
# SSL证书
# ===============================

create_ssl(){



echo "安装acme.sh"



if [ ! -f /root/.acme.sh/acme.sh ]

then


curl https://get.acme.sh | sh


fi




echo "申请证书..."



/root/.acme.sh/acme.sh \
--issue \
-d "$DOMAIN" \
-w "$WEBROOT"




/root/.acme.sh/acme.sh \
--install-cert \
-d "$DOMAIN" \
--key-file "$SSL_DIR/key.pem" \
--fullchain-file "$SSL_DIR/fullchain.pem"




}
# ===============================
# HTTPS正式配置
# ===============================

create_nginx_https(){


cat > "$NGINX_CONF" <<EOF


worker_processes auto;


worker_rlimit_nofile 65535;



events {


worker_connections 65535;


}




http {



lua_shared_dict domain_cache 1m;



lua_package_path "$LUA_DIR/?.lua;;";



include mime.types;




map \$http_upgrade \$connection_upgrade {


default upgrade;


'' close;


}






server {


listen 80;


server_name $DOMAIN;



location /.well-known/acme-challenge/ {


root $WEBROOT;


}



location / {


return 301 https://\$host\$request_uri;


}



}







server {



listen 443 ssl;


http2 on;



server_name $DOMAIN;




ssl_certificate $SSL_DIR/fullchain.pem;


ssl_certificate_key $SSL_DIR/key.pem;



ssl_protocols TLSv1.2 TLSv1.3;





location / {



set \$backend_scheme "";


set \$backend_host "";




access_by_lua_file $LUA_DIR/proxy.lua;





proxy_pass \$backend_scheme://\$backend_host;





proxy_ssl_server_name on;


proxy_ssl_name \$backend_host;




proxy_set_header Host \$backend_host;


proxy_set_header X-Real-IP \$remote_addr;


proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;


proxy_set_header X-Forwarded-Proto https;





proxy_set_header Upgrade \$http_upgrade;


proxy_set_header Connection \$connection_upgrade;





proxy_set_header Range \$http_range;


proxy_set_header If-Range \$http_if_range;





proxy_connect_timeout 30s;


proxy_read_timeout 43200s;


proxy_send_timeout 43200s;



proxy_buffering off;


proxy_request_buffering off;



}



}



}


EOF



}






# ===============================
# 安装
# ===============================

install(){


echo

echo "开始安装 $APP_NAME"



read -p "请输入代理域名:" DOMAIN



if [ -z "$DOMAIN" ]; then


echo "域名不能为空"

pause

return


fi




check_port



install_openresty



init_dir



create_config



create_lua




echo "生成HTTP验证配置"



create_nginx_http




openresty -t



systemctl enable openresty



systemctl restart openresty




echo "申请SSL"



create_ssl





echo "生成HTTPS配置"



create_nginx_https




openresty -t



systemctl reload openresty




echo

echo "============================"

echo "安装完成"

echo

echo "访问方式:"

echo "https://$DOMAIN/https://你的Emby地址"

echo

echo "白名单:"

echo "$WHITE_FILE"

echo

echo "============================"



pause


}







# ===============================
# 修复
# ===============================

repair(){


echo "修复配置"



init_dir


create_config


create_lua



if [ -f "$SSL_DIR/fullchain.pem" ]

then


create_nginx_https


else


create_nginx_http


fi




openresty -t



systemctl reload openresty



echo "修复完成"



pause


}







# ===============================
# 服务操作
# ===============================

restart(){


systemctl restart openresty


echo "重启完成"


pause


}



reload(){


openresty -t


systemctl reload openresty


echo "Reload完成"


pause


}







# ===============================
# 白名单管理
# ===============================

whitelist(){


nano "$WHITE_FILE"



systemctl reload openresty


}







# ===============================
# 日志
# ===============================

logs(){


journalctl -u openresty \
-n 100 \
--no-pager


pause


}







# ===============================
# 菜单
# ===============================

menu(){



while true

do


clear



echo "=============================="

echo "$APP_NAME v$VERSION"

echo "=============================="



echo

echo "1. 安装"

echo "2. 卸载"

echo "3. 状态"

echo "4. 重启"

echo "5. Reload"

echo "6. 查看日志"

echo "7. 白名单管理"

echo "8. 修复安装"

echo "0. 退出"



echo



read -p "选择:" NUM




case $NUM in


1)

install

;;


2)

uninstall

;;


3)

status

;;


4)

restart

;;


5)

reload

;;


6)

logs

;;


7)

whitelist

;;


8)

repair

;;


0)

exit 0

;;


*)

echo "错误"

sleep 1

;;


esac



done



}







# ===============================
# 启动
# ===============================

check_root

check_system

menu
