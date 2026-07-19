#!/bin/bash

# ==================================================
# Emby Reverse Proxy Manager
# Version: v3.0 Lua版
#
# 功能:
# 1. OpenResty官方源安装
# 2. Lua动态反代
# 3. 自动HTTPS补全
# 4. HTTP/HTTPS支持
# 5. 端口自动判断
# 6. 白名单管理
# ==================================================

VER="v3.0"

CONF="/etc/emby-rp.conf"

NGINX="/usr/local/openresty/nginx/conf/nginx.conf"

LUA="/usr/local/openresty/nginx/conf/lua_init.lua"


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

read -p "回车继续..."

}



init(){

[ -f "$CONF" ] || cat > "$CONF" <<EOF
DOMAIN=""
PORT="80"
FILTER="0"
ALLOW_DOMAIN=""
EOF


source "$CONF"

}



save(){

cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
PORT="80"
FILTER="$FILTER"
ALLOW_DOMAIN="$ALLOW_DOMAIN"
EOF

}



header(){

clear

echo "================================"

echo " Emby Reverse Proxy Manager"

echo " Version: $VER"

echo "================================"

echo

}



# ==================================================
# 安装依赖
# ==================================================

install_pkg(){

apt update >/dev/null 2>&1


apt install -y \
curl \
wget \
socat \
gnupg2 \
ca-certificates \
software-properties-common \
lsb-release >/dev/null 2>&1

}




# ==================================================
# 安装OpenResty
# ==================================================

install_openresty(){


command -v openresty >/dev/null && return 0



# 删除旧源

rm -f /etc/apt/sources.list.d/openresty.list



# 导入官方KEY

wget -qO- https://openresty.org/package/pubkey.gpg | apt-key add -



# 添加官方源

echo "deb http://openresty.org/package/debian $(lsb_release -sc) openresty" \
> /etc/apt/sources.list.d/openresty.list



apt update



apt install -y openresty



if ! command -v openresty >/dev/null;then


red "OpenResty安装失败"


return 1


fi



systemctl enable openresty



return 0


}
# ==================================================
# 写入Lua白名单配置
# ==================================================

write_lua(){


mkdir -p "$(dirname "$LUA")"



cat > "$LUA" <<EOF

local dict = ngx.shared.allow_domain


dict:set(
"filter",
"$FILTER"
)


dict:set(
"domains",
"$ALLOW_DOMAIN"
)

EOF

}



# ==================================================
# Nginx配置(Lua动态反代)
# ==================================================

make_nginx(){


write_lua



cat > "$NGINX" <<EOF

worker_processes auto;


events {

    worker_connections 4096;

}



http {


    include mime.types;


    default_type text/plain;


    charset utf-8;



    lua_shared_dict allow_domain 10m;


    init_by_lua_file $LUA;



    resolver 1.1.1.1 8.8.8.8 208.67.222.222 valid=300s ipv6=off;



    server {


        listen 80;


        server_name $DOMAIN;



        set \$backend_scheme "https";

        set \$backend_host "";

        set \$backend_uri "/";



        location / {



            rewrite_by_lua_block {


                local uri = ngx.var.uri


                local target = uri:sub(2)



                if target == "" then


                    ngx.exit(400)


                end



                local scheme = "https"


                local host = target


                local path = "/"



                if target:match("^http://") then


                    scheme="http"


                    host=target:gsub("^http://","")



                elseif target:match("^https://") then


                    scheme="https"


                    host=target:gsub("^https://","")


                end



                local pos = host:find("/")



                if pos then


                    path=host:sub(pos)


                    host=host:sub(1,pos-1)


                end



                if host:match(":%d+$") then


                    scheme="http"


                end



                -- 白名单

                local dict=ngx.shared.allow_domain



                if dict:get("filter")=="1" then


                    local allow=false



                    for d in string.gmatch(
                    dict:get("domains") or "",
                    "[^|]+"
                    )
                    do


                        if host==d or
                        host:sub(-#d-1)=="."..d
                        then


                            allow=true


                        end


                    end



                    if not allow then


                        ngx.exit(403)


                    end


                end



                ngx.var.backend_scheme=scheme

                ngx.var.backend_host=host

                ngx.var.backend_uri=path



            }



            proxy_pass \$backend_scheme://\$backend_host\$backend_uri;



            proxy_ssl_server_name on;


            proxy_ssl_name \$backend_host;


            proxy_ssl_verify off;



            proxy_set_header Host \$backend_host;


            proxy_set_header X-Real-IP \$remote_addr;



            proxy_http_version 1.1;


            proxy_set_header Upgrade \$http_upgrade;


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


red "Nginx配置检测失败"


return 1


fi



systemctl restart openresty



green "Lua反代配置完成"


}
# ==================================================
# 安装反代
# ==================================================

install(){


header



install_pkg



install_openresty



if [ $? != 0 ];then

red "OpenResty安装失败"

pause

return

fi



read -p "代理域名:" DOMAIN



PORT="80"



FILTER="0"



ALLOW_DOMAIN=""



save



make_nginx



if [ $? != 0 ];then

red "配置失败"

pause

return

fi



green "安装完成"



echo


echo "访问格式:"


echo "http://$DOMAIN/目标地址"



echo


echo "示例:"


echo "http://$DOMAIN/cdn.zhezhi.art"



echo "自动解析:"


echo "https://cdn.zhezhi.art"



pause


}




# ==================================================
# 白名单管理
# ==================================================

white(){


while true

do



header



echo "白名单管理"


echo


echo "当前状态:"


if [ "$FILTER" = "1" ];then

echo "开启"

else

echo "关闭"

fi



echo


echo "当前域名:"


if [ -z "$ALLOW_DOMAIN" ];then


echo "暂无"


else


echo "$ALLOW_DOMAIN" | tr "|" "\n"


fi



echo


echo "1.开启"

echo "2.关闭"

echo "3.添加域名"

echo "4.删除域名"

echo "5.清空"

echo "0.返回"



echo


read -p "选择:" W



case $W in



1)

FILTER="1"

;;



2)

FILTER="0"

;;



3)


read -p "添加域名:" ADD



if [ -z "$ALLOW_DOMAIN" ];then


ALLOW_DOMAIN="$ADD"


else


ALLOW_DOMAIN="$ALLOW_DOMAIN|$ADD"


fi


;;



4)


read -p "删除域名:" DEL



NEW=""


IFS="|" read -ra LIST <<< "$ALLOW_DOMAIN"



for i in "${LIST[@]}"

do


if [ "$i" != "$DEL" ] && [ -n "$i" ];then



if [ -z "$NEW" ];then


NEW="$i"


else


NEW="$NEW|$i"


fi



fi


done



ALLOW_DOMAIN="$NEW"



;;



5)


ALLOW_DOMAIN=""


;;



0)


return


;;



*)

red "错误"


;;


esac



save



make_nginx



pause



done



}
# ==================================================
# 查看配置
# ==================================================

show(){

header

cat "$CONF"

pause

}



# ==================================================
# 重载
# ==================================================

reload(){

if openresty -t;then

systemctl reload openresty

green "重载成功"

else

red "配置错误"

fi


pause

}



# ==================================================
# 卸载
# ==================================================

remove(){


systemctl stop openresty 2>/dev/null



apt remove --purge -y openresty* 2>/dev/null



rm -rf /usr/local/openresty



rm -rf "$CONF"



green "卸载完成"



pause


}



# ==================================================
# 菜单
# ==================================================

menu(){


while true

do


header


echo "1.安装反代"

echo "2.白名单管理"

echo "3.查看配置"

echo "4.重载OpenResty"

echo "5.卸载"

echo "0.退出"


echo


read -p "选择:" M



case $M in



1)

install

;;



2)

white

;;



3)

show

;;



4)

reload

;;



5)

remove

;;



0)

exit 0

;;



*)

red "错误"

;;


esac



done


}



# ==================================================
# 启动
# ==================================================

if [ "$(id -u)" != "0" ];then


red "请使用root运行"


exit 1


fi



init



menu
