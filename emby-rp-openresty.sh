#!/bin/bash

# ==========================================================
# Emby Proxy Manager
# Script Version: v1.8.1
#
# 功能:
#  - 动态反代
#  - Emby优化
#  - WebSocket
#  - HTTPS证书
#  - 根域名白名单(可选)
#  - 人性化错误页面
#
# ==========================================================


SCRIPT_NAME="Emby Proxy Manager"
SCRIPT_VERSION="v1.8.1"


NGINX_CONF="/usr/local/openresty/nginx/conf/nginx.conf"

CONFIG_FILE="/etc/emby_proxy.conf"

SSL_DIR="/etc/openresty/ssl"

BACKUP_DIR="/root/emby_proxy_backup"



pause(){

echo

read -p "按回车继续..."

}



info(){

echo -e "\033[36m$1\033[0m"

}



ok(){

echo -e "\033[32m$1\033[0m"

}



err(){

echo -e "\033[31m$1\033[0m"

}




show_header(){

clear

echo "================================"

echo " $SCRIPT_NAME"

echo " 脚本版本: $SCRIPT_VERSION"

echo "================================"

echo

}





root_check(){

if [ "$(id -u)" != "0" ];then

err "请使用 root 用户运行"

exit 1

fi

}





save_config(){


cat > "$CONFIG_FILE" <<EOF

DOMAIN="$DOMAIN"

PORT="$PORT"

EMAIL="$EMAIL"


# 目标域名限制

# 0 = 不限制

# 1 = 开启

DOMAIN_FILTER="$DOMAIN_FILTER"


# 根域名

ALLOW_ROOT_DOMAIN="$ALLOW_ROOT_DOMAIN"


SCRIPT_VERSION="$SCRIPT_VERSION"

EOF


}





load_config(){


if [ -f "$CONFIG_FILE" ];then


source "$CONFIG_FILE"


else


DOMAIN_FILTER=0


fi


}





install_dependencies(){


info "安装依赖..."


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


ok "OpenResty 已存在"

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





show_status(){


show_header


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







uninstall_all(){


show_header


echo "开始清理..."



systemctl stop openresty 2>/dev/null


systemctl disable openresty 2>/dev/null



apt remove --purge -y openresty* 2>/dev/null



rm -rf /usr/local/openresty


rm -rf /etc/openresty


rm -rf "$CONFIG_FILE"


rm -rf "$BACKUP_DIR"



systemctl daemon-reload



ok "清理完成"


pause


}






menu(){


while true

do


show_header



echo "1. 安装反代"

echo "2. 设置域名白名单"

echo "3. 查看配置"

echo "4. 卸载"

echo "5. 查看状态"

echo "0. 退出"



echo


read -p "请选择: " CHOOSE



case $CHOOSE in


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

uninstall_all

;;


5)

show_status

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
# ==========================================================
# 域名白名单检查
# ==========================================================


domain_check_config(){


if [ "$DOMAIN_FILTER" != "1" ];then

return

fi



if [ -z "$ALLOW_ROOT_DOMAIN" ];then

return

fi


}





# ==========================================================
# 生成 nginx 配置
# ==========================================================


create_nginx(){


info "生成 OpenResty 配置..."



mkdir -p "$BACKUP_DIR"



if [ -f "$NGINX_CONF" ];then

cp "$NGINX_CONF" "$BACKUP_DIR/nginx.conf.$(date +%s)"

fi



cat > "$NGINX_CONF" <<EOF


worker_processes auto;



events {

    worker_connections 4096;

}



http {


    include mime.types;


    default_type text/html;


    charset utf-8;



    sendfile on;


    tcp_nopush on;


    keepalive_timeout 65;




    resolver 223.5.5.5 119.29.29.29 1.1.1.1 valid=300s ipv6=off;


    resolver_timeout 5s;



    server {



EOF



if [ "$PORT" = "443" ];then


cat >> "$NGINX_CONF" <<EOF

        listen 443 ssl;


        server_name $DOMAIN;



        ssl_certificate $SSL_DIR/fullchain.pem;


        ssl_certificate_key $SSL_DIR/key.pem;



EOF


else


cat >> "$NGINX_CONF" <<EOF

        listen $PORT;


        server_name $DOMAIN;



EOF


fi



cat >> "$NGINX_CONF" <<EOF


        error_page 403 /403.html;


        error_page 404 /404.html;


        error_page 502 503 504 /502.html;




        location = /403.html {


            default_type text/html;


            return 403 '

<!DOCTYPE html>

<html>

<meta charset="utf-8">

<title>403</title>

<body>


<h2>🚫 访问被拒绝</h2>

<p>目标地址不允许代理</p>


<p>请检查域名白名单设置</p>


</body>

</html>';

        }





        location = /404.html {


            return 404 '

<!DOCTYPE html>

<html>

<meta charset="utf-8">

<h2>404</h2>

<p>页面不存在</p>

<p>Emby Proxy Manager $SCRIPT_VERSION</p>

</html>';

        }






        location = /502.html {


            return 502 '

<!DOCTYPE html>

<html>

<meta charset="utf-8">


<h2>⚠️ 后端连接失败</h2>


<p>可能原因:</p>

<p>1. 目标服务器离线</p>

<p>2. 地址错误</p>

<p>3. HTTPS握手失败</p>


<p>请检查目标地址</p>


</html>';

        }






        location / {



            if ($request_uri !~ "^/https?://") {


                return 200 '

<!DOCTYPE html>

<html>

<meta charset="utf-8">


<h2>🚀 Emby Proxy Manager</h2>


<p>版本: $SCRIPT_VERSION</p>


<hr>


<p>使用方法:</p>


<p>

https://你的域名/https://目标地址

</p>



<p>示例:</p>


<p>

https://proxy.com/https://emby.example.com

</p>


<hr>


<p>

支持:

<br>

✓ Emby

<br>

✓ WebSocket

<br>

✓ HTTPS

<br>

✓ 大文件播放

</p>


</html>';

            }




            set \$backend_host "";

            set \$backend_uri "/";



            if (\$request_uri ~ "^/https?://([^/]+)(.*)") {


                set \$backend_host \$1;


                set \$backend_uri \$2;


            }




EOF



# 白名单逻辑

if [ "$DOMAIN_FILTER" = "1" ] && [ -n "$ALLOW_ROOT_DOMAIN" ];then


cat >> "$NGINX_CONF" <<EOF


            set \$domain_allow 0;



            if (\$backend_host = "$ALLOW_ROOT_DOMAIN") {


                set \$domain_allow 1;


            }




            if (\$backend_host ~* "\.${ALLOW_ROOT_DOMAIN}$") {


                set \$domain_allow 1;


            }




            if (\$domain_allow = 0) {


                return 403;


            }



EOF


fi



cat >> "$NGINX_CONF" <<'EOF'


            proxy_pass https://$backend_host$backend_uri;



            # HTTPS SNI

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



        }


    }


}


EOF



openresty -t



if [ $? != 0 ];then

err "nginx配置错误"

return 1

fi



systemctl restart openresty



ok "OpenResty启动成功"


}
# ==========================================================
# 白名单设置菜单
# ==========================================================


domain_filter_menu(){


load_config


show_header


echo "当前域名限制状态:"



if [ "$DOMAIN_FILTER" = "1" ];then


echo "✅ 已开启"

echo "根域名: $ALLOW_ROOT_DOMAIN"



else


echo "❌ 已关闭"


fi



echo

echo "1. 开启白名单"

echo "2. 关闭白名单"

echo "3. 设置根域名"

echo "0. 返回"



read -p "选择: " C



case $C in


1)

DOMAIN_FILTER=1

ok "白名单已开启"

save_config

;;


2)

DOMAIN_FILTER=0

ok "白名单已关闭"

save_config

;;


3)

read -p "输入根域名(例如 mobaiemby.site): " ALLOW_ROOT_DOMAIN


save_config


;;


0)

return

;;


*)

echo "错误"

;;

esac



pause


}






# ==========================================================
# 查看配置
# ==========================================================


show_config(){


show_header


if [ -f "$CONFIG_FILE" ];then


cat "$CONFIG_FILE"



else


echo "暂无配置"


fi



pause


}





# ==========================================================
# acme证书
# ==========================================================


install_cert(){



if [ "$PORT" != "443" ];then


info "80端口模式，不申请证书"

return


fi




if [ -z "$EMAIL" ];then


read -p "输入证书邮箱: " EMAIL


fi




info "安装 acme.sh"



curl https://get.acme.sh | sh -s email="$EMAIL"



~/.acme.sh/acme.sh \

--set-default-ca \

--server letsencrypt




mkdir -p "$SSL_DIR"



systemctl stop openresty



info "申请证书..."



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



ok "证书安装成功"



}





# ==========================================================
# 安装代理
# ==========================================================


install_proxy(){


show_header



install_dependencies


install_openresty




echo


read -p "请输入代理域名: " DOMAIN



if [ -z "$DOMAIN" ];then


err "域名不能为空"


pause


return


fi




echo


echo "选择端口"

echo "1. 80 HTTP"

echo "2. 443 HTTPS"

echo "3. 自定义"



read -p "选择: " PORT_CHOICE



case $PORT_CHOICE in


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


read -p "请输入证书邮箱: " EMAIL


install_cert


fi





# 默认关闭域名限制

if [ -z "$DOMAIN_FILTER" ];then

DOMAIN_FILTER=0

fi




save_config



create_nginx




echo


echo "================================"

ok "安装完成"


echo

echo "脚本版本: $SCRIPT_VERSION"

echo "代理域名: $DOMAIN"

echo "监听端口: $PORT"


echo


echo "访问格式:"


echo "https://$DOMAIN/https://目标地址"



echo "================================"



pause


}
# ==========================================================
# 程序入口
# ==========================================================


root_check


load_config


menu
