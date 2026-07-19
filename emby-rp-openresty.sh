#!/bin/bash

# ==================================================
# 动态反代极速部署工具 (Emby/CDN 专用)
# Version: v3.6 Lua (Clean Example Edition)
# ==================================================

VER="v3.6"
CONF="/etc/emby-rp.conf"
NGINX="/usr/local/openresty/nginx/conf/nginx.conf"
LUA="/usr/local/openresty/nginx/conf/lua_init.lua"

green(){ echo -e "\033[32m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }
pause(){ echo; read -p " 💡 按 [回车键] 返回主菜单..."; }

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
    echo "=================================================="
    echo "         🚀 动态反代服务管理面板 v$VER"
    echo "=================================================="
    echo
}

install_pkg(){
    echo "ℹ️  正在准备系统环境..."
    apt update >/dev/null 2>&1
    apt install -y curl wget socat gnupg2 ca-certificates software-properties-common lsb-release >/dev/null 2>&1
}

install_openresty(){
    command -v openresty >/dev/null && return 0
    echo "ℹ️  正在安装 OpenResty..."
    rm -f /etc/apt/sources.list.d/openresty.list
    wget -qO- https://openresty.org/package/pubkey.gpg | apt-key add -
    echo "deb http://openresty.org/package/debian $(lsb_release -sc) openresty" \
    > /etc/apt/sources.list.d/openresty.list
    apt update
    apt install -y openresty

    if ! command -v openresty >/dev/null;then
        red "❌ 错误: OpenResty 安装失败！"
        return 1
    fi

    systemctl enable openresty
    return 0
}

write_lua(){
    mkdir -p "$(dirname "$LUA")"
    cat > "$LUA" <<EOF
local dict = ngx.shared.allow_domain
dict:set("filter", "$FILTER")
dict:set("domains", "$ALLOW_DOMAIN")
EOF
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
    default_type text/plain;
    charset utf-8;

    lua_shared_dict allow_domain 10m;
    init_by_lua_file $LUA;

    resolver 1.1.1.1 8.8.8.8 208.67.222.222 valid=300s ipv6=off;

    server {
        listen 80;
        server_name $DOMAIN;

        set \$upstream "";
        set \$target_host "";
        set \$target_scheme "";

        location / {
            rewrite_by_lua_block {
                local uri = ngx.var.request_uri
                local pure_uri = uri:match("^([^?]+)") or uri
                local target = pure_uri:sub(2)

                if target == "" then
                    ngx.status = 400
                    ngx.header.content_type="text/plain; charset=utf-8"
                    ngx.say("❌ 400 缺少目标地址\n\n[正确格式]: http://" .. ngx.var.host .. "/目标域名\n[示例]: http://" .. ngx.var.host .. "/example.com\n")
                    return ngx.exit(400)
                end

                local url = target
                if not url:match("^https?://") then
                    url="https://"..url
                end

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
                        ngx.say("⚠️ 403 目标域名不在白名单内\n")
                        return ngx.exit(403)
                    end
                end

                local scheme, host, path = url:match("^(https?://)([^/]+)(.*)")
                if not path or path == "" then
                    path = "/"
                end
                ngx.req.set_uri(path)

                ngx.var.target_scheme = scheme:gsub("://", "")
                ngx.var.target_host = host
                ngx.var.upstream = scheme .. host
            }

            proxy_pass \$upstream;

            proxy_set_header Host \$target_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$target_scheme;

            proxy_ssl_server_name on;
            proxy_ssl_verify off;
            proxy_intercept_errors on;
            proxy_http_version 1.1;

            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";

            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 43200s;
            proxy_send_timeout 43200s;
        }

        error_page 502 = @err502;
        error_page 504 = @err504;

        location @err502 {
            default_type text/plain;
            return 502 "❌ 502 代理失败\n\n[排查提示]:\n1. 请检查目标源站是否可以正常访问。\n2. 源站可能封禁了此服务器 IP。\n3. DNS 解析超时，请刷新重试。\n";
        }

        location @err504 {
            default_type text/plain;
            return 504 "❌ 504 请求超时\n\n[提示]: 目标源站响应超时。\n";
        }
    }
}
EOF

    openresty -t >/dev/null 2>&1
    if [ $? != 0 ];then
        red "❌ 错误: Nginx 配置校验失败！"
        return 1
    fi

    systemctl restart openresty
    green "✅ 成功: 配置已重构并应用！"
}

install(){
    header
    install_pkg
    install_openresty

    if [ $? != 0 ];then
        pause
        return
    fi

    echo "⚡ 请输入绑定的代理域名："
    read -p " 👉 域名: " DOMAIN
    if [ -z "$DOMAIN" ];then
        red "❌ 错误: 域名不能为空！"
        pause
        return
    fi
    
    FILTER="0"
    ALLOW_DOMAIN=""
    save

    make_nginx
    if [ $? != 0 ];then
        red "❌ 错误: 初始化失败！"
        pause
        return
    fi

    green "=================================================="
    green " 🎉 反代服务部署成功！"
    green "=================================================="
    echo " ℹ️  访问格式: http://$DOMAIN/目标地址"
    echo " 💡 示例: http://$DOMAIN/example.com"
    pause
}

white(){
    while true
    do
        header
        echo "🛡️  白名单管理"
        echo "--------------------------------------------------"
        echo -n " 🔒 状态: "
        if [ "$FILTER" = "1" ];then
            green "已开启 (仅放行列表内域名)"
        else
            yellow "已关闭 (允许代理任何网站)"
        fi

        echo " 📋 列表:"
        if [ -z "$ALLOW_DOMAIN" ];then
            echo "    (暂无域名)"
        else
            echo "$ALLOW_DOMAIN" | tr "|" "\n" | sed 's/^/    🔹 /'
        fi
        echo "--------------------------------------------------"
        echo "  [1] 开启白名单"
        echo "  [2] 关闭白名单"
        echo "  [3] 添加域名"
        echo "  [4] 删除域名"
        echo "  [5] 清空列表"
        echo "  [0] 保存并返回"
        echo "--------------------------------------------------"
        echo

        read -p " 👉 请选择 [0-5]: " W
        case $W in
            1) FILTER="1" ;;
            2) FILTER="0" ;;
            3)
                echo
                read -p " ➕ 输入放行域名 (例如 example.com): " ADD
                if [ -n "$ADD" ];then
                    if [ -z "$ALLOW_DOMAIN" ];then
                        ALLOW_DOMAIN="$ADD"
                    else
                        ALLOW_DOMAIN="$ALLOW_DOMAIN|$ADD"
                    fi
                fi
            ;;
            4)
                echo
                read -p " ➖ 输入删除域名: " DEL
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
            0) 
                save
                make_nginx
                return 
            ;;
            *) red "❌ 输入错误！" ;;
        esac
        save
        make_nginx
        pause
    done
}

show(){
    header
    echo "🔍 当前配置参数:"
    echo "--------------------------------------------------"
    echo " 🌐 代理域名: $DOMAIN"
    echo -n " 🛡️ 白名单状态: "
    [ "$FILTER" = "1" ] && green "已开启" || yellow "已关闭"
    echo " 📝 允许的域名: ${ALLOW_DOMAIN:-未设置}"
    echo "--------------------------------------------------"
    pause
}

reload(){
    header
    openresty -t >/dev/null 2>&1
    if [ $? = 0 ];then
        systemctl reload openresty
        green "✅ 成功: 服务已重载！"
    else
        red "❌ 错误: Nginx 配置存在致命错误！"
    fi
    pause
}

remove(){
    header
    red "⚠️  警告：该操作将清除所有反代服务与配置！"
    read -p " 🤔 确定卸载吗？(确认输入 y, 取消按回车): " CONFIRM
    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ];then
        systemctl stop openresty 2>/dev/null
        apt remove --purge -y openresty* 2>/dev/null
        rm -rf /usr/local/openresty rm -rf "$CONF"
        green "✅ 成功: 已卸载完毕！"
    else
        yellow "ℹ️  操作已取消。"
    fi
    pause
}

menu(){
    while true
    do
        header
        echo "请选择操作:"
        echo "--------------------------------------------------"
        echo "  [1] 安装 / 初始化反代"
        echo "  [2] 白名单管理"
        echo "  [3] 查看当前配置"
        echo "  [4] 重载服务 / 刷新缓存"
        echo "  [5] 卸载反代系统"
        echo "  [0] 退出脚本"
        echo "--------------------------------------------------"
        echo

        read -p " 👉 请输入选项 [0-5]: " M
        case $M in
            1) install ;;
            2) white ;;
            3) show ;;
            4) reload ;;
            5) remove ;;
            0) clear; exit 0 ;;
            *) red "❌ 提示: 输入无效！"; sleep 1 ;;
        esac
    done
}

if [ "$(id -u)" != "0" ];then
    echo -e "\033[31m❌ 错误: 必须使用 root 用户运行！\033[0m"
    exit 1
fi

init
menu
