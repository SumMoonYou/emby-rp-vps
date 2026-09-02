#!/bin/bash
# ==================================================
# Emby 动态反代管理脚本
# Version: v2.0
# --------------------------------------------------
# 功能：
#   1. 动态反向代理（通过路径直接指定目标地址）
#   2. 可选 HTTPS（使用 acme.sh + Let's Encrypt）
#   3. 中国大陆 IP 访问限制（基于 IP 库）
#   4. 域名白名单过滤（防止滥用）
# 系统要求：Debian / Ubuntu，必须以 root 运行
# ==================================================
VER="v2.0"

# ---------- 路径定义 ----------
CONF="/etc/emby-rp.conf"                          # 主配置文件（域名、开关等）
NGINX="/usr/local/openresty/nginx/conf/nginx.conf" # OpenResty 主配置文件
LUA="/usr/local/openresty/nginx/conf/lua_init.lua" # Lua 初始化脚本（白名单相关）
SERVICE="/etc/systemd/system/emby-proxy.service"  # systemd 服务文件
SSL_DIR="/usr/local/openresty/nginx/conf/ssl"     # SSL 证书存放目录
ACME_HOME="/root/.acme.sh"                        # acme.sh 安装目录
ACME_WEBROOT="/var/www/acme"                      # ACME 验证用 webroot
CHINA_IP_CONF="/usr/local/openresty/nginx/conf/china_ip.conf"  # 中国 IP 库（geo 格式）
CHINA_IP_URL="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"  # 中国 IP 列表源

# ---------- 颜色输出函数 ----------
green(){ echo -e "\033[32m$1\033[0m"; }   # 成功/正常信息
red(){ echo -e "\033[31m$1\033[0m"; }     # 错误信息
yellow(){ echo -e "\033[33m$1\033[0m"; }  # 警告/提示信息
blue(){ echo -e "\033[36m$1\033[0m"; }    # 进度/普通信息
pause(){ echo; read -p "按回车返回..." ; } # 暂停等待用户确认

# 清屏并显示标题
header(){
    clear
    echo "========================================"
    echo "   动态反代管理面板  $VER"
    echo "========================================"
    echo
}

# ---------- 配置读写 ----------
# 初始化配置文件（不存在时创建默认配置）
init(){
    if [ ! -f "$CONF" ]; then
        cat > "$CONF" <<EOF
DOMAIN=""
FILTER="0"
ALLOW_DOMAIN=""
HTTPS="0"
CHINA_ONLY="1"
EOF
    fi
    source "$CONF"
    # 兼容旧版本配置（缺少变量时补默认值）
    [ -z "${HTTPS:-}" ] && HTTPS="0"
    [ -z "${CHINA_ONLY:-}" ] && CHINA_ONLY="1"
}

# 将当前变量写回配置文件
save(){
    cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
FILTER="$FILTER"
ALLOW_DOMAIN="$ALLOW_DOMAIN"
HTTPS="$HTTPS"
CHINA_ONLY="$CHINA_ONLY"
EOF
}

# ---------- 中国 IP 库管理 ----------
# 下载并转换中国大陆 IP 列表为 nginx geo 模块可用格式
update_china_ip(){
    blue "ℹ️ 更新中国IP库..."
    mkdir -p "$(dirname "$CHINA_IP_CONF")"
    local tmp="/tmp/china_ip_list.txt"
    if ! curl -fsSL --connect-timeout 15 --max-time 60 "$CHINA_IP_URL" -o "$tmp"; then
        red "❌ 下载失败"
        return 1
    fi
    # 转换为 geo 格式：IP段 1;
    awk '{print $1 " 1;"}' "$tmp" > "$CHINA_IP_CONF"
    rm -f "$tmp"
    green "✅ 更新完成（$(wc -l < "$CHINA_IP_CONF") 条）"
}

# ---------- 依赖安装 ----------
# 安装基础依赖包
install_pkg(){
    blue "ℹ️ 安装依赖..."
    apt update >/dev/null 2>&1
    apt install -y curl wget socat gnupg2 ca-certificates \
        software-properties-common lsb-release apt-transport-https cron >/dev/null 2>&1
    green "✅ 完成"
}

# 安装 OpenResty（Nginx + Lua）
install_openresty(){
    if command -v openresty >/dev/null 2>&1; then
        green "✅ OpenResty 已安装"
        return 0
    fi
    blue "ℹ️ 安装 OpenResty..."
    CODENAME=$(lsb_release -sc)
    # 优先使用新版 gpg 密钥方式，失败则回退到旧版 apt-key
    if wget -qO- https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg 2>/dev/null; then
        echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/debian $CODENAME openresty" \
            > /etc/apt/sources.list.d/openresty.list
    else
        wget -qO- https://openresty.org/package/pubkey.gpg | apt-key add - >/dev/null 2>&1
        echo "deb http://openresty.org/package/debian $CODENAME openresty" \
            > /etc/apt/sources.list.d/openresty.list
    fi
    apt update >/dev/null 2>&1
    apt install -y openresty >/dev/null 2>&1
    if ! command -v openresty >/dev/null 2>&1; then
        red "❌ 安装失败"
        return 1
    fi
    systemctl enable openresty >/dev/null 2>&1
    green "✅ 安装完成"
}

# 安装 acme.sh（证书申请工具）
install_acme(){
    if [ -f "$ACME_HOME/acme.sh" ]; then
        green "✅ acme.sh 已安装"
        return 0
    fi
    blue "ℹ️ 安装 acme.sh..."
    curl -s https://get.acme.sh | sh -s email=admin@${DOMAIN:-localhost} >/dev/null 2>&1
    export PATH="$ACME_HOME:$PATH"
    [ -f /root/.bashrc ] && source /root/.bashrc 2>/dev/null
    if [ ! -f "$ACME_HOME/acme.sh" ]; then
        red "❌ 安装失败"
        return 1
    fi
    # 默认使用 Let's Encrypt
    "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1
    green "✅ 安装完成"
}

# ---------- 证书相关 ----------
# 申请并安装 SSL 证书（优先 webroot，失败则尝试 standalone）
issue_cert(){
    local domain="$1"
    mkdir -p "$SSL_DIR" "$ACME_WEBROOT"
    blue "ℹ️ 申请证书 $domain ..."
    export PATH="$ACME_HOME:$PATH"

    # 先写入临时 nginx 配置，用于 webroot 验证
    write_acme_temp_nginx "$domain"
    systemctl restart openresty 2>/dev/null || systemctl restart emby-proxy 2>/dev/null || true
    sleep 1

    # 尝试 webroot 方式
    "$ACME_HOME/acme.sh" --issue -d "$domain" -w "$ACME_WEBROOT" --keylength 2048 --force >/dev/null 2>&1
    local ok=$?
    if [ $ok -ne 0 ]; then
        yellow "⚠️ webroot失败，尝试standalone"
        # 停止可能占用 80 端口的服务
        systemctl stop openresty 2>/dev/null || true
        systemctl stop nginx 2>/dev/null || true
        systemctl stop emby-proxy 2>/dev/null || true
        fuser -k 80/tcp 2>/dev/null || true
        "$ACME_HOME/acme.sh" --issue -d "$domain" --standalone --keylength 2048 --force >/dev/null 2>&1
        ok=$?
    fi
    if [ $ok -ne 0 ]; then
        red "❌ 证书申请失败"
        return 1
    fi

    # 安装证书并设置自动重载命令
    "$ACME_HOME/acme.sh" --install-cert -d "$domain" \
        --key-file       "$SSL_DIR/${domain}.key" \
        --fullchain-file "$SSL_DIR/${domain}.fullchain.pem" \
        --reloadcmd      "systemctl reload openresty 2>/dev/null || systemctl reload emby-proxy 2>/dev/null || true" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        red "❌ 证书安装失败"
        return 1
    fi
    chmod 600 "$SSL_DIR/${domain}.key"
    chmod 644 "$SSL_DIR/${domain}.fullchain.pem"
    green "✅ 证书成功"
}

# 写入临时 nginx 配置（仅用于 ACME 验证）
write_acme_temp_nginx(){
    local domain="$1"
    mkdir -p "$ACME_WEBROOT"
    cat > "$NGINX" <<EOF
worker_processes auto;
events { worker_connections 1024; }
http {
    server {
        listen 80;
        listen [::]:80;
        server_name $domain;
        location /.well-known/acme-challenge/ {
            root $ACME_WEBROOT;
            default_type text/plain;
        }
        location / {
            return 200 'acme-ready';
            add_header Content-Type text/plain;
        }
    }
}
EOF
    openresty -t >/dev/null 2>&1 || true
}

# 写入 Lua 初始化脚本（把白名单配置注入共享字典）
write_lua(){
    mkdir -p "$(dirname "$LUA")"
    cat > "$LUA" <<EOF
local dict = ngx.shared.allow_domain
dict:set("filter", "$FILTER")
dict:set("domains", "$ALLOW_DOMAIN")
EOF
}

# 创建并启用 systemd 服务
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

# ---------- 生成反代 location 配置 ----------
# 生成核心反向代理 location 块（含中国 IP 检查 + Lua 动态解析目标）
gen_proxy_location(){
    local china_check=""
    if [ "$CHINA_ONLY" = "1" ]; then
        # 非中国 IP 直接返回 403
        china_check='
        if ($is_cn = 0) {
            add_header Content-Type "text/plain; charset=utf-8" always;
            return 403 "⚠️ 403 仅限中国大陆IP访问";
        }
'
    fi
    cat <<LOC
    location / {
$china_check
        set \$upstream "";
        set \$target_host "";
        set \$target_scheme "";
        rewrite_by_lua_block {
            local uri = ngx.var.request_uri
            local pure_uri, args = uri:match("^([^?]*)%??(.*)$")
            local target = pure_uri:sub(2)   -- 去掉开头的 /
            if target == "" then
                ngx.status = 400
                ngx.header.content_type = "text/plain;charset=utf-8"
                ngx.say("❌ 400 缺少目标地址")
                return ngx.exit(400)
            end
            local url = target
            -- 若未带协议，默认补 https://
            if not url:match("^https?://") then
                url = "https://" .. url
            end
            -- 白名单校验
            local dict = ngx.shared.allow_domain
            if dict:get("filter") == "1" then
                local check_host = url:match("^https?://([^/]+)")
                if check_host then
                    check_host = check_host:lower()
                    check_host = check_host:match("^([^:]+)") or check_host  -- 去掉端口
                end
                local allow = false
                for domain in string.gmatch(dict:get("domains") or "", "[^|]+") do
                    domain = domain:lower()
                    domain = domain:match("^([^:]+)") or domain
                    -- 精确匹配或子域名匹配
                    if check_host == domain or (#check_host > #domain and check_host:sub(-#domain - 1) == "." .. domain) then
                        allow = true
                        break
                    end
                end
                if not allow then
                    ngx.status = 403
                    ngx.header.content_type = "text/plain;charset=utf-8"
                    ngx.say("⚠️ 403 不在白名单")
                    return ngx.exit(403)
                end
            end
            -- 解析目标地址
            local scheme, host, path = url:match("^(https?://)([^/]+)(.*)")
            if not host then
                ngx.status = 400
                ngx.header.content_type = "text/plain;charset=utf-8"
                ngx.say("❌ 400 地址解析失败")
                return ngx.exit(400)
            end
            if path == "" then path = "/" end
            ngx.req.set_uri(path)
            if args and args ~= "" then
                ngx.req.set_uri_args(args)
            end
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
        proxy_ssl_name \$target_host;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_force_ranges on;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
    error_page 502 = @error502;
    error_page 504 = @error504;
    location @error502 {
        default_type text/plain;
        return 502 "❌ 502 源站连接失败";
    }
    location @error504 {
        default_type text/plain;
        return 504 "❌ 504 请求超时";
    }
LOC
}

# 生成完整 nginx 配置并重载
make_nginx(){
    write_lua
    # 开启中国 IP 限制但 IP 库不存在时自动更新
    if [ "$CHINA_ONLY" = "1" ] && [ ! -f "$CHINA_IP_CONF" ]; then
        update_china_ip || true
    fi
    PROXY_LOC=$(gen_proxy_location)
    local geo_block=""
    if [ "$CHINA_ONLY" = "1" ]; then
        geo_block="
    geo \$is_cn {
        default 0;
        include $CHINA_IP_CONF;
    }
"
    fi

    if [ "$HTTPS" = "1" ]; then
        # HTTPS 模式：80 跳转 443，并启用 HSTS
        cat > "$NGINX" <<EOF
worker_processes auto;
events { worker_connections 4096; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    lua_shared_dict allow_domain 10m;
    init_by_lua_file $LUA;
$geo_block
    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;
    resolver_timeout 5s;
    real_ip_header    CF-Connecting-IP;
    real_ip_recursive on;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 0;
    server {
        listen 80;
        listen [::]:80;
        server_name $DOMAIN;
        location /.well-known/acme-challenge/ {
            root /var/www/acme;
            default_type text/plain;
        }
        location / {
            return 301 https://\$host\$request_uri;
        }
    }
    server {
        listen 443 ssl;
        listen [::]:443 ssl;
        http2 on;
        server_name $DOMAIN;
        ssl_certificate     $SSL_DIR/$DOMAIN.fullchain.pem;
        ssl_certificate_key $SSL_DIR/$DOMAIN.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
$PROXY_LOC
    }
}
EOF
    else
        # 纯 HTTP 模式
        cat > "$NGINX" <<EOF
worker_processes auto;
events { worker_connections 4096; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    lua_shared_dict allow_domain 10m;
    init_by_lua_file $LUA;
$geo_block
    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;
    resolver_timeout 5s;
    real_ip_header    CF-Connecting-IP;
    real_ip_recursive on;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 0;
    server {
        listen 80;
        listen [::]:80;
        server_name $DOMAIN;
$PROXY_LOC
    }
}
EOF
    fi

    # 配置语法检查
    if ! openresty -t >/dev/null 2>&1; then
        red "❌ 配置检测失败"
        openresty -t
        return 1
    fi
    systemctl restart openresty 2>/dev/null || systemctl restart emby-proxy 2>/dev/null || true
    green "✅ 配置已加载"
}

# ---------- 功能菜单 ----------
# 安装/初始化整套服务
install(){
    header
    install_pkg
    install_openresty || { pause; return; }
    read -p "绑定域名: " DOMAIN
    if [ -z "$DOMAIN" ]; then
        red "❌ 域名不能为空"
        pause
        return
    fi
    read -p "开启HTTPS？(y/N): " SSL_CHOICE
    [[ "$SSL_CHOICE" =~ ^[yY]$ ]] && HTTPS="1" || HTTPS="0"
    # 默认关闭白名单，开启中国 IP 限制
    FILTER="0"
    ALLOW_DOMAIN=""
    CHINA_ONLY="1"
    save
    update_china_ip
    if [ "$HTTPS" = "1" ]; then
        install_acme
        if [ $? -ne 0 ]; then
            red "❌ acme安装失败，回退HTTP"
            HTTPS="0"
            save
        else
            issue_cert "$DOMAIN" || {
                red "❌ 证书失败，回退HTTP"
                HTTPS="0"
                save
            }
        fi
    fi
    make_nginx
    make_systemd
    systemctl restart openresty 2>/dev/null || systemctl restart emby-proxy 2>/dev/null || true
    green "✅ 部署成功"
    if [ "$HTTPS" = "1" ]; then
        echo "访问: https://$DOMAIN/目标地址"
    else
        echo "访问: http://$DOMAIN/目标地址"
    fi
    pause
}

# 强制更新证书
renew_cert(){
    header
    if [ -z "$DOMAIN" ]; then
        red "❌ 请先安装并设置域名"
        pause
        return
    fi
    if [ "$HTTPS" != "1" ]; then
        HTTPS="1"
        save
    fi
    install_acme || { pause; return; }
    issue_cert "$DOMAIN" && make_nginx && green "✅ 证书已更新" || red "❌ 更新失败"
    pause
}

# 中国大陆 IP 限制管理子菜单
china_ip_menu(){
    while true; do
        header
        echo "中国大陆IP限制"
        echo "----------------------------------------"
        echo -n "状态: "
        [ "$CHINA_ONLY" = "1" ] && green "已开启" || yellow "已关闭"
        [ -f "$CHINA_IP_CONF" ] && echo "IP库: $(wc -l < "$CHINA_IP_CONF") 条"
        echo
        echo "[1] 开启限制"
        echo "[2] 关闭限制"
        echo "[3] 更新IP库"
        echo "[0] 返回"
        read -p "选择: " C
        case $C in
            1) CHINA_ONLY="1"; [ ! -f "$CHINA_IP_CONF" ] && update_china_ip ;;
            2) CHINA_ONLY="0" ;;
            3) update_china_ip ;;
            0) save; make_nginx; return ;;
            *) red "❌ 输入错误" ;;
        esac
        save
        make_nginx
    done
}

# 域名白名单管理子菜单
white(){
    while true; do
        header
        echo "域名白名单"
        echo "----------------------------------------"
        echo -n "状态: "
        [ "$FILTER" = "1" ] && green "已开启" || yellow "已关闭"
        echo "列表: ${ALLOW_DOMAIN:-无}"
        echo
        echo "[1] 开启限制"
        echo "[2] 关闭限制"
        echo "[3] 添加域名"
        echo "[4] 删除域名"
        echo "[5] 清空域名"
        echo "[0] 返回"
        read -p "选择: " W
        case $W in
            1) FILTER="1" ;;
            2) FILTER="0" ;;
            3)
                read -p "域名: " ADD
                [ -n "$ADD" ] && {
                    [ -z "$ALLOW_DOMAIN" ] && ALLOW_DOMAIN="$ADD" || ALLOW_DOMAIN="$ALLOW_DOMAIN|$ADD"
                }
                ;;
            4)
                read -p "删除: " DEL
                NEW=""
                IFS="|" read -ra ARR <<< "$ALLOW_DOMAIN"
                for d in "${ARR[@]}"; do
                    [ "$d" != "$DEL" ] && [ -n "$d" ] && {
                        [ -z "$NEW" ] && NEW="$d" || NEW="$NEW|$d"
                    }
                done
                ALLOW_DOMAIN="$NEW"
                ;;
            5) ALLOW_DOMAIN="" ;;
            0) save; make_nginx; return ;;
            *) red "❌ 输入错误" ;;
        esac
        save
        make_nginx
    done
}

# 查看当前配置
show(){
    header
    echo "当前配置"
    echo "----------------------------------------"
    echo "域名:     $DOMAIN"
    echo -n "HTTPS:    "
    [ "$HTTPS" = "1" ] && green "已开启" || yellow "未开启"
    echo -n "中国IP:   "
    [ "$CHINA_ONLY" = "1" ] && green "已开启" || yellow "已关闭"
    echo -n "白名单:   "
    [ "$FILTER" = "1" ] && green "已开启" || yellow "已关闭"
    echo "白名单列表: ${ALLOW_DOMAIN:-无}"
    if [ "$HTTPS" = "1" ] && [ -f "$SSL_DIR/$DOMAIN.fullchain.pem" ]; then
        echo -n "证书到期: "
        openssl x509 -in "$SSL_DIR/$DOMAIN.fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "未知"
    fi
    pause
}

# 重载配置（不中断服务）
reload(){
    header
    if openresty -t >/dev/null 2>&1; then
        systemctl reload openresty 2>/dev/null || systemctl reload emby-proxy 2>/dev/null || true
        green "✅ 重载成功"
    else
        red "❌ 配置错误"
        openresty -t
    fi
    pause
}

# 完全卸载
remove(){
    header
    yellow "将卸载 OpenResty、证书、配置、IP库"
    read -p "确认卸载？(y): " OK
    if [[ "$OK" =~ ^[yY]$ ]]; then
        systemctl stop openresty emby-proxy 2>/dev/null || true
        systemctl disable openresty emby-proxy 2>/dev/null || true
        apt remove --purge -y openresty* >/dev/null 2>&1
        apt autoremove -y >/dev/null 2>&1
        rm -rf "$CONF" "$SERVICE" "$SSL_DIR" /usr/local/openresty \
               "$ACME_HOME" "$ACME_WEBROOT" "$CHINA_IP_CONF" \
               /etc/apt/sources.list.d/openresty.list \
               /usr/share/keyrings/openresty.gpg
        # 清理 acme 相关定时任务
        crontab -l 2>/dev/null | grep -v 'acme.sh' | crontab - 2>/dev/null || true
        systemctl daemon-reload
        green "✅ 已卸载"
    else
        yellow "已取消"
    fi
    pause
}

# ---------- 主菜单 ----------
menu(){
    while true; do
        header
        echo "[1] 安装/初始化"
        echo "[2] 域名白名单"
        echo "[3] 中国IP限制"
        echo "[4] 查看配置"
        echo "[5] 重载服务"
        echo "[6] 更新证书"
        echo "[7] 卸载"
        echo "[0] 退出"
        read -p "选择: " M
        case $M in
            1) install ;;
            2) white ;;
            3) china_ip_menu ;;
            4) show ;;
            5) reload ;;
            6) renew_cert ;;
            7) remove ;;
            0) clear; exit 0 ;;
            *) red "❌ 输入错误" ;;
        esac
    done
}

# ---------- 入口 ----------
# 必须使用 root 运行
if [ "$(id -u)" != "0" ]; then
    red "❌ 请使用 root 运行"
    exit 1
fi
init
menu
