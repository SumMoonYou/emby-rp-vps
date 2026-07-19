#!/bin/bash

# ==========================================================
# Emby Proxy Manager
# Script Version: v1.8.0
#
# 功能:
#  - 动态URL反代
#  - 支持Emby
#  - 支持WebSocket
#  - 支持大文件Range
#  - 安装/卸载OpenResty
#  - 80/443端口选择
#  - 自动证书
#
# ==========================================================


SCRIPT_NAME="Emby Proxy Manager"
SCRIPT_VERSION="v1.8.0"


CONF="/usr/local/openresty/nginx/conf/nginx.conf"

BACKUP_DIR="/root/emby_proxy_backup"

CONFIG_FILE="/etc/emby_proxy.conf"

SSL_DIR="/etc/openresty/ssl"


pause(){

echo

read -p "按回车继续..."

}



ok(){

echo -e "\033[32m$1\033[0m"

}



err(){

echo -e "\033[31m$1\033[0m"

}



info(){

echo -e "\033[36m$1\033[0m"

}




root_check(){

if [ "$(id -u)" != "0" ];then

err "请使用 root 用户运行"

exit 1

fi

}





show_version(){

echo

echo "================================"

echo "$SCRIPT_NAME"

echo "脚本版本: $SCRIPT_VERSION"

echo "================================"

echo

}





save_config(){


cat > "$CONFIG_FILE" <<EOF

DOMAIN="$DOMAIN"

PORT="$PORT"

EMAIL="$EMAIL"

SCRIPT_VERSION="$SCRIPT_VERSION"

EOF


}



load_config(){


if [ -f "$CONFIG_FILE" ];then

source "$CONFIG_FILE"

fi


}





install_env(){


info "更新软件源..."

apt update



apt install -y \

curl \

wget \

socat \

cron \

software-properties-common



}



install_openresty(){


if command -v openresty >/dev/null 2>&1;then

ok "OpenResty 已安装"

return

fi



info "安装 OpenResty..."



wget -qO - https://openresty.org/package/pubkey.gpg | apt-key add -



add-apt-repository \

"deb http://openresty.org/package/debian $(lsb_release -sc) main"



apt update



apt install -y openresty



systemctl enable openresty



}





uninstall_proxy(){


show_version


echo "正在卸载..."



systemctl stop openresty 2>/dev/null


systemctl disable openresty 2>/dev/null



apt remove --purge -y openresty* 2>/dev/null



rm -rf /usr/local/openresty


rm -rf /etc/openresty


rm -rf /etc/emby_proxy.conf


rm -rf /root/emby_proxy_backup



systemctl daemon-reload



ok "卸载完成"



pause

}





status(){


show_version


if command -v openresty >/dev/null 2>&1

then


openresty -v


echo


systemctl status openresty --no-pager


else


echo "OpenResty 未安装"


fi



pause

}







menu(){


while true

do


clear


show_version



echo "1. 安装反代"

echo "2. 卸载"

echo "3. 状态"

echo "0. 退出"



echo


read -p "请选择: " NUM



case $NUM in


1)

install_proxy

;;


2)

uninstall_proxy

;;


3)

status

;;


0)

exit

;;


*)

echo "输入错误"

sleep 1

;;

esac



done


}

# ==========================================================
# 生成 OpenResty 配置
# ==========================================================


create_nginx(){


info "生成 nginx 配置..."



mkdir -p "$BACKUP_DIR"



if [ -f "$CONF" ];then

cp "$CONF" "$BACKUP_DIR/nginx.conf.$(date +%s)"

fi




cat > "$CONF" <<EOF

worker_processes auto;


events {

    worker_connections 4096;

}



http {


    include mime.types;


    default_type application/octet-stream;



    sendfile on;


    tcp_nopush on;


    keepalive_timeout 65;



    # 动态域名解析

    resolver 223.5.5.5 119.29.29.29 1.1.1.1 valid=300s ipv6=off;


    resolver_timeout 5s;



    server {



EOF



if [ "$PORT" = "443" ];then


cat >> "$CONF" <<EOF

        listen 443 ssl;


        server_name $DOMAIN;



        ssl_certificate $SSL_DIR/fullchain.pem;

        ssl_certificate_key $SSL_DIR/key.pem;


EOF


else


cat >> "$CONF" <<EOF

        listen $PORT;


        server_name $DOMAIN;


EOF


fi




cat >> "$CONF" <<'EOF'


        location / {



            # 默认提示

            if ($request_uri !~ "^/https?://") {

                return 200 '

Emby Proxy

使用方法:

https://域名/https://目标地址


例如:

https://proxy.com/https://emby.example.com

';

            }



            # 获取目标域名

            set $backend_host "";


            set $backend_uri "/";



            if ($request_uri ~ "^/https?://([^/]+)(.*)") {

                set $backend_host $1;

                set $backend_uri $2;

            }



            proxy_pass https://$backend_host$backend_uri;



            # HTTPS SNI

            proxy_ssl_server_name on;


            proxy_ssl_name $backend_host;



            proxy_ssl_verify off;



            # 保留目标Host

            proxy_set_header Host $backend_host;



            proxy_set_header X-Real-IP $remote_addr;


            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;



            # Emby WebSocket

            proxy_http_version 1.1;


            proxy_set_header Upgrade $http_upgrade;


            proxy_set_header Connection "upgrade";



            # 流媒体优化

            proxy_buffering off;


            proxy_request_buffering off;


            proxy_read_timeout 43200s;


            proxy_send_timeout 43200s;



            # Range支持

            proxy_set_header Range $http_range;


            proxy_set_header If-Range $http_if_range;



        }



    }



}


EOF



openresty -t



if [ $? != 0 ];then

err "nginx配置检测失败"

return 1

fi



systemctl restart openresty



ok "nginx启动成功"


}
# ==========================================================
# acme证书申请
# ==========================================================


install_cert(){


if [ "$PORT" != "443" ];then

info "当前端口不是443，跳过证书申请"

return

fi



mkdir -p "$SSL_DIR"



if [ -z "$EMAIL" ];then

read -p "请输入证书邮箱: " EMAIL

fi



info "安装 acme.sh..."



curl https://get.acme.sh | sh -s email="$EMAIL"



~/.acme.sh/acme.sh \

--set-default-ca \

--server letsencrypt




info "停止 OpenResty 释放80端口"



systemctl stop openresty



~/.acme.sh/acme.sh \

--issue \

-d "$DOMAIN" \

--standalone




if [ $? != 0 ];then


err "证书申请失败"


systemctl start openresty


return 1


fi




~/.acme.sh/acme.sh \

--install-cert \

-d "$DOMAIN" \

--key-file "$SSL_DIR/key.pem" \

--fullchain-file "$SSL_DIR/fullchain.pem" \

--reloadcmd "systemctl reload openresty"



ok "证书安装完成"


}





# ==========================================================
# 安装代理
# ==========================================================


install_proxy(){



show_version



install_env



install_openresty



echo



read -p "请输入代理域名: " DOMAIN



if [ -z "$DOMAIN" ];then

err "域名不能为空"

pause

return

fi




echo

echo "请选择端口"

echo "1. 80 HTTP"

echo "2. 443 HTTPS"

echo "3. 自定义"



read -p "选择: " CHOICE



case $CHOICE in


1)

PORT=80

;;



2)

PORT=443

;;



3)

read -p "请输入端口: " PORT

;;


*)

PORT=80

;;

esac




if [ "$PORT" = "443" ];then


read -p "请输入证书邮箱: " EMAIL


install_cert


fi




create_nginx



save_config



echo

echo "================================"

ok "安装完成"

echo

echo "脚本版本: $SCRIPT_VERSION"

echo "域名: $DOMAIN"

echo "端口: $PORT"

echo

echo "访问方式："

echo "https://$DOMAIN/https://目标地址"

echo

echo "例如："

echo "https://$DOMAIN/https://emby.example.com"

echo

echo "================================"



pause



}






# ==========================================================
# 更新配置
# ==========================================================


reload_config(){


load_config


if [ -z "$DOMAIN" ];then

err "没有配置文件"

pause

return

fi



create_nginx


pause


}






# ==========================================================
# 启动
# ==========================================================


root_check


menu
