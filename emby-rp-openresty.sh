#!/bin/bash

# ==================================================
# Emby Proxy Lite v1.1
# OpenResty + Lua Dynamic Proxy
# HTTPS + Whitelist
# ==================================================

set -e


APP_NAME="Emby Proxy Lite"


BASE_DIR="/etc/emby-proxy"
LUA_DIR="/etc/openresty/lua"
SSL_DIR="/etc/openresty/ssl"
CONF_FILE="$BASE_DIR/config.conf"
WHITE_FILE="$BASE_DIR/whitelist.conf"



# --------------------------
# root检测
# --------------------------

check_root(){

if [ "$(id -u)" != "0" ]; then

echo "请使用 root 运行"

exit 1

fi

}



# --------------------------
# 系统检测
# --------------------------

check_system(){

if [ ! -f /etc/os-release ]; then

echo "无法识别系统"

exit 1

fi


source /etc/os-release


OS=$ID


echo "系统: $OS"

}



# --------------------------
# 暂停
# --------------------------

pause(){

echo

read -p "按回车继续..."

}



# --------------------------
# 状态
# --------------------------

status(){


echo

echo "==============="

echo "$APP_NAME 状态"

echo "==============="



if command -v openresty >/dev/null 2>&1

then

echo "OpenResty : 已安装"

else

echo "OpenResty : 未安装"

fi



if systemctl is-active --quiet openresty

then

echo "服务 : 运行中"

else

echo "服务 : 未运行"

fi



if [ -f "$SSL_DIR/fullchain.pem" ]

then

echo "SSL : 已配置"

else

echo "SSL : 未配置"

fi


pause


}




# --------------------------
# 安装 OpenResty
# --------------------------

install_openresty(){


if command -v openresty >/dev/null 2>&1

then

echo "OpenResty 已存在"

return

fi



echo "安装 OpenResty..."



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

echo "不支持系统: $OS"

exit 1


;;

esac


}



# --------------------------
# 创建目录
# --------------------------

init_dir(){


mkdir -p "$BASE_DIR"

mkdir -p "$LUA_DIR"

mkdir -p "$SSL_DIR"

mkdir -p /var/www/html/.well-known/acme-challenge


}
# --------------------------
# 创建配置文件
# --------------------------

create_config(){


if [ ! -f "$CONF_FILE" ]; then


cat > "$CONF_FILE" <<EOF

DOMAIN=$DOMAIN

EOF


fi




cat > "$WHITE_FILE" <<EOF

# 白名单控制
# ENABLE=0 关闭限制
# ENABLE=1 开启限制


ENABLE=0


# 添加允许域名
# emby.example.com


EOF


}





# --------------------------
# Lua动态代理
# --------------------------

create_lua(){


cat > "$LUA_DIR/proxy.lua" <<'LUA'


local uri = ngx.var.uri


local target = string.sub(uri,2)



if target == "" then

    ngx.exit(400)

end



if not ngx.re.match(target,"^https?://") then

    ngx.exit(403)

end



local m = ngx.re.match(
    target,
    "^https?://([^/]+)"
)



if not m then

    ngx.exit(400)

end



local host = m[1]





-- 白名单检查

local file="/etc/emby-proxy/whitelist.conf"


local f=io.open(file,"r")



if f then


    local enable=false

    local allow=false



    for line in f:lines() do


        line=line:gsub("^%s+","")

        line=line:gsub("%s+$","")



        if line=="ENABLE=1" then


            enable=true



        elseif line~="" 
        and string.sub(line,1,1)~="#" then



            if line==host then

                allow=true

            end


        end


    end



    f:close()



    if enable and not allow then


        ngx.status=403

        ngx.say("Domain blocked")

        ngx.exit(403)


    end


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




# --------------------------
# SSL证书
# webroot模式
# 不占80端口
# --------------------------

create_ssl(){


echo "安装 acme.sh"



if [ ! -f /root/.acme.sh/acme.sh ]; then

curl https://get.acme.sh | sh

fi




mkdir -p /var/www/html/.well-known/acme-challenge





echo "申请证书..."



/root/.acme.sh/acme.sh \
--issue \
-d "$DOMAIN" \
-w /var/www/html





/root/.acme.sh/acme.sh \
--install-cert \
-d "$DOMAIN" \
--key-file "$SSL_DIR/key.pem" \
--fullchain-file "$SSL_DIR/fullchain.pem" \
--reloadcmd "systemctl reload openresty"




}




# --------------------------
# nginx配置
# --------------------------

create_nginx(){


mkdir -p /etc/openresty/conf.d



cat >/etc/openresty/nginx.conf <<EOF


worker_processes auto;


worker_rlimit_nofile 65535;



events {


worker_connections 65535;


}



http {



lua_package_path "/etc/openresty/lua/?.lua;;";



include mime.types;



include /etc/openresty/conf.d/*.conf;



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


root /var/www/html;


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




access_by_lua_file /etc/openresty/lua/proxy.lua;




proxy_pass \$backend_scheme://\$backend_host;




proxy_ssl_server_name on;


proxy_ssl_name \$backend_host;




proxy_set_header Host \$backend_host;


proxy_set_header X-Real-IP \$remote_addr;


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
# --------------------------
# 安装流程
# --------------------------

install(){

echo "开始安装 $APP_NAME"



read -p "请输入代理域名: " DOMAIN



if [ -z "$DOMAIN" ]; then

echo "域名不能为空"

pause

return

fi




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

echo "============================"

echo "安装完成"

echo

echo "访问格式:"

echo "https://$DOMAIN/https://你的Emby地址"

echo

echo "白名单文件:"

echo "$WHITE_FILE"

echo

echo "============================"



pause

}




# --------------------------
# 卸载
# --------------------------

uninstall(){


echo

read -p "确认卸载? 输入 YES: " OK



if [ "$OK" != "YES" ]; then

echo "取消卸载"

pause

return

fi




systemctl stop openresty 2>/dev/null || true


systemctl disable openresty 2>/dev/null || true




rm -rf "$BASE_DIR"

rm -rf "$LUA_DIR/proxy.lua"

rm -rf "$SSL_DIR"



echo

echo "卸载完成"



pause

}




# --------------------------
# 重启
# --------------------------

restart(){


systemctl restart openresty


echo "已重启"



pause


}




# --------------------------
# Reload
# --------------------------

reload(){


openresty -t


systemctl reload openresty



echo "配置已重新加载"


pause

}





# --------------------------
# 更新配置
# --------------------------

update(){


echo "重新生成配置"



create_lua

create_nginx



openresty -t


systemctl reload openresty



echo "更新完成"


pause


}





# --------------------------
# 白名单管理
# --------------------------

whitelist(){


echo

echo "当前白名单:"

cat "$WHITE_FILE"


echo

echo "1. 编辑"

echo "0. 返回"



read -p "选择: " W



case $W in


1)

nano "$WHITE_FILE"

systemctl reload openresty

;;


0)

return

;;


esac


}





# --------------------------
# 主菜单
# --------------------------

menu(){


while true

do


clear


echo "================================"

echo "       Emby Proxy Lite v1.1"

echo "================================"


echo

echo "1. 安装 Emby Proxy"

echo "2. 卸载"

echo "3. 状态"

echo "4. 重启服务"

echo "5. Reload配置"

echo "6. 更新配置"

echo "7. 查看日志"

echo "8. 白名单管理"

echo "0. 退出"



echo

read -p "请选择: " NUM




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


0)

exit 0

;;


*)

echo "错误选择"

sleep 1

;;


esac



done


}




# --------------------------
# 启动
# --------------------------

check_root

check_system

menu
