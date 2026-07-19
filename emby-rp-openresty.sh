#!/bin/bash

# ==========================================================
# Emby Proxy Manager
# Version: v1.9.0
#
# Features:
# - OpenResty reverse proxy
# - Emby optimized
# - WebSocket support
# - HTTPS SNI
# - Optional root domain whitelist
# - Friendly error pages
# - Script version independent
#
# ==========================================================


SCRIPT_NAME="Emby Proxy Manager"
SCRIPT_VERSION="v1.9.0"


BASE_DIR="/etc/emby_proxy"

CONFIG_FILE="$BASE_DIR/config.conf"

TEMPLATE_FILE="$BASE_DIR/nginx.conf.template"

NGINX_CONF="/usr/local/openresty/nginx/conf/nginx.conf"

SSL_DIR="/etc/openresty/ssl"

BACKUP_DIR="/root/emby_proxy_backup"



mkdir -p "$BASE_DIR"



green(){

echo -e "\033[32m$1\033[0m"

}


red(){

echo -e "\033[31m$1\033[0m"

}


yellow(){

echo -e "\033[33m$1\033[0m"

}



pause(){

read -p "按回车继续..."

}



header(){

clear

echo "===================================="

echo " $SCRIPT_NAME"

echo " 脚本版本: $SCRIPT_VERSION"

echo "===================================="

echo

}





root_check(){

if [ "$(id -u)" != "0" ];then

red "请使用 root 用户运行"

exit 1

fi

}




init_config(){


if [ ! -f "$CONFIG_FILE" ];then


cat > "$CONFIG_FILE" <<EOF

DOMAIN=""

PORT="80"

EMAIL=""


# 0关闭限制

# 1开启根域名限制

DOMAIN_FILTER="0"


ALLOW_ROOT_DOMAIN=""


SCRIPT_VERSION="$SCRIPT_VERSION"

EOF


fi


}




load_config(){

source "$CONFIG_FILE"

}




save_config(){


cat > "$CONFIG_FILE" <<EOF

DOMAIN="$DOMAIN"

PORT="$PORT"

EMAIL="$EMAIL"

DOMAIN_FILTER="$DOMAIN_FILTER"

ALLOW_ROOT_DOMAIN="$ALLOW_ROOT_DOMAIN"

SCRIPT_VERSION="$SCRIPT_VERSION"

EOF


}






install_dependencies(){


yellow "安装依赖..."

apt update


apt install -y \

curl \

wget \

socat \

cron \

software-properties-common


}





install_openresty(){


if command -v openresty >/dev/null 2>&1

then


green "OpenResty 已存在"

return


fi



yellow "安装 OpenResty..."



wget -qO - https://openresty.org/package/pubkey.gpg | apt-key add -



add-apt-repository \

"deb http://openresty.org/package/debian $(lsb_release -sc) main"



apt update



apt install -y openresty



systemctl enable openresty



}




show_status(){


header


echo "脚本版本: $SCRIPT_VERSION"

echo



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




show_config(){


header


if [ -f "$CONFIG_FILE" ]

then

cat "$CONFIG_FILE"

else

echo "没有配置"

fi



pause


}
# ==========================================================
# 创建 nginx 模板
# ==========================================================

create_template(){


cat > "$TEMPLATE_FILE" <<'NGINX'

worker_processes auto;


events {

    worker_connections 4096;

}



http {


    include mime.types;


    default_type text/html;


    charset utf-8;



    sendfile on;


    keepalive_timeout 65;



    resolver 223.5.5.5 119.29.29.29 1.1.1.1 valid=300s ipv6=off;


    resolver_timeout 5s;



    server {


        LISTEN_CONFIG


        server_name DOMAIN_CONFIG;



        SSL_CONFIG



        location = / {


            default_type text/html;


            return 200 '

<!DOCTYPE html>

<html>

<head>

<meta charset="utf-8">

<title>Emby Proxy</title>

</head>


<body>


<h2>🚀 Emby Proxy Manager</h2>


<p>版本：SCRIPT_VERSION_CONFIG</p>


<hr>


<p>使用方法：</p>


<p>

https://你的域名/https://目标地址

</p>


<p>

示例：

</p>


<p>

https://proxy.com/https://emby.example.com

</p>



<hr>


<p>

支持：

<br>

✓ Emby

<br>

✓ WebSocket

<br>

✓ HTTPS

<br>

✓ Range播放

</p>


</body>

</html>';

        }





        location / {



            set $backend_host "";

            set $backend_uri "/";



            if ($request_uri ~ "^/https?://([^/]+)(.*)") {


                set $backend_host $1;


                set $backend_uri $2;


            }




            if ($backend_host = "") {


                return 400 '

<!DOCTYPE html>

<html>

<head>

<meta charset="utf-8">

</head>


<body>


<h2>⚠️ 请求格式错误</h2>


<p>

正确格式：

</p>


<p>

https://域名/https://目标地址

</p>


</body>

</html>';

            }



            DOMAIN_CHECK



            proxy_pass https://$backend_host$backend_uri;



            proxy_ssl_server_name on;


            proxy_ssl_name $backend_host;


            proxy_ssl_verify off;



            proxy_set_header Host $backend_host;



            proxy_set_header X-Real-IP $remote_addr;


            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;



            proxy_http_version 1.1;


            proxy_set_header Upgrade $http_upgrade;


            proxy_set_header Connection "upgrade";



            proxy_buffering off;


            proxy_request_buffering off;



            proxy_read_timeout 43200s;


            proxy_send_timeout 43200s;



            proxy_set_header Range $http_range;


            proxy_set_header If-Range $http_if_range;



        }



    }


}

NGINX
}
# ==========================================================
# 生成最终 nginx 配置
# ==========================================================


generate_nginx(){


mkdir -p "$BACKUP_DIR"



if [ -f "$NGINX_CONF" ];then

cp "$NGINX_CONF" "$BACKUP_DIR/nginx.conf.$(date +%s)"

fi




TMP="/tmp/emby_nginx.conf"



cp "$TEMPLATE_FILE" "$TMP"



# 监听端口

if [ "$PORT" = "443" ];then


sed -i "s|LISTEN_CONFIG|listen 443 ssl;|" "$TMP"



sed -i "s|SSL_CONFIG|ssl_certificate $SSL_DIR/fullchain.pem;
        ssl_certificate_key $SSL_DIR/key.pem;|" "$TMP"



else


sed -i "s|LISTEN_CONFIG|listen $PORT;|" "$TMP"



sed -i "/SSL_CONFIG/d" "$TMP"



fi




# 域名

sed -i \

"s|DOMAIN_CONFIG|$DOMAIN|g" \

"$TMP"





# 版本

sed -i \

"s|SCRIPT_VERSION_CONFIG|$SCRIPT_VERSION|g" \

"$TMP"






# 白名单

if [ "$DOMAIN_FILTER" = "1" ] && [ -n "$ALLOW_ROOT_DOMAIN" ];then



CHECK='

set $domain_allow 0;

if ($backend_host = "'$ALLOW_ROOT_DOMAIN'") {

    set $domain_allow 1;

}

if ($backend_host ~* "\.'$ALLOW_ROOT_DOMAIN'$") {

    set $domain_allow 1;

}

if ($domain_allow = 0) {

    return 403;

}

'



sed -i \

"s|DOMAIN_CHECK|$CHECK|g" \

"$TMP"



else



sed -i \

"s|DOMAIN_CHECK||g" \

"$TMP"



fi





cp "$TMP" "$NGINX_CONF"




openresty -t



if [ $? != 0 ];then


red "nginx配置检测失败"


return 1


fi




systemctl restart openresty



green "OpenResty启动成功"



}




# ==========================================================
# 申请证书
# ==========================================================


install_cert(){


if [ "$PORT" != "443" ];then


yellow "80端口模式，跳过证书"


return


fi



mkdir -p "$SSL_DIR"



if [ -z "$EMAIL" ];then


read -p "请输入证书邮箱: " EMAIL


fi



yellow "安装 acme.sh"



curl https://get.acme.sh | sh -s email="$EMAIL"



~/.acme.sh/acme.sh \

--set-default-ca \

--server letsencrypt




systemctl stop openresty



yellow "申请证书..."



~/.acme.sh/acme.sh \

--issue \

-d "$DOMAIN" \

--standalone




if [ $? != 0 ];then


red "证书申请失败"


systemctl start openresty


return 1


fi





~/.acme.sh/acme.sh \

--install-cert \

-d "$DOMAIN" \

--key-file "$SSL_DIR/key.pem" \

--fullchain-file "$SSL_DIR/fullchain.pem" \

--reloadcmd "systemctl reload openresty"




green "证书安装完成"


}




# ==========================================================
# 安装代理
# ==========================================================


install_proxy(){


header



install_dependencies


install_openresty



echo


read -p "请输入代理域名: " DOMAIN



echo


echo "选择端口"

echo "1. 80"

echo "2. 443"

echo "3. 自定义"



read -p "选择: " CH



case $CH in


1)

PORT=80

;;


2)

PORT=443

;;


3)

read -p "输入端口: " PORT

;;


*)

PORT=80

;;

esac





if [ "$PORT" = "443" ];then


read -p "请输入邮箱: " EMAIL


install_cert


fi



# 默认关闭限制

[ -z "$DOMAIN_FILTER" ] && DOMAIN_FILTER=0



save_config


create_template


generate_nginx



green "安装完成"


echo

echo "版本: $SCRIPT_VERSION"

echo "域名: $DOMAIN"

echo "端口: $PORT"


pause


}





# ==========================================================
# 白名单菜单
# ==========================================================


domain_filter_menu(){


load_config



header


echo "当前状态:"


if [ "$DOMAIN_FILTER" = "1" ];then


echo "开启"

echo "根域名:$ALLOW_ROOT_DOMAIN"


else


echo "关闭"


fi



echo

echo "1.开启"

echo "2.关闭"

echo "3.设置根域名"

echo "0.返回"



read -p "选择:" X



case $X in


1)

DOMAIN_FILTER=1

;;


2)

DOMAIN_FILTER=0

;;


3)

read -p "根域名:" ALLOW_ROOT_DOMAIN

;;


0)

return

;;

esac



save_config


generate_nginx


pause


}
# ==========================================================
# 卸载清理
# ==========================================================


uninstall_all(){


header


yellow "开始卸载..."



systemctl stop openresty 2>/dev/null


systemctl disable openresty 2>/dev/null



apt remove --purge -y openresty* 2>/dev/null



rm -rf /usr/local/openresty


rm -rf /etc/openresty


rm -rf "$BASE_DIR"


rm -rf "$BACKUP_DIR"



systemctl daemon-reload



green "OpenResty及脚本配置已清理"



pause


}





# ==========================================================
# 状态
# ==========================================================


status(){


header



echo "脚本版本: $SCRIPT_VERSION"


echo



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







# ==========================================================
# 主菜单
# ==========================================================


menu(){



while true

do



header



echo "1. 安装/配置反代"


echo "2. 白名单管理"


echo "3. 查看配置"


echo "4. 查看状态"


echo "5. 卸载清理"


echo "0. 退出"



echo


read -p "请选择: " MENU



case $MENU in



1)

install_proxy

;;



2)

domain_filter_menu

;;



3)

show_config

;;



4)

status

;;



5)

uninstall_all

;;



0)

exit 0

;;



*)

red "错误选择"

sleep 1

;;

esac



done


}






# ==========================================================
# 启动
# ==========================================================


root_check


init_config


load_config


menu
