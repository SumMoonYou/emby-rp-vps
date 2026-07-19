#!/bin/bash

# ==========================================================
# Emby Proxy Lite v1.6
# OpenResty + Lua Dynamic Proxy
# HTTP / HTTPS Mode
# Let's Encrypt SSL
# Universal Linux
# ==========================================================


set -e


APP_NAME="Emby Proxy Lite"

VERSION="1.6"



BASE_DIR="/etc/emby-proxy"


CONFIG_FILE="$BASE_DIR/config.conf"


WHITE_FILE="$BASE_DIR/whitelist.conf"


SSL_DIR="$BASE_DIR/ssl"


WEBROOT="/var/www/html"



DOMAIN=""

EMAIL=""

PORT="443"

ENABLE_SSL=1



NGINX_DIR=""

NGINX_CONF=""

CONF_DIR=""

LUA_DIR=""





# ===============================
# 基础函数
# ===============================


pause(){

echo

read -p "按回车继续..."

}




msg(){

echo

echo "================================"

echo "$1"

echo "================================"

echo

}






check_root(){


if [ "$(id -u)" != "0" ]

then

echo "❌ 请使用 root 运行"

exit 1

fi


}





check_system(){



if [ ! -f /etc/os-release ]

then

echo "❌ 无法识别系统"

exit 1

fi



source /etc/os-release


OS=$ID



echo

echo "系统检测:"

echo "$PRETTY_NAME"



}




# ===============================
# OpenResty路径检测
# ===============================


detect_path(){



if [ -f /usr/local/openresty/nginx/conf/nginx.conf ]

then



NGINX_DIR="/usr/local/openresty/nginx"

NGINX_CONF="/usr/local/openresty/nginx/conf/nginx.conf"




elif [ -f /etc/openresty/nginx.conf ]

then



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
# 状态显示
# ===============================


status(){


detect_path



msg "$APP_NAME v$VERSION 状态"



echo "版本: v$VERSION"



if command -v openresty >/dev/null 2>&1

then

echo "OpenResty: ✅ 已安装"

else

echo "OpenResty: ❌ 未安装"

fi




if systemctl is-active --quiet openresty

then

echo "服务状态: ✅ 运行中"

else

echo "服务状态: ❌ 未运行"

fi




if [ -f "$SSL_DIR/fullchain.pem" ]

then

echo "SSL: ✅ 已启用"

else

echo "SSL: ⚪ 未启用"

fi




if [ -f "$CONFIG_FILE" ]

then

echo

echo "当前配置:"

cat "$CONFIG_FILE"

fi



pause


}





# ===============================
# 初始化目录
# ===============================


init_dir(){



detect_path



mkdir -p "$BASE_DIR"


mkdir -p "$SSL_DIR"


mkdir -p "$CONF_DIR"


mkdir -p "$LUA_DIR"


mkdir -p "$WEBROOT/.well-known/acme-challenge"



}
# ===============================
# OpenResty安装
# ===============================

install_openresty(){


if command -v openresty >/dev/null 2>&1

then

echo "✅ 检测到 OpenResty 已安装"

return

fi



msg "开始安装 OpenResty"



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


yum install -y yum-utils curl



yum-config-manager \
--add-repo \
https://openresty.org/package/centos/openresty.repo



yum install -y openresty


;;



*)

echo "❌ 暂不支持系统: $OS"

exit 1

;;

esac



echo "✅ OpenResty安装完成"



}








# ===============================
# 完全卸载
# ===============================

uninstall(){



msg "卸载 $APP_NAME"



echo "将删除："

echo " - OpenResty"

echo " - 配置文件"

echo " - SSL证书"

echo " - acme.sh"



read -p "输入 YES 确认:" OK



if [ "$OK" != "YES" ]

then

echo "已取消"

pause

return

fi




systemctl stop openresty 2>/dev/null || true


systemctl disable openresty 2>/dev/null || true




rm -rf "$BASE_DIR"


rm -rf /usr/local/openresty


rm -rf /etc/openresty


rm -rf /root/.acme.sh





case "$OS" in


debian|ubuntu)


apt purge -y openresty* 2>/dev/null || true

apt autoremove -y


;;



centos|rocky|almalinux)


yum remove -y openresty* 2>/dev/null || true


;;



esac




systemctl daemon-reload



echo

echo "✅ 卸载完成"



pause


}








# ===============================
# 保存配置
# ===============================

save_config(){



cat > "$CONFIG_FILE" <<EOF

VERSION=$VERSION

DOMAIN=$DOMAIN

EMAIL=$EMAIL

PORT=$PORT

ENABLE_SSL=$ENABLE_SSL

EOF



}







# ===============================
# 读取配置
# ===============================

load_config(){



if [ -f "$CONFIG_FILE" ]

then


source "$CONFIG_FILE"


fi



}








# ===============================
# 端口输入
# ===============================

input_port(){


echo

echo "请输入监听端口"

echo "默认:443"

echo "如果使用80，将跳过SSL证书"



read -p "端口:" USER_PORT



if [ -n "$USER_PORT" ]

then

PORT=$USER_PORT

fi





if [ "$PORT" = "80" ]

then


ENABLE_SSL=0


echo

echo "检测到80端口"

echo "✅ HTTP模式"

echo "跳过SSL证书申请"


else


ENABLE_SSL=1


echo

echo "HTTPS模式"

echo "将申请SSL证书"


fi



}
# ===============================
# Lua动态代理核心
# ===============================

create_lua(){


cat > "$LUA_DIR/proxy.lua" <<'LUA'


local uri = ngx.var.uri



-- 去掉第一个 /

local target = uri:sub(2)



-- URL解码

target = ngx.unescape_uri(target)





-- 首页检测

if target == "" then


ngx.status = 200

ngx.header.content_type="text/plain; charset=utf-8"


ngx.say(
"Emby Proxy Running\n\n" ..
"使用方法:\n" ..
"https://" ..
ngx.var.host ..
"/https://你的Emby地址"
)


ngx.exit(200)


end






-- 修复浏览器处理问题

target = target:gsub(
"^https:/",
"https://"
)


target = target:gsub(
"^http:/",
"http://"
)







local m = ngx.re.match(

target,

"^(https?)://([^/]+)(.*)"

)






if not m then


ngx.status=400

ngx.header.content_type="text/plain; charset=utf-8"


ngx.say(

"❌ 请求格式错误\n\n" ..

"正确格式:\n" ..

"https://" ..
ngx.var.host ..
"/https://Emby地址"

)


ngx.exit(400)



end






local scheme=m[1]

local host=m[2]

local path=m[3]





-- 白名单检测

local whitelist="/etc/emby-proxy/whitelist.conf"



local f=io.open(
whitelist,
"r"
)




local enabled=false

local allowed=false



if f then


for line in f:lines()

do


line=line:gsub("%s+","")



if line=="ENABLE=1"

then

enabled=true


elseif line==host

then

allowed=true


end



end


f:close()


end





if enabled and not allowed then


ngx.status=403

ngx.header.content_type="text/plain; charset=utf-8"


ngx.say(

"❌ 域名不在白名单\n\n" ..

"当前禁止访问:\n" ..

host ..
"\n\n请添加到:\n" ..

whitelist

)



ngx.exit(403)



end







-- 设置后端变量

ngx.var.backend_scheme=scheme


ngx.var.backend_host=host





if path=="" then

path="/"

end





-- 恢复真实路径

ngx.req.set_uri(path)






-- 请求头优化

ngx.req.set_header(
"Host",
host
)



ngx.req.set_header(
"X-Real-IP",
ngx.var.remote_addr
)



ngx.req.set_header(
"X-Forwarded-For",
ngx.var.proxy_add_x_forwarded_for
)



ngx.req.set_header(
"X-Forwarded-Proto",
scheme
)





-- WebSocket

if ngx.var.http_upgrade then


ngx.req.set_header(
"Upgrade",
ngx.var.http_upgrade
)


ngx.req.set_header(
"Connection",
"upgrade"
)


end




LUA


}
# ===============================
# HTTP配置
# ===============================

create_nginx_http(){



cat > "$NGINX_CONF" <<EOF


worker_processes auto;


events {

worker_connections 65535;

}



http {



lua_shared_dict domain_cache 1m;



lua_package_path "$LUA_DIR/?.lua;;";



include mime.types;





server {



listen $PORT;



server_name $DOMAIN;





location / {


set \$backend_scheme "";

set \$backend_host "";



access_by_lua_file $LUA_DIR/proxy.lua;




proxy_pass \$backend_scheme://\$backend_host;



proxy_set_header Host \$backend_host;


proxy_set_header X-Real-IP \$remote_addr;


proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;



proxy_buffering off;


proxy_request_buffering off;



proxy_read_timeout 43200s;



}



}



}


EOF


}








# ===============================
# SSL申请
# ===============================

create_ssl(){



if [ "$ENABLE_SSL" = "0" ]

then


echo

echo "HTTP模式"

echo "跳过SSL"



return


fi






echo

echo "安装acme.sh"



if [ ! -f /root/.acme.sh/acme.sh ]

then


curl https://get.acme.sh | sh


fi





echo

echo "切换Let's Encrypt"



/root/.acme.sh/acme.sh \
--set-default-ca \
--server letsencrypt





echo

echo "注册证书邮箱"



/root/.acme.sh/acme.sh \
--register-account \
-m "$EMAIL"





echo

echo "申请证书..."



/root/.acme.sh/acme.sh \
--issue \
--force \
-d "$DOMAIN" \
-w "$WEBROOT" \
--server letsencrypt





if [ $? != 0 ]

then


echo

echo "❌ SSL申请失败"

echo

echo "检查:"

echo "1. DNS是否解析到服务器"

echo "2. 80端口是否开放"

echo "3. 防火墙"



exit 1



fi







mkdir -p "$SSL_DIR"




/root/.acme.sh/acme.sh \
--install-cert \
-d "$DOMAIN" \
--key-file "$SSL_DIR/key.pem" \
--fullchain-file "$SSL_DIR/fullchain.pem"



echo "✅ SSL安装完成"



}








# ===============================
# HTTPS配置
# ===============================

create_nginx_https(){



cat > "$NGINX_CONF" <<EOF



worker_processes auto;



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



listen $PORT ssl;


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





proxy_buffering off;


proxy_request_buffering off;



proxy_read_timeout 43200s;


proxy_send_timeout 43200s;



}



}


}



EOF



}
# ===============================
# 安装
# ===============================

install(){


msg "$APP_NAME v$VERSION 安装"



read -p "请输入代理域名:" DOMAIN



if [ -z "$DOMAIN" ]

then


echo "❌ 域名不能为空"

pause

return


fi






input_port






if [ "$ENABLE_SSL" = "1" ]

then



read -p "请输入证书邮箱:" EMAIL



if [ -z "$EMAIL" ]

then


echo "❌ 邮箱不能为空"


pause

return


fi



fi






install_openresty



init_dir



save_config



create_lua





if [ "$ENABLE_SSL" = "1" ]

then


echo

echo "生成临时HTTP配置"



create_nginx_http



openresty -t



systemctl enable openresty


systemctl restart openresty





create_ssl




create_nginx_https




else



echo

echo "生成HTTP配置"



create_nginx_http



fi






openresty -t




if [ $? != 0 ]

then


echo "❌ OpenResty配置错误"

pause

return


fi






systemctl restart openresty





echo

echo "================================"

echo "✅ 安装完成"

echo

echo "版本: v$VERSION"

echo "域名: $DOMAIN"

echo "端口: $PORT"



if [ "$ENABLE_SSL" = "1" ]

then

echo "SSL: 已启用"

else

echo "SSL: 未启用"

fi



echo

echo "访问方式:"

if [ "$ENABLE_SSL" = "1" ]

then

echo "https://$DOMAIN/https://你的Emby地址"

else

echo "http://$DOMAIN/https://你的Emby地址"

fi



echo "================================"



pause


}







# ===============================
# 修复
# ===============================

repair(){



msg "修复配置"



load_config



init_dir



create_lua





if [ "$ENABLE_SSL" = "1" ]

then


create_nginx_https


else


create_nginx_http


fi




openresty -t



if [ $? = 0 ]

then


systemctl reload openresty


echo "✅ 修复完成"



else


echo "❌ 配置错误"



fi



pause


}







# ===============================
# 白名单
# ===============================

whitelist(){


init_dir


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



echo

echo "===================================="

echo "  $APP_NAME"

echo "  Version: v$VERSION"

echo "===================================="



echo

echo "1. 安装代理"

echo "2. 完全卸载"

echo "3. 查看状态"

echo "4. 修复配置"

echo "5. 重启服务"

echo "6. Reload配置"

echo "7. 白名单管理"

echo "8. 查看日志"

echo "0. 退出"



echo



read -p "请选择:" NUM




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

repair

;;



5)

systemctl restart openresty

;;



6)

openresty -t && systemctl reload openresty

;;



7)

whitelist

;;



8)

logs

;;



0)

exit 0

;;



*)

echo "❌ 无效选择"

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
