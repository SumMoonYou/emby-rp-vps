#!/bin/bash

# ==================================================
# Emby Reverse Proxy Manager
# Version: v3.3 Lua (Streaming Fixed)
#
# OpenResty + Lua 动态反代（流媒体完美修复版）
# ==================================================

VER="v3.3"
CONF="/etc/emby-rp.conf"
NGINX="/usr/local/openresty/nginx/conf/nginx.conf"
LUA="/usr/local/openresty/nginx/conf/lua_init.lua"

green(){
    echo -e "\033[32m$1\033[0m"
}

red(){
    echo -e "\033[31m$1\033[0m"
}

pause(){
    read -p "回车继续..."
}

init(){
    [ -f "$CONF" ] || cat > "$CONF" <<EOF
DOMAIN=""
FILTER="0"
ALLOW_DOMAIN=""
EOF
    source "$CONF"
}

save(){
    cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
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
    rm -f /etc/apt/sources.list.d/openresty.list
    wget -qO- https://openresty.org/package/pubkey.gpg | apt-key add -
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
# 写入Lua配置
# ==================================================
write_lua(){
    mkdir -p "$(dirname "$LUA")"
    cat > "$LUA" <<EOF
local dict = ngx.shared.allow_domain
dict:set("filter", "$FILTER")
dict:set("domains", "$ALLOW_DOMAIN")
EOF
}

# ==================================================
# 生成OpenResty Lua反代配置
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

    # 保持您指定的国外通用 DNS
    resolver 1.1.1.1 8.8.8.8 208.67.222.222 valid=300s ipv6=off;

    server {
        listen 80;
        server_name $DOMAIN;

        # 提前定义 Nginx 变量，供 Lua 动态写入
        set \$upstream "";
        set \$target_host "";
        set \$target_scheme "";

        location / {
            rewrite_by_lua_block {
                local uri = ngx.var.request_uri
                
                -- 【核心修复 1】剥离 ? 后面的流媒体播放参数，防止参数污染重写路径导致无法播放
                local pure_uri = uri:match("^([^?]+)") or uri
                local target = pure_uri:sub(2)

                if target == "" then
                    ngx.status = 400
                    ngx.header.content_type="text/plain; charset=utf-8"
                    ngx.say("❌ 400 请求错误\n\n原因:\n没有输入目标地址\n\n正确格式:\nhttp://你的域名/目标地址\n")
                    return ngx.exit(400)
                end

                local url = target
                if not url:match("^https?://") then
                    url="https://"..url
                end

                -- 白名单检测
                local dict = ngx.shared.allow_domain
                if dict:get("filter")=="1" then
                    local host = url:match("^https?://([^/]+)")
                    local allow=false
                    for domain in string.gmatch(dict:get("domains") or "", "[^|]+") do
                        if host==domain or host:sub(-#domain-1)=="."..domain then
                            allow=true
                        end
                    end

                    if not allow then
                        ngx.status=403
                        ngx.header.content_type="text/plain; charset=utf-8"
                        ngx.say("❌ 403 禁止访问\n\n原因:\n目标域名不在白名单\n")
                        return ngx.exit(403)
                    end
                end

                -- 【核心修复 2】准确拆分出纯净域名与路径，只用 path 参与重写，让 Nginx 自动追加原始 Query 参数
                local scheme, host, path = url:match("^(https?://)([^/]+)(.*)")
                if not path or path == "" then
                    path = "/"
                end
                ngx.req.set_uri(path)

                -- 将提取出来的正确值赋给 Nginx 变量
                ngx.var.target_scheme = scheme:gsub("://", "")
                ngx.var.target_host = host
                ngx.var.upstream = scheme .. host
            }

            proxy_pass \$upstream;

            # 【核心修复 3】将 Host 修改为真实的 Emby 目标域名，防止 502 拒绝连接
            proxy_set_header Host \$target_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            
            # 告诉 Emby 真实的传输协议，防止其发送错误的媒体播放清单路径
            proxy_set_header X-Forwarded-Proto \$target_scheme;

            proxy_ssl_server_name on;
            proxy_ssl_verify off;
            proxy_intercept_errors on;
            proxy_http_version 1.1;

            # 完美放行 WebSocket 协议，保障 Emby 客户端控制台与握手连接
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";

            # 流媒体流式大文件传输必备优化选项
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 43200s;
            proxy_send_timeout 43200s;
        }

        error_page 502 = @err502;
        error_page 504 = @err504;

        location @err502 {
            default_type text/plain;
            return 502 "❌ 502 代理失败\n\n原因:\n目标服务器拒绝连接，或动态路径解析错误。\n";
        }

        location @err504 {
            default_type text/plain;
            return 504 "❌ 504 请求超时\n";
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
    echo "或者:"
    echo "http://$DOMAIN/https://cdn.zhezhi.art"
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
            1) FILTER="1" ;;
            2) FILTER="0" ;;
            3)
                read -p "输入域名:" ADD
                if [ -z "$ALLOW_DOMAIN" ];then
                    ALLOW_DOMAIN="$ADD"
                else
                    ALLOW_DOMAIN="$ALLOW_DOMAIN|$ADD"
                fi
            ;;
            4)
                read -p "删除域名:" DEL
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
            5) ALLOW_DOMAIN="" ;;
            0) return ;;
            *) red "错误" ;;
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
    openresty -t
    if [ $? = 0 ];then
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
            1) install ;;
            2) white ;;
            3) show ;;
            4) reload ;;
            5) remove ;;
            0) exit 0 ;;
            *) red "错误" ;;
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
