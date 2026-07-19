#!/bin/bash

# =================================================
# Emby Proxy Manager v1.7
# 简单稳定版
#
# 功能:
# 1. 一键安装 OpenResty
# 2. 动态URL反代
# 3. 支持Emby
# 4. 支持WebSocket
# 5. 支持HTTP/HTTPS
# 6. 安装/卸载菜单
# =================================================


VERSION="v1.7"

APP="Emby Proxy Manager"


CONF="/usr/local/openresty/nginx/conf/nginx.conf"

SSL_DIR="/etc/openresty/ssl"


CONFIG="/etc/emby_proxy.conf"



pause(){

read -p "按回车继续..."

}



msg(){

echo
echo "================================"
echo "$1"
echo "================================"
echo

}



root_check(){

if [ "$EUID" != "0" ];then

echo "请使用root运行"

exit

fi

}




install_pkg(){


apt update


apt install -y curl wget unzip socat



}




install_openresty(){


if command -v openresty >/dev/null

then

echo "OpenResty 已安装"

return

fi



echo "安装 OpenResty"



wget -qO - https://openresty.org/package/pubkey.gpg \
| apt-key add -



apt-get -y install software-properties-common



add-apt-repository \
"deb http://openresty.org/package/debian $(lsb_release -sc) main"



apt update


apt install -y openresty



systemctl enable openresty



}




save_config(){


cat > $CONFIG <<EOF

DOMAIN="$DOMAIN"

PORT="$PORT"

EOF


}



load_config(){


if [ -f $CONFIG ]

then

source $CONFIG

fi


}
# =================================================
# 生成Nginx配置
# =================================================

create_nginx(){


msg "生成 OpenResty 配置"


cp "$CONF" "$CONF.bak.$(date +%s)"



cat > "$CONF" <<EOF

worker_processes auto;


events {

    worker_connections 4096;

}



http {


    include       mime.types;

    default_type  application/octet-stream;



    sendfile on;


    tcp_nopush on;


    keepalive_timeout 65;



    server {


        listen $PORT;



        server_name $DOMAIN;



        # ==========================
        # 动态反代核心
        # ==========================

        location / {



            # 提取用户输入地址
            set \$target "";

            if (\$request_uri ~ "^/https?://([^/]+)(/.*)?") {

                set \$target \$1;

            }



            # 没有输入地址提示

            if (\$target = "") {

                return 200 "

Emby Proxy $VERSION

使用方法:

https://域名/https://目标地址

例如:

https://proxy.com/https://emby.xxx.com

";

            }



            proxy_pass https://\$target;



            proxy_ssl_server_name on;


            proxy_ssl_verify off;



            proxy_set_header Host \$target;



            proxy_set_header X-Real-IP \$remote_addr;


            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;



            proxy_http_version 1.1;



            proxy_set_header Upgrade \$http_upgrade;


            proxy_set_header Connection "upgrade";



            proxy_buffering off;



            proxy_request_buffering off;



            proxy_read_timeout 43200s;



        }



    }


}


EOF



openresty -t


if [ $? != 0 ]

then

echo "❌ nginx配置错误"

return

fi



systemctl restart openresty



echo

echo "✅ 配置完成"

echo

}
# =================================================
# 卸载
# =================================================

uninstall(){


msg "卸载 Emby Proxy"


systemctl stop openresty 2>/dev/null


systemctl disable openresty 2>/dev/null



apt remove --purge -y openresty* 2>/dev/null



rm -rf /usr/local/openresty


rm -rf /etc/openresty


rm -rf /etc/emby_proxy.conf



rm -f /etc/systemd/system/openresty.service



systemctl daemon-reload



echo

echo "✅ 卸载完成"

echo

echo "如果需要重新安装，请重新运行脚本"



pause


}






# =================================================
# 状态
# =================================================

status(){


echo

echo "版本: $VERSION"


echo


systemctl status openresty --no-pager



pause


}






# =================================================
# 安装流程
# =================================================

install(){



msg "$APP $VERSION 安装"



install_pkg



install_openresty



echo


read -p "请输入代理域名: " DOMAIN



if [ -z "$DOMAIN" ]

then

echo "域名不能为空"

pause

return

fi





echo

echo "选择端口"

echo "1. 80 HTTP"

echo "2. 443 HTTPS"

echo "3. 自定义端口"



read -p "选择:" P



case $P in


1)

PORT=80

;;


2)

PORT=443

;;


3)

read -p "输入端口:" PORT

;;


*)

PORT=80

;;

esac






save_config



create_nginx




echo

echo "================================"

echo "安装完成"

echo

echo "版本: $VERSION"

echo "域名: $DOMAIN"

echo "端口: $PORT"

echo

echo "访问格式："

echo "https://$DOMAIN/https://你的Emby地址"

echo

echo "例如："

echo "https://$DOMAIN/https://emby.xxx.com"

echo

echo "================================"



pause


}








# =================================================
# 菜单
# =================================================

menu(){



while true

do


clear



echo "================================"

echo " $APP"

echo " Version $VERSION"

echo "================================"



echo

echo "1. 安装代理"

echo "2. 卸载"

echo "3. 查看状态"

echo "4. 重载配置"

echo "0. 退出"



echo


read -p "请选择:" N



case $N in



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

load_config

create_nginx

;;



0)

exit

;;



*)

echo "错误"

sleep 1

;;

esac



done



}





# =================================================
# 启动
# =================================================

root_check

menu
create_nginx(){


msg "生成 OpenResty 配置"


cp "$CONF" "$CONF.bak.$(date +%s)"



if [ "$PORT" = "443" ]; then


cat > "$CONF" <<EOF

worker_processes auto;


events {
    worker_connections 4096;
}


http {


include mime.types;


sendfile on;


server {


listen 443 ssl;


server_name $DOMAIN;



ssl_certificate $SSL_DIR/fullchain.pem;

ssl_certificate_key $SSL_DIR/key.pem;



location / {



set \$target "";



if (\$request_uri ~ "^/https?://([^/]+)(/.*)?") {

    set \$target \$1;

}



if (\$target = "") {

return 200 "

Emby Proxy $VERSION

使用方法:

https://\$host/https://目标地址

";

}



proxy_pass https://\$target;



proxy_ssl_server_name on;


proxy_ssl_verify off;



proxy_set_header Host \$target;


proxy_set_header X-Real-IP \$remote_addr;


proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;


proxy_http_version 1.1;


proxy_set_header Upgrade \$http_upgrade;


proxy_set_header Connection "upgrade";


proxy_buffering off;


proxy_request_buffering off;


proxy_read_timeout 43200s;


}


}


}

EOF


else


cat > "$CONF" <<EOF

worker_processes auto;


events {

worker_connections 4096;

}


http {


include mime.types;


server {


listen $PORT;


server_name $DOMAIN;


location / {



set \$target "";



if (\$request_uri ~ "^/https?://([^/]+)(/.*)?") {

set \$target \$1;

}



if (\$target = "") {

return 200 "

Emby Proxy $VERSION

使用方法:

http://\$host/https://目标地址

";

}



proxy_pass https://\$target;


proxy_ssl_server_name on;


proxy_ssl_verify off;



proxy_set_header Host \$target;


proxy_http_version 1.1;


proxy_set_header Upgrade \$http_upgrade;


proxy_set_header Connection "upgrade";


proxy_buffering off;


proxy_read_timeout 43200s;


}


}


}

EOF


fi



openresty -t

if [ $? = 0 ]; then

systemctl restart openresty

echo "✅ nginx配置成功"

else

echo "❌ nginx配置错误"

fi


}

