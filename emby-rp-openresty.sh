#!/bin/bash

# ==================================================
# Emby Proxy Lite v1.3
# OpenResty + Lua Dynamic Proxy
# Full Manager
# ==================================================

set -e


APP="Emby Proxy Lite"

VERSION="1.3"



BASE_DIR="/etc/emby-proxy"

CONF_DIR="/etc/openresty/conf.d"

LUA_DIR="/etc/openresty/lua"

SSL_DIR="/etc/openresty/ssl"

WEBROOT="/var/www/html"


CONFIG="$BASE_DIR/config.conf"

WHITELIST="$BASE_DIR/whitelist.conf"





# ===============================
# 基础函数
# ===============================


pause(){

echo

read -p "按回车继续..."

}




check_root(){

if [ "$(id -u)" != "0" ]; then

echo "请使用root运行"

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


echo "检测系统: $PRETTY_NAME"

}





# ===============================
# 检测安装状态
# ===============================


check_install(){


if command -v openresty >/dev/null 2>&1

then

OPENRESTY=1

else

OPENRESTY=0

fi



if systemctl list-unit-files \
| grep -q openresty

then

SERVICE=1

else

SERVICE=0

fi



}




# ===============================
# 查看状态
# ===============================


status(){


check_install


echo

echo "=============================="

echo "$APP v$VERSION"

echo "=============================="



if [ "$OPENRESTY" = "1" ]

then

echo "OpenResty : 已安装"

else

echo "OpenResty : 未安装"

fi




if systemctl is-active --quiet openresty

then

echo "服务状态 : 运行中"

else

echo "服务状态 : 未运行"

fi




if [ -f "$SSL_DIR/fullchain.pem" ]

then

echo "SSL : 已配置"

else

echo "SSL : 未配置"

fi




if [ -f "$CONFIG" ]

then

echo "配置 : 正常"

else

echo "配置 : 缺失"

fi



echo "=============================="



pause

}




# ===============================
# 创建目录
# ===============================


init_dir(){


mkdir -p "$BASE_DIR"

mkdir -p "$CONF_DIR"

mkdir -p "$LUA_DIR"

mkdir -p "$SSL_DIR"

mkdir -p "$WEBROOT/.well-known/acme-challenge"


}




# ===============================
# 端口检测
# ===============================


check_port(){


echo "检测端口..."



if ss -lntp | grep -q ":80 "

then

echo

echo "警告:80端口已经被占用"

ss -lntp | grep ":80 "

echo

fi



if ss -lntp | grep -q ":443 "

then

echo

echo "警告:443端口已经被占用"

ss -lntp | grep ":443 "

echo

fi



}
# ===============================
# OpenResty安装
# ===============================

install_openresty(){


check_install



if [ "$OPENRESTY" = "1" ]; then


echo "检测到 OpenResty 已安装"

echo "执行配置修复模式"


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

echo "不支持系统:$OS"

exit 1


;;

esac



}




# ===============================
# 完全卸载
# ===============================


uninstall(){


echo

echo "即将完全删除:"
echo "- Emby Proxy配置"
echo "- OpenResty"
echo "- SSL证书"
echo "- acme.sh"



read -p "输入 YES 确认:" OK



if [ "$OK" != "YES" ]; then

echo "取消"

pause

return

fi



echo "停止服务..."



systemctl stop openresty 2>/dev/null || true


systemctl disable openresty 2>/dev/null || true



systemctl stop nginx 2>/dev/null || true





echo "删除文件..."



rm -rf "$BASE_DIR"

rm -rf "/etc/openresty"

rm -rf "$SSL_DIR"

rm -rf "$WEBROOT/.well-known"



echo "删除acme.sh"



rm -rf /root/.acme.sh




echo "卸载软件包..."



case "$OS" in


debian|ubuntu)


apt purge -y openresty* 2>/dev/null || true

apt autoremove -y


;;



centos|rocky|almalinux)


if command -v dnf >/dev/null 2>&1

then

dnf remove -y openresty* 2>/dev/null || true

else

yum remove -y openresty* 2>/dev/null || true

fi


;;


esac




systemctl daemon-reload



echo

echo "======================"

echo "完全卸载完成"

echo "======================"



pause

}




# ===============================
# 配置文件
# ===============================


create_config(){


cat > "$CONFIG" <<EOF

DOMAIN=$DOMAIN

DNS_CACHE=60

EOF





cat > "$WHITELIST" <<EOF

# 白名单控制

# ENABLE=0 不限制

# ENABLE=1 开启限制


ENABLE=0


# 添加允许域名

# emby.example.com


EOF


}
# ===============================
# Lua 动态代理
# ===============================

create_lua(){


cat > "$LUA_DIR/proxy.lua" <<'LUA'


local cache = ngx.shared.domain_cache


local function load_white()


    local enable = cache:get("enable")

    if enable then

        return enable == "1"

    end



    local f = io.open(
        "/etc/emby-proxy/whitelist.conf",
        "r"
    )



    if not f then

        return false

    end



    local enabled = false



    for line in f:lines() do


        line=line:gsub("%s+","")



        if line=="ENABLE=1" then

            enabled=true

            break

        end


    end



    f:close()



    cache:set(
        "enable",
        enabled and "1" or "0",
        60
    )


    return enabled


end




local function check_domain(host)



    local enable=load_white()



    if not enable then

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





if not check_domain(host) then


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


ngx.req.set_header(
    "X-Real-IP",
    ngx.var.remote_addr
)



LUA


}





# ===============================
# SSL webroot
# ===============================

create_ssl(){


echo "检查 acme.sh"



if [ ! -f /root/.acme.sh/acme.sh ]

then

curl https://get.acme.sh | sh

fi




mkdir -p "$WEBROOT/.well-known/acme-challenge"



echo "申请SSL证书..."



/root/.acme.sh/acme.sh \
--issue \
-d "$DOMAIN" \
-w "$WEBROOT"





/root/.acme.sh/acme.sh \
--install-cert \
-d "$DOMAIN" \
--key-file "$SSL_DIR/key.pem" \
--fullchain-file "$SSL_DIR/fullchain.pem" \
--reloadcmd "systemctl reload openresty"



}




# ===============================
# nginx配置
# ===============================

create_nginx(){



mkdir -p "$CONF_DIR"



cat > /etc/openresty/nginx.conf <<EOF


worker_processes auto;

worker_rlimit_nofile 65535;



events {


worker_connections 65535;


}



http {



lua_shared_dict domain_cache 1m;



lua_package_path "$LUA_DIR/?.lua;;";



include mime.types;



include $CONF_DIR/*.conf;



sendfile on;


tcp_nopush on;


tcp_nodelay on;



keepalive_timeout 65;



resolver 1.1.1.1 8.8.8.8 valid=300s;



proxy_buffering off;


proxy_request_buffering off;



proxy_http_version 1.1;




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


listen 443 ssl http2;



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


proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;


proxy_set_header X-Forwarded-Proto https;



proxy_set_header Range \$http_range;


proxy_set_header If-Range \$http_if_range;



proxy_set_header Upgrade \$http_upgrade;


proxy_set_header Connection \$connection_upgrade;




proxy_connect_timeout 30s;


proxy_read_timeout 43200s;


proxy_send_timeout 43200s;



}


}


}


EOF



}
# ===============================
# 安装流程
# ===============================

install(){


echo "开始安装 $APP"



read -p "请输入代理域名: " DOMAIN



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



# 先生成HTTP验证配置

create_nginx



systemctl enable openresty


systemctl restart openresty




create_ssl



create_nginx



openresty -t



systemctl reload openresty




echo

echo "=============================="

echo "安装完成"

echo

echo "代理格式:"

echo "https://$DOMAIN/https://你的Emby地址"

echo

echo "白名单文件:"

echo "$WHITELIST"

echo

echo "=============================="



pause

}





# ===============================
# 修复安装
# ===============================

repair(){


echo "开始修复..."



init_dir


create_config


create_lua


create_nginx



openresty -t



systemctl reload openresty



echo

echo "修复完成"



pause

}





# ===============================
# 重启
# ===============================

restart(){


systemctl restart openresty


echo "已重启"


pause


}





# ===============================
# Reload
# ===============================

reload(){


openresty -t


systemctl reload openresty


echo "Reload完成"



pause


}





# ===============================
# 更新配置
# ===============================

update(){


create_lua


create_nginx



openresty -t



systemctl reload openresty



echo "配置更新完成"



pause


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
# 白名单
# ===============================

whitelist(){



echo


echo "当前白名单:"

cat "$WHITELIST"



echo


echo "1. 编辑"

echo "0. 返回"



read -p "选择:" W



case $W in


1)

nano "$WHITELIST"

systemctl reload openresty

;;


0)

return

;;


esac


}





# ===============================
# 主菜单
# ===============================

menu(){



while true

do


clear



echo "================================"

echo "      $APP v$VERSION"

echo "================================"


echo


echo "1. 安装 Emby Proxy"

echo "2. 完全卸载"

echo "3. 查看状态"

echo "4. 重启服务"

echo "5. Reload配置"

echo "6. 更新配置"

echo "7. 查看日志"

echo "8. 白名单管理"

echo "9. 修复安装"

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

restart

;;


5)

reload

;;


6)

update

;;


7)

logs

;;


8)

whitelist

;;


9)

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
