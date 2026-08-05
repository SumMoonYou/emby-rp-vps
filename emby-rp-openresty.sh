#!/bin/bash
# 动态反代管理器 v3.0

VER="3.0"
CONF="/etc/dproxy.conf"
NGINX="/usr/local/openresty/nginx/conf/nginx.conf"
LUA="/usr/local/openresty/nginx/conf/proxy.lua"
SSL="/usr/local/openresty/nginx/conf/ssl"
ACME="/root/.acme.sh"
WEBROOT="/var/www/acme"

green(){ echo -e "\033[32m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }
blue(){ echo -e "\033[36m$1\033[0m"; }

pause(){ read -p "💡 回车返回..."; }

header(){
clear
echo "================================"
echo " 🚀 动态反代管理器 v$VER"
echo "================================"
}

init(){
if [ ! -f "$CONF" ];then
cat >$CONF <<EOF
DOMAIN=""
TARGET=""
HTTPS="0"
FILTER="0"
ALLOW=""
EOF
fi
source $CONF
}

save(){
cat >$CONF <<EOF
DOMAIN="$DOMAIN"
TARGET="$TARGET"
HTTPS="$HTTPS"
FILTER="$FILTER"
ALLOW="$ALLOW"
EOF
}

check_root(){
[ "$(id -u)" != "0" ]&&{ red "请使用root运行";exit 1; }
}

install_pkg(){
blue "安装依赖..."
apt update >/dev/null 2>&1
apt install -y curl wget socat cron ca-certificates gnupg2 lsb-release openssl >/dev/null 2>&1
green "依赖安装完成"
}

install_openresty(){
if command -v openresty >/dev/null;then
green "OpenResty已安装"
return
fi

blue "安装OpenResty..."

wget -qO- https://openresty.org/package/pubkey.gpg|gpg --dearmor -o /usr/share/keyrings/openresty.gpg

echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/debian $(lsb_release -sc) openresty" >/etc/apt/sources.list.d/openresty.list

apt update
apt install -y openresty

systemctl enable openresty >/dev/null 2>&1

green "OpenResty安装完成"
}

install_acme(){
[ -f "$ACME/acme.sh" ]&&return

curl https://get.acme.sh|sh -s email=admin@$DOMAIN >/dev/null 2>&1

$ACME/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
}

acme_nginx(){
mkdir -p $WEBROOT

cat >$NGINX <<EOF
worker_processes auto;
events{worker_connections 1024;}
http{
server{
listen 80;
listen [::]:80;
server_name $DOMAIN;
location /.well-known/acme-challenge/{
root $WEBROOT;
}
location /{
return 200 "ok";
}
}
}
EOF

openresty -t&&systemctl restart openresty
}

issue_cert(){
mkdir -p $SSL
blue "申请证书..."

acme_nginx

$ACME/acme.sh --issue -d $DOMAIN -w $WEBROOT --keylength 2048

[ $? != 0 ]&&{ red "证书申请失败";return 1; }

$ACME/acme.sh --install-cert -d $DOMAIN \
--key-file $SSL/$DOMAIN.key \
--fullchain-file $SSL/$DOMAIN.pem \
--reloadcmd "systemctl reload openresty"

chmod 600 $SSL/$DOMAIN.key

green "证书安装完成"
}
write_lua(){
cat >$LUA <<'EOF'
local c=ngx.shared.cfg
local uri=ngx.var.uri
local target=uri:sub(2)

if target=="" then target=c:get("target") or "" end

if target=="" then
ngx.status=400
ngx.header.content_type="text/plain;charset=utf-8"
ngx.say("❌ 400 请求错误\n\n缺少目标地址\n\n正确格式:\nhttps://你的域名/https://目标地址")
return ngx.exit(400)
end

if not target:match("^https?://") then
target="https://"..target
end

local scheme,host,path=target:match("^(https?://)([^/]+)(.*)$")

if not host then
ngx.status=400
ngx.say("❌ 地址解析失败")
return ngx.exit(400)
end

host=host:gsub(":.*$","")

local deny={
"127.","10.","192.168.","172.16.","172.17.","172.18.",
"172.19.","172.20.","172.21.","172.22.","172.23.",
"172.24.","172.25.","172.26.","172.27.","172.28.",
"172.29.","172.30.","172.31.","169.254.","localhost"
}

for _,v in ipairs(deny) do
if host:find(v,1,true) then
ngx.status=403
ngx.say("⚠️ 禁止访问内部地址")
return ngx.exit(403)
end
end

if c:get("filter")=="1" then
local ok=false
for d in string.gmatch(c:get("allow") or "","[^|]+") do
if host==d or host:sub(-#d-1)=="."..d then
ok=true
break
end
end
if not ok then
ngx.status=403
ngx.say("⚠️ 403 禁止访问\n\n目标域名不在白名单")
return ngx.exit(403)
end
end

if path=="" then path="/" end

ngx.req.set_uri(path)

ngx.var.up_host=host
ngx.var.up_url=scheme..host
EOF
}


make_nginx(){

write_lua

cat >$NGINX <<EOF
worker_processes auto;

events{
worker_connections 4096;
}

http{

lua_shared_dict cfg 10m;

init_by_lua_file $LUA;

map \$http_upgrade \$connection_upgrade{
default upgrade;
'' close;
}

resolver 1.1.1.1 8.8.8.8 ipv6=on valid=300s;
resolver_timeout 10s;

client_max_body_size 0;

proxy_connect_timeout 10s;
proxy_send_timeout 86400s;
proxy_read_timeout 86400s;

server{

listen 80;
listen [::]:80;

server_name $DOMAIN;

location /.well-known/acme-challenge/{
root $WEBROOT;
}

location /{

rewrite_by_lua_file $LUA;

proxy_pass \$up_url;

proxy_set_header Host \$up_host;

proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Host \$host;
proxy_set_header X-Forwarded-Proto \$scheme;

proxy_http_version 1.1;

proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection \$connection_upgrade;

proxy_ssl_server_name on;
proxy_ssl_name \$up_host;
proxy_ssl_verify off;

proxy_cookie_domain ~.* \$host;
proxy_redirect off;

proxy_set_header Range \$http_range;
proxy_set_header If-Range \$http_if_range;
proxy_force_ranges on;

proxy_buffering off;
proxy_request_buffering off;

}

}

EOF

if [ "$HTTPS" = "1" ];then

cat >>$NGINX <<EOF

server{

listen 443 ssl;
listen [::]:443 ssl;

server_name $DOMAIN;

ssl_certificate $SSL/$DOMAIN.fullchain.pem;
ssl_certificate_key $SSL/$DOMAIN.key;

ssl_protocols TLSv1.2 TLSv1.3;

location /{

rewrite_by_lua_file $LUA;

proxy_pass \$up_url;

proxy_set_header Host \$up_host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

proxy_http_version 1.1;

proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection \$connection_upgrade;

proxy_ssl_server_name on;
proxy_ssl_verify off;

proxy_buffering off;
proxy_request_buffering off;

}

}

EOF

fi

cat >>$NGINX <<EOF

}
EOF

openresty -t && systemctl restart openresty
}
install(){

header
install_pkg
install_openresty

read -p "🌐 输入代理域名: " DOMAIN
[ -z "$DOMAIN" ]&&{ red "域名不能为空";pause;return; }

read -p "🎯 输入默认目标(可空): " TARGET

read -p "🔒 开启HTTPS证书?(y/N): " Y

if [[ "$Y" =~ ^[Yy]$ ]];then
HTTPS="1"
install_acme
issue_cert
else
HTTPS="0"
fi

save

make_nginx

green "🎉 部署完成"

echo
echo "访问方式:"
echo "动态:"
echo "https://$DOMAIN/https://目标地址"

[ -n "$TARGET" ]&&echo "默认:"
[ -n "$TARGET" ]&&echo "https://$DOMAIN"

pause
}


white(){

while true
do

header

echo "🛡 白名单管理"
echo
echo "状态: $FILTER"
echo "列表: ${ALLOW:-无}"
echo
echo "1 开启"
echo "2 关闭"
echo "3 添加"
echo "4 删除"
echo "5 清空"
echo "0 返回"

read -p "选择:" W

case $W in

1)
FILTER="1"
;;

2)
FILTER="0"
;;

3)
read -p "域名:" D

if [ -n "$ALLOW" ];then
ALLOW="$ALLOW|$D"
else
ALLOW="$D"
fi
;;

4)
read -p "删除:" D
ALLOW=$(echo "$ALLOW"|sed "s/$D//g;s/||/|/g;s/^|//;s/|$//")
;;

5)
ALLOW=""
;;

0)
save
make_nginx
return
;;

esac

save

done

}


show(){

header

echo "🌐 域名: $DOMAIN"
echo "🎯 默认目标: ${TARGET:-无}"
echo "🔒 HTTPS: $HTTPS"
echo "🛡 白名单: $FILTER"
echo "📋 列表: ${ALLOW:-无}"

echo

systemctl status openresty --no-pager|head -10

pause
}


reload(){

openresty -t&&systemctl reload openresty

green "配置已重载"

pause

}


renew(){

install_acme

issue_cert

make_nginx

green "证书更新完成"

pause

}


remove(){

read -p "⚠️ 确认卸载?(y/N): " Y

[[ "$Y" =~ ^[Yy]$ ]]||return

systemctl stop openresty

apt remove --purge -y openresty* >/dev/null 2>&1

rm -rf /usr/local/openresty
rm -rf $SSL
rm -f $CONF

green "卸载完成"

pause

}


menu(){

while true
do

header

echo "1 🚀 安装/初始化"
echo "2 🛡 白名单"
echo "3 🔍 查看配置"
echo "4 🔄 重载"
echo "5 🔐 更新证书"
echo "6 🗑 卸载"
echo "0 退出"

read -p "选择:" M

case $M in

1) install ;;
2) white ;;
3) show ;;
4) reload ;;
5) renew ;;
6) remove ;;
0) exit ;;
*) red "错误" ;;

esac

done

}


check_root
init
menu
