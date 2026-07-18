#!/bin/bash

# ======================================
# Emby Proxy Lite v1.0
# OpenResty + Lua Dynamic Proxy
# ======================================

set -e


BASE_DIR="/etc/emby-proxy"
LUA_DIR="/etc/openresty/lua"
SSL_DIR="/etc/openresty/ssl"


CONF="$BASE_DIR/config.conf"
WHITE="$BASE_DIR/whitelist.conf"


OS=""





check_root(){

if [ "$(id -u)" != "0" ]; then

echo "请使用 root 运行"

exit 1

fi

}




check_system(){

if [ -f /etc/os-release ]; then

source /etc/os-release

OS=$ID

else

echo "无法识别系统"

exit 1

fi


}





pause(){

echo

read -p "按回车继续..."

}




status(){

echo

echo "========== 状态 =========="


if command -v openresty >/dev/null 2>&1

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


echo "=========================="

pause

}






restart(){

systemctl restart openresty

echo "已重启"

pause

}





reload(){

openresty -t

systemctl reload openresty

echo "配置已重新加载"

pause

}





logs(){

journalctl -u openresty -n 50 --no-pager

pause

}
# ======================================
# 安装 OpenResty
# ======================================

install_openresty(){


echo "开始安装 OpenResty..."


case "$OS" in


debian|ubuntu)

apt update

apt install -y curl gnupg2 ca-certificates lsb-release


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

if command -v dnf >/dev/null
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




# ======================================
# 初始化目录
# ======================================

init_dir(){


mkdir -p "$BASE_DIR"

mkdir -p "$LUA_DIR"

mkdir -p "$SSL_DIR"


}



# ======================================
# 创建配置
# ======================================


create_config(){


cat > "$CONF" <<EOF

DOMAIN=$DOMAIN

EOF



cat > "$WHITE" <<EOF

# 白名单控制
# ENABLE=0 全部允许
# ENABLE=1 开启限制


ENABLE=0


# 添加允许域名
# emby.example.com


EOF


}



# ======================================
# Lua 动态代理
# ======================================


create_lua(){


cat > "$LUA_DIR/proxy.lua" <<'EOF'


local uri=ngx.var.uri


local target=string.sub(uri,2)



if target=="" then

ngx.exit(400)

end



if not ngx.re.match(target,"^https?://") then

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



-- 白名单检查

local f=io.open(
"/etc/emby-proxy/whitelist.conf",
"r"
)



if f then


local enable=false

local allow=false



for line in f:lines() do


line=line:gsub("%s+","")



if line=="ENABLE=1" then

enable=true


elseif line~="" and
string.sub(line,1,1)~="#" then


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



EOF


}
# ======================================
# 生成 Nginx 配置
# ======================================

create_nginx(){


cat >/etc/openresty/nginx.conf <<EOF


worker_processes auto;

worker_rlimit_nofile 65535;


events {

    worker_connections 65535;

}


http {


    lua_package_path "/etc/openresty/lua/?.lua;;";


    include mime.types;


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


        return 301 https://\$host\$request_uri;


    }





    server {


        listen 443 ssl http2;


        server_name $DOMAIN;



        ssl_certificate /etc/openresty/ssl/fullchain.pem;

        ssl_certificate_key /etc/openresty/ssl/key.pem;


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




            # Emby Range

            proxy_set_header Range \$http_range;

            proxy_set_header If-Range \$http_if_range;



            # WebSocket

            proxy_set_header Upgrade \$http_upgrade;

            proxy_set_header Connection \$connection_upgrade;



            # 长连接

            proxy_connect_timeout 30s;

            proxy_read_timeout 43200s;

            proxy_send_timeout 43200s;



        }

    }

}

EOF


}



# ======================================
# 申请证书
# ======================================

create_ssl(){


echo "安装 acme.sh"


curl https://get.acme.sh | sh



/root/.acme.sh/acme.sh \
--issue \
-d "$DOMAIN" \
--standalone



/root/.acme.sh/acme.sh \
--install-cert \
-d "$DOMAIN" \
--key-file /etc/openresty/ssl/key.pem \
--fullchain-file /etc/openresty/ssl/fullchain.pem


}



# ======================================
# 安装
# ======================================

install(){


read -p "请输入代理域名: " DOMAIN


if [ -z "$DOMAIN" ]; then

echo "域名不能为空"

return

fi



install_openresty


init_dir


create_config


create_lua


create_ssl


create_nginx



openresty -t


systemctl enable openresty

systemctl restart openresty



echo

echo "================================"

echo " Emby Proxy 安装完成"

echo

echo "访问方式:"

echo "https://$DOMAIN/https://你的Emby地址"

echo

echo "================================"


pause


}





# ======================================
# 卸载
# ======================================

uninstall(){


read -p "确认卸载? 输入 YES: " OK


if [ "$OK" != "YES" ]; then

echo "取消"

return

fi



systemctl stop openresty 2>/dev/null || true


systemctl disable openresty 2>/dev/null || true



rm -rf /etc/emby-proxy


rm -rf /etc/openresty/lua/proxy.lua


rm -rf /etc/openresty/ssl



echo "卸载完成"


pause

}





# ======================================
# 主菜单
# ======================================

menu(){


while true

do


clear


echo "================================"

echo "       Emby Proxy Lite v1.0"

echo "================================"


echo

echo "1. 安装 Emby Proxy"

echo "2. 卸载"

echo "3. 查看状态"

echo "4. 重启服务"

echo "5. Reload 配置"

echo "6. 查看日志"

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

logs

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



check_root

check_system

menu
