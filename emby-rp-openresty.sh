#!/bin/bash

# ==================================================
# Emby 动态反代
# Version: v3.7
# ==================================================

VER="v3.7"

CONF="/etc/emby-rp.conf"

NGINX="/usr/local/openresty/nginx/conf/nginx.conf"

LUA="/usr/local/openresty/nginx/conf/lua_init.lua"

SERVICE="/etc/systemd/system/emby-proxy.service"



green(){
    echo -e "\033[32m$1\033[0m"
}

red(){
    echo -e "\033[31m$1\033[0m"
}

yellow(){
    echo -e "\033[33m$1\033[0m"
}

blue(){
    echo -e "\033[36m$1\033[0m"
}


pause(){

echo

read -p "💡 按回车返回主菜单..."

}



header(){

clear

echo "=================================================="

echo "        🚀 动态反代服务管理面板 $VER"

echo "        Emby / CDN Reverse Proxy"

echo "=================================================="

echo

}



init(){


if [ ! -f "$CONF" ];then


cat > "$CONF" <<EOF
DOMAIN=""
FILTER="0"
ALLOW_DOMAIN=""
EOF


fi


source "$CONF"


}



save(){


cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
FILTER="$FILTER"
ALLOW_DOMAIN="$ALLOW_DOMAIN"
EOF


}



install_pkg(){


blue "ℹ️ 正在准备系统环境..."


apt update >/dev/null 2>&1


apt install -y \
curl \
wget \
socat \
gnupg2 \
ca-certificates \
software-properties-common \
lsb-release \
apt-transport-https >/dev/null 2>&1


green "✅ 系统环境准备完成"


}



install_openresty(){


if command -v openresty >/dev/null;then

green "✅ OpenResty 已安装"

return 0

fi



blue "ℹ️ 正在安装 OpenResty..."



wget -qO- https://openresty.org/package/pubkey.gpg \
| apt-key add - >/dev/null 2>&1



echo "deb http://openresty.org/package/debian $(lsb_release -sc) openresty" \
> /etc/apt/sources.list.d/openresty.list



apt update


apt install -y openresty



if ! command -v openresty >/dev/null;then

red "❌ OpenResty安装失败"

return 1

fi



systemctl enable openresty >/dev/null 2>&1


green "✅ OpenResty安装完成"


}




write_lua(){


mkdir -p "$(dirname "$LUA")"



cat > "$LUA" <<EOF

local dict = ngx.shared.allow_domain

dict:set("filter","$FILTER")

dict:set("domains","$ALLOW_DOMAIN")

EOF


}



make_systemd(){


cat > "$SERVICE" <<EOF
[Unit]
Description=Emby Dynamic Reverse Proxy
After=network.target


[Service]
Type=forking
ExecStart=/usr/local/openresty/bin/openresty
ExecReload=/usr/local/openresty/bin/openresty -s reload
Restart=always
RestartSec=5


[Install]
WantedBy=multi-user.target
EOF


systemctl daemon-reload

systemctl enable emby-proxy.service >/dev/null 2>&1


}
make_nginx(){

write_lua


cat > "$NGINX" <<EOF

worker_processes auto;


events {

    worker_connections 4096;

}


http {


    include mime.types;

    default_type application/octet-stream;


    lua_shared_dict allow_domain 10m;


    init_by_lua_file $LUA;



    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;

    resolver_timeout 5s;



    real_ip_header CF-Connecting-IP;

    real_ip_recursive on;



    sendfile on;

    tcp_nopush on;

    tcp_nodelay on;


    keepalive_timeout 65;



    client_max_body_size 0;



    server {


        listen 80;


        server_name $DOMAIN;



        location / {



            set \$upstream "";

            set \$target_host "";

            set \$target_scheme "";



            rewrite_by_lua_block {



                local uri = ngx.var.request_uri



                -- 分离路径和参数
                local pure_uri,args =
                uri:match("^([^?]*)%??(.*)$")



                local target =
                pure_uri:sub(2)



                if target == "" then


                    ngx.status=400

                    ngx.header.content_type=
                    "text/plain;charset=utf-8"


                    ngx.say([[
❌ 400 请求错误

缺少目标地址

正确格式:

http://你的域名/目标地址

示例:

http://你的域名/emby.example.com
]])


                    return ngx.exit(400)

                end




                local url=target



                if not url:match("^https?://") then

                    url="https://"..url

                end




                local dict=ngx.shared.allow_domain




                if dict:get("filter")=="1" then



                    local check_host =
                    url:match("^https?://([^/]+)")



                    if check_host then

                        check_host=
                        check_host:lower()

                    end



                    local allow=false



                    for domain in string.gmatch(
                        dict:get("domains") or "",
                        "[^|]+"
                    )

                    do



                        domain=domain:lower()



                        if check_host==domain
                        or check_host:sub(-#domain-1)
                        =="."..domain

                        then

                            allow=true

                            break

                        end


                    end




                    if not allow then


                        ngx.status=403


                        ngx.header.content_type=
                        "text/plain;charset=utf-8"



                        ngx.say([[
⚠️ 403 禁止访问

目标域名不在白名单内。
]])



                        return ngx.exit(403)


                    end



                end





                local scheme,host,path =
                url:match(
                "^(https?://)([^/]+)(.*)"
                )




                if not host then


                    ngx.status=400


                    ngx.say([[
❌ 400 地址解析失败

无法识别目标服务器。
]])

                    return ngx.exit(400)


                end





                if path=="" then

                    path="/"

                end




                -- 关键修复:
                -- 只修改URI
                -- 参数保持原样

                ngx.req.set_uri(path)



                if args and args~="" then

                    ngx.req.set_uri_args(args)

                end




                ngx.var.target_scheme =
                scheme:gsub("://","")



                ngx.var.target_host=host



                ngx.var.upstream=
                scheme..host



            }




            proxy_pass \$upstream;



            proxy_set_header Host \$target_host;



            proxy_set_header X-Real-IP \$remote_addr;



            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;



            proxy_set_header X-Forwarded-Proto \$target_scheme;



            proxy_ssl_server_name on;


            proxy_ssl_name \$target_host;


            proxy_ssl_verify off;




            proxy_http_version 1.1;



            proxy_set_header Upgrade \$http_upgrade;


            proxy_set_header Connection "upgrade";




            # Emby Range播放优化

            proxy_set_header Range \$http_range;


            proxy_set_header If-Range \$http_if_range;



            proxy_force_ranges on;



            proxy_buffering off;


            proxy_request_buffering off;


            proxy_max_temp_file_size 0;



            proxy_read_timeout 86400s;


            proxy_send_timeout 86400s;



            proxy_intercept_errors on;


        }



        error_page 502 = @error502;


        error_page 504 = @error504;




        location @error502 {


            default_type text/plain;



            return 502
"❌ 502 源站连接失败\n\n可能原因:\n1. 源站无法访问\n2. 源站封禁服务器IP\n3. DNS解析失败\n4. HTTPS握手失败\n";


        }





        location @error504 {


            default_type text/plain;



            return 504
"❌ 504 请求超时\n\n目标服务器响应时间过长。\n";


        }



    }


}


EOF



openresty -t >/dev/null 2>&1


if [ $? != 0 ];then


red "❌ nginx配置检测失败"

return 1


fi



systemctl restart openresty


green "✅ nginx配置加载成功"


}
install(){

header


install_pkg


install_openresty


if [ $? != 0 ];then

pause

return

fi



echo

read -p "🌐 请输入绑定代理域名: " DOMAIN



if [ -z "$DOMAIN" ];then

red "❌ 域名不能为空"

pause

return

fi



FILTER="0"

ALLOW_DOMAIN=""


save


make_nginx


if [ $? != 0 ];then

pause

return

fi



make_systemd



systemctl restart openresty



green "=================================================="

green "🎉 动态反代部署成功"

green "=================================================="


echo

echo "🌐 访问格式："

echo

echo "http://$DOMAIN/目标地址"


echo

echo "示例："

echo "http://$DOMAIN/emby.example.com"


echo

echo "已启用："

echo "✅ 动态反代"

echo "✅ WebSocket"

echo "✅ Range断点续传"

echo "✅ 大文件流媒体"

echo "✅ Cloudflare真实IP"

echo "✅ DNS缓存"

echo "✅ systemd守护"


pause


}




white(){


while true

do


header


echo "🛡️ 白名单管理"

echo "--------------------------------------------------"



echo -n "当前状态: "


if [ "$FILTER" = "1" ];then

green "开启"

else

yellow "关闭"

fi



echo


echo "允许域名:"


if [ -z "$ALLOW_DOMAIN" ];then

echo "  (暂无)"

else

echo "$ALLOW_DOMAIN" | tr "|" "\n"

fi



echo

echo "[1] 开启白名单"

echo "[2] 关闭白名单"

echo "[3] 添加域名"

echo "[4] 删除域名"

echo "[5] 清空列表"

echo "[0] 保存返回"



read -p "👉 请选择: " W



case $W in


1)

FILTER="1"

;;


2)

FILTER="0"

;;


3)

read -p "输入域名: " ADD


if [ -n "$ADD" ];then


if [ -z "$ALLOW_DOMAIN" ];then

ALLOW_DOMAIN="$ADD"

else

ALLOW_DOMAIN="$ALLOW_DOMAIN|$ADD"

fi


fi

;;


4)

read -p "删除域名: " DEL


NEW=""


IFS="|" read -ra ARR <<< "$ALLOW_DOMAIN"



for d in "${ARR[@]}"

do

if [ "$d" != "$DEL" ] && [ -n "$d" ];then


if [ -z "$NEW" ];then

NEW="$d"

else

NEW="$NEW|$d"

fi


fi


done



ALLOW_DOMAIN="$NEW"


;;



5)

ALLOW_DOMAIN=""

;;



0)

save

make_nginx

return

;;


*)

red "❌ 输入错误"

;;

esac



save

make_nginx



done


}




show(){


header


echo "🔍 当前配置"

echo "--------------------------------------------------"

echo "🌐 域名: $DOMAIN"

echo "🛡️ 白名单: $FILTER"

echo "📋 列表: ${ALLOW_DOMAIN:-无}"

echo "--------------------------------------------------"


pause


}





reload(){


header


openresty -t


if [ $? = 0 ];then


systemctl reload openresty


green "✅ 重载成功"


else


red "❌ 配置错误"

fi


pause


}




remove(){


header


read -p "⚠️ 确认卸载？(y): " OK



if [[ "$OK" == "y" || "$OK" == "Y" ]];then



systemctl stop openresty 2>/dev/null



apt remove --purge -y openresty* >/dev/null 2>&1



rm -rf /usr/local/openresty


rm -f "$CONF"


rm -f "$SERVICE"



systemctl daemon-reload



green "✅ 已卸载"


fi


pause


}





menu(){


while true

do


header



echo "[1] 🚀 安装/初始化"

echo "[2] 🛡️ 白名单管理"

echo "[3] 🔍 查看配置"

echo "[4] 🔄 重载服务"

echo "[5] 🗑️ 卸载"

echo "[0] 退出"



read -p "👉 请选择: " M



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

clear

exit

;;


*)

red "❌ 输入错误"

;;

esac


done


}





if [ "$(id -u)" != "0" ];then

red "❌ 请使用root运行"

exit 1

fi



init


menu
