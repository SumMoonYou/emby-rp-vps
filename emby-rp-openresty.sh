#!/bin/bash
# ==================================================
# Emby 动态反代管理脚本
# Version: v1.6
# --------------------------------------------------
# 功能说明：
#   1. 安装 OpenResty 作为动态反向代理
#   2. 支持 HTTP(80) / HTTPS(443)，自动申请 Let's Encrypt 证书
#   3. 同时监听 IPv4 + IPv6
#   4. 可选域名白名单（根域名自动放行全部子域名）
#   5. 默认仅允许中国大陆 IP 访问（可开关）
#   6. 访问格式：https://你的域名/目标地址
#      例：https://proxy.example.com/https://emby.xxx.com
# --------------------------------------------------
# 系统要求：Debian / Ubuntu（apt + systemd）
# 必须以 root 运行
# ==================================================
VER="v1.6"

# ==================== 路径常量定义 ====================
CONF="/etc/emby-rp.conf"                              # 脚本持久化配置文件
NGINX="/usr/local/openresty/nginx/conf/nginx.conf"    # OpenResty 主配置文件
LUA="/usr/local/openresty/nginx/conf/lua_init.lua"    # Lua 初始化文件（存放白名单等）
SERVICE="/etc/systemd/system/emby-proxy.service"      # 自定义 systemd 服务文件
SSL_DIR="/usr/local/openresty/nginx/conf/ssl"         # SSL 证书存放目录
ACME_HOME="/root/.acme.sh"                            # acme.sh 安装目录
ACME_WEBROOT="/var/www/acme"                          # ACME HTTP-01 验证目录
CHINA_IP_CONF="/usr/local/openresty/nginx/conf/china_ip.conf"  # 中国 IP 库（geo 格式）
CHINA_IP_URL="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"  # 中国 IP 库下载地址

# ==================== 终端颜色输出函数 ====================
green(){ echo -e "\033[32m$1\033[0m"; }    # 绿色成功提示
red(){ echo -e "\033[31m$1\033[0m"; }      # 红色错误提示
yellow(){ echo -e "\033[33m$1\033[0m"; }   # 黄色警告提示
blue(){ echo -e "\033[36m$1\033[0m"; }     # 蓝色信息提示

# 暂停并等待用户按回车
pause(){
    echo
    read -p "💡 按回车返回主菜单..."
}

# 清屏并显示标题
header(){
    clear
    echo "=================================================="
    echo "        🚀 动态反代服务管理面板 $VER"
    echo "        Emby / CDN Reverse Proxy"
    echo "=================================================="
    echo
}

# ==================== 配置加载与保存 ====================
# 加载配置文件，如果不存在则创建默认配置
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
    # 兼容旧版配置（没有对应字段时使用默认值）
    [ -z "${HTTPS:-}" ] && HTTPS="0"
    [ -z "${CHINA_ONLY:-}" ] && CHINA_ONLY="1"
}

# 将当前内存中的配置变量写回配置文件
save(){
    cat > "$CONF" <<EOF
DOMAIN="$DOMAIN"
FILTER="$FILTER"
ALLOW_DOMAIN="$ALLOW_DOMAIN"
HTTPS="$HTTPS"
CHINA_ONLY="$CHINA_ONLY"
EOF
}

# ==================== 中国 IP 库相关 ====================
# 下载最新中国大陆 IP 列表，并转换为 Nginx geo 模块可用的格式
update_china_ip(){
    blue "ℹ️ 正在更新中国大陆 IP 库..."
    mkdir -p "$(dirname "$CHINA_IP_CONF")"
    local tmp="/tmp/china_ip_list.txt"

    # 下载原始 CIDR 列表
    if ! curl -fsSL --connect-timeout 15 --max-time 60 "$CHINA_IP_URL" -o "$tmp"; then
        red "❌ 下载中国 IP 列表失败，请检查网络"
        return 1
    fi

    # 转换为 nginx geo 格式：  1.2.3.0/24 1;
    awk '{print $1 " 1;"}' "$tmp" > "$CHINA_IP_CONF"
    rm -f "$tmp"

    local count=$(wc -l < "$CHINA_IP_CONF")
    green "✅ 中国 IP 库更新完成（共 $count 条）"
    return 0
}

# ==================== 系统依赖安装 ====================
# 安装基础依赖包
install_pkg(){
    blue "ℹ️ 正在准备系统环境..."
    apt update >/dev/null 2>&1
    apt install -y curl wget socat gnupg2 ca-certificates \
        software-properties-common lsb-release apt-transport-https cron >/dev/null 2>&1
    green "✅ 系统环境准备完成"
}

# 安装 OpenResty（已安装则跳过）
install_openresty(){
    if command -v openresty >/dev/null 2>&1; then
        green "✅ OpenResty 已安装"
        return 0
    fi

    blue "ℹ️ 正在安装 OpenResty..."
    CODENAME=$(lsb_release -sc)

    # 优先使用新版 signed-by 方式添加源
    if wget -qO- https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg 2>/dev/null; then
        echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/debian $CODENAME openresty" \
            > /etc/apt/sources.list.d/openresty.list
    else
        # 旧系统回退到 apt-key 方式
        wget -qO- https://openresty.org/package/pubkey.gpg | apt-key add - >/dev/null 2>&1
        echo "deb http://openresty.org/package/debian $CODENAME openresty" \
            > /etc/apt/sources.list.d/openresty.list
    fi

    apt update
    apt install -y openresty

    if ! command -v openresty >/dev/null 2>&1; then
        red "❌ OpenResty 安装失败"
        return 1
    fi

    systemctl enable openresty >/dev/null 2>&1
    green "✅ OpenResty 安装完成"
}

# 安装 acme.sh（Let's Encrypt 客户端）
install_acme(){
    if [ -f "$ACME_HOME/acme.sh" ]; then
        green "✅ acme.sh 已安装"
        return 0
    fi

    blue "ℹ️ 正在安装 acme.sh..."
    curl -s https://get.acme.sh | sh -s email=admin@${DOMAIN:-localhost} >/dev/null 2>&1
    export PATH="$ACME_HOME:$PATH"
    [ -f /root/.bashrc ] && source /root/.bashrc 2>/dev/null

    if [ ! -f "$ACME_HOME/acme.sh" ]; then
        red "❌ acme.sh 安装失败"
        return 1
    fi

    # 默认使用 Let's Encrypt 作为 CA
    "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1
    green "✅ acme.sh 安装完成"
}

# ==================== 证书申请相关 ====================
# 申请并安装证书（优先 webroot，失败后回退 standalone）
issue_cert(){
    local domain="$1"
    mkdir -p "$SSL_DIR" "$ACME_WEBROOT"

    blue "ℹ️ 正在为 $domain 申请证书..."
    yellow "⚠️ 请确保：1. 域名已解析到本机  2. 80 端口对外开放"

    export PATH="$ACME_HOME:$PATH"

    # 先写入临时 nginx 配置，保证 ACME 验证能正常响应
    write_acme_temp_nginx "$domain"
    systemctl restart openresty 2>/dev/null || systemctl restart emby-proxy 2>/dev/null || true
    sleep 1

    # 方式一：webroot（推荐，不独占 80 端口）
    blue "ℹ️ 尝试 webroot 模式..."
    "$ACME_HOME/acme.sh" --issue -d "$domain" -w "$ACME_WEBROOT" --keylength 2048 --force
    local ok=$?

    # 方式二：standalone 回退（需要短暂停止占用 80 端口的服务）
    if [ $ok -ne 0 ]; then
        yellow "⚠️ webroot 失败，尝试 standalone..."
        systemctl stop openresty 2>/dev/null || true
        systemctl stop nginx 2>/dev/null || true
        systemctl stop emby-proxy 2>/dev/null || true
        fuser -k 80/tcp 2>/dev/null || true
        "$ACME_HOME/acme.sh" --issue -d "$domain" --standalone --keylength 2048 --force
        ok=$?
    fi

    if [ $ok -ne 0 ]; then
        red "❌ 证书申请失败"
        return 1
    fi

    # 安装证书到固定路径，并设置续期后自动重载
    "$ACME_HOME/acme.sh" --install-cert -d "$domain" \
        --key-file       "$SSL_DIR/${domain}.key" \
        --fullchain-file "$SSL_DIR/${domain}.fullchain.pem" \
        --reloadcmd      "systemctl reload openresty 2>/dev/null || systemctl reload emby-proxy 2>/dev/null || true"

    if [ $? -ne 0 ]; then
        red "❌ 证书安装失败"
        return 1
    fi

    chmod 600 "$SSL_DIR/${domain}.key"
    chmod 644 "$SSL_DIR/${domain}.fullchain.pem"
    green "✅ 证书申请并安装成功"
    return 0
}

# 生成仅用于 ACME 验证的临时 nginx 配置
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

# ==================== Lua 与 systemd ====================
# 将白名单等配置写入 Lua 共享字典（nginx 启动时加载）
write_lua(){
    mkdir -p "$(dirname "$LUA")"
    cat > "$LUA" <<EOF
local dict = ngx.shared.allow_domain
dict:set("filter", "$FILTER")
dict:set("domains", "$ALLOW_DOMAIN")
EOF
}

# 创建自定义 systemd 服务（可选，主要仍使用 openresty 服务）
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

# ==================== 核心反代配置生成 ====================
# 生成反代核心 location（包含中国 IP 检查 + Lua 解析目标地址 + 白名单校验）
gen_proxy_location(){
    local china_check=""
    # 如果开启了中国 IP 限制，则生成对应的检查代码
    if [ "$CHINA_ONLY" = "1" ]; then
        china_check='
        # ---------- 中国大陆 IP 访问限制 ----------
        if ($is_cn = 0) {
            add_header Content-Type "text/plain; charset=utf-8" always;
            return 403 "⚠️ 403 禁止访问（仅限中国大陆地区IP）\n";
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
            -- 路径去掉开头的 / 后即为目标地址
            local target = pure_uri:sub(2)
            if target == "" then
                ngx.status = 400
                ngx.header.content_type = "text/plain;charset=utf-8"
                ngx.say([[
❌ 400 请求错误
缺少目标地址
正确格式:
https://你的域名/目标地址
]])
                return ngx.exit(400)
            end
            local url = target
            -- 未写协议时默认按 https
            if not url:match("^https?://") then
                url = "https://" .. url
            end
            -- 白名单校验
            local dict = ngx.shared.allow_domain
            if dict:get("filter") == "1" then
                local check_host = url:match("^https?://([^/]+)")
                if check_host then
                    check_host = check_host:lower()
                    -- 去掉端口号
                    check_host = check_host:match("^([^:]+)") or check_host
                end
                local allow = false
                for domain in string.gmatch(dict:get("domains") or "", "[^|]+") do
                    domain = domain:lower()
                    domain = domain:match("^([^:]+)") or domain
                    -- 精确匹配 或 子域名匹配（根域名放行全部子域名）
                    if check_host == domain or (#check_host > #domain and check_host:sub(-#domain - 1) == "." .. domain) then
                        allow = true
                        break
                    end
                end
                if not allow then
                    ngx.status = 403
                    ngx.header.content_type = "text/plain;charset=utf-8"
                    ngx.say("⚠️ 403 禁止访问（不在白名单）")
                    return ngx.exit(403)
                end
            end
            local scheme, host, path = url:match("^(https?://)([^/]+)(.*)")
            if not host then
                ngx.status = 400
                ngx.say("❌ 地址解析失败")
                return ngx.exit(400)
            end
            if path == "" then
                path = "/"
            end
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
        # 支持音视频 Range 请求（断点续传）
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

# 根据当前配置生成最终的 nginx.conf
make_nginx(){
    write_lua

    # 如果开启了中国 IP 限制且库文件不存在，则自动下载
    if [ "$CHINA_ONLY" = "1" ] && [ ! -f "$CHINA_IP_CONF" ]; then
        update_china_ip || true
    fi

    PROXY_LOC=$(gen_proxy_location)

    # 生成 geo 模块配置块（仅在开启中国 IP 限制时）
    local geo_block=""
    if [ "$CHINA_ONLY" = "1" ]; then
        geo_block="
    # 中国大陆 IP 判断（0=非中国，1=中国）
    geo \$is_cn {
        default 0;
        include $CHINA_IP_CONF;
    }
"
    fi

    if [ "$HTTPS" = "1" ]; then
        # HTTPS 模式：80 强制跳转 + ACME 验证路径；443 提供服务
        cat > "$NGINX" <<EOF
worker_processes auto;
events {
    worker_connections 4096;
}
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
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout 65;
    client_max_body_size 0;

    # HTTP 服务：ACME 验证 + 强制跳转 HTTPS
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

    # HTTPS 主服务
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
        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
$PROXY_LOC
    }
}
EOF
    else
        # 仅 HTTP 模式
        cat > "$NGINX" <<EOF
worker_processes auto;
events {
    worker_connections 4096;
}
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
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
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

    # 检测配置是否正确
    if ! openresty -t >/dev/null 2>&1; then
        red "❌ nginx 配置检测失败"
        openresty -t
        return 1
    fi

    systemctl restart openresty 2>/dev/null || systemctl restart emby-proxy 2>/dev/null || true
    green "✅ nginx 配置加载成功"
}

# ==================== 安装流程 ====================
install(){
    header
    install_pkg
    install_openresty || { pause; return; }

    read -p "🌐 请输入绑定代理域名: " DOMAIN
    if [ -z "$DOMAIN" ]; then
        red "❌ 域名不能为空"
        pause
        return
    fi

    echo
    yellow "是否开启 HTTPS (443) 并自动申请 Let's Encrypt 证书？"
    read -p "开启 HTTPS？(y/N): " SSL_CHOICE
    if [[ "$SSL_CHOICE" == "y" || "$SSL_CHOICE" == "Y" ]]; then
        HTTPS="1"
    else
        HTTPS="0"
    fi

    FILTER="0"
    ALLOW_DOMAIN=""
    CHINA_ONLY="1"          # 默认开启中国大陆 IP 限制
    save

    # 下载中国 IP 库
    update_china_ip

    if [ "$HTTPS" = "1" ]; then
        install_acme
        if [ $? -ne 0 ]; then
            red "❌ acme.sh 安装失败，回退为仅 HTTP"
            HTTPS="0"
            save
        else
            issue_cert "$DOMAIN"
            if [ $? -ne 0 ]; then
                red "❌ 证书申请失败，回退为仅 HTTP"
                HTTPS="0"
                save
            fi
        fi
    fi

    make_nginx
    make_systemd
    systemctl restart openresty 2>/dev/null || systemctl restart emby-proxy 2>/dev/null || true

    green "🎉 动态反代部署成功"
    echo
    if [ "$HTTPS" = "1" ]; then
        echo "访问格式: https://$DOMAIN/目标地址"
    else
        echo "访问格式: http://$DOMAIN/目标地址"
    fi
    echo
    green "✅ 已默认开启「仅中国大陆 IP 访问」限制"
    echo "   非中国 IP 将收到 403 提示"
    pause
}

# ==================== 证书更新 ====================
renew_cert(){
    header
    if [ -z "$DOMAIN" ]; then
        red "❌ 请先完成安装并设置域名"
        pause
        return
    fi
    if [ "$HTTPS" != "1" ]; then
        yellow "当前未开启 HTTPS，正在开启..."
        HTTPS="1"
        save
    fi
    install_acme || { pause; return; }
    issue_cert "$DOMAIN"
    if [ $? -eq 0 ]; then
        make_nginx
        green "✅ 证书已更新并重载"
    else
        red "❌ 证书更新失败"
    fi
    pause
}

# ==================== 中国 IP 限制管理菜单 ====================
china_ip_menu(){
    while true; do
        header
        echo "🇨🇳 中国大陆 IP 访问限制"
        echo "--------------------------------------------------"
        echo -n "当前状态: "
        if [ "$CHINA_ONLY" = "1" ]; then
            green "已开启（仅允许中国大陆 IP）"
        else
            yellow "已关闭（允许全球 IP）"
        fi
        echo
        if [ -f "$CHINA_IP_CONF" ]; then
            local count=$(wc -l < "$CHINA_IP_CONF" 2>/dev/null || echo 0)
            echo "IP 库条目: $count 条"
            echo "文件位置: $CHINA_IP_CONF"
        else
            yellow "IP 库尚未下载"
        fi
        echo
        echo "[1] 开启中国大陆 IP 限制"
        echo "[2] 关闭中国大陆 IP 限制"
        echo "[3] 立即更新中国 IP 库"
        echo "[0] 保存返回"
        read -p "👉 请选择: " C
        case $C in
            1)
                CHINA_ONLY="1"
                if [ ! -f "$CHINA_IP_CONF" ]; then
                    update_china_ip
                fi
                ;;
            2) CHINA_ONLY="0" ;;
            3) update_china_ip ;;
            0)
                save
                make_nginx
                return
                ;;
            *) red "❌ 输入错误" ;;
        esac
        save
        make_nginx
    done
}

# ==================== 域名白名单管理 ====================
white(){
    while true; do
        header
        echo "🛡️ 域名白名单管理"
        echo "--------------------------------------------------"
        yellow "提示: 添加根域名(如 example.com) 将自动放行其全部子域名"
        echo "--------------------------------------------------"
        echo -n "当前状态: "
        if [ "$FILTER" = "1" ]; then
            green "开启"
        else
            yellow "关闭"
        fi
        echo
        echo "允许域名:"
        if [ -z "$ALLOW_DOMAIN" ]; then
            echo "  (暂无)"
        else
            echo "$ALLOW_DOMAIN" | tr "|" "\n" | sed 's/^/  /'
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
            1) FILTER="1" ;;
            2) FILTER="0" ;;
            3)
                read -p "输入域名(根域名将放行全部子域名): " ADD
                if [ -n "$ADD" ]; then
                    if [ -z "$ALLOW_DOMAIN" ]; then
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
                for d in "${ARR[@]}"; do
                    if [ "$d" != "$DEL" ] && [ -n "$d" ]; then
                        if [ -z "$NEW" ]; then
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
            *) red "❌ 输入错误" ;;
        esac
        save
        make_nginx
    done
}

# ==================== 查看当前配置 ====================
show(){
    header
    echo "🔍 当前配置"
    echo "--------------------------------------------------"
    echo "🌐 域名:       $DOMAIN"
    echo -n "🔒 HTTPS:      "
    if [ "$HTTPS" = "1" ]; then
        green "已开启 (443)"
        echo "📜 证书:       $SSL_DIR/$DOMAIN.fullchain.pem"
        if [ -f "$SSL_DIR/$DOMAIN.fullchain.pem" ]; then
            echo -n "📅 到期:       "
            openssl x509 -in "$SSL_DIR/$DOMAIN.fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "未知"
        fi
    else
        yellow "未开启 (仅 80)"
    fi
    echo -n "🇨🇳 中国IP限制: "
    if [ "$CHINA_ONLY" = "1" ]; then
        green "已开启"
    else
        yellow "已关闭"
    fi
    echo "🛡️ 域名白名单: $FILTER"
    echo "📋 白名单列表: ${ALLOW_DOMAIN:-无}"
    echo "📡 监听:       IPv4 + IPv6"
    echo "--------------------------------------------------"
    pause
}

# ==================== 重载服务 ====================
reload(){
    header
    if openresty -t; then
        systemctl reload openresty 2>/dev/null || systemctl reload emby-proxy 2>/dev/null || true
        green "✅ 重载成功"
    else
        red "❌ 配置错误"
    fi
    pause
}

# ==================== 完全卸载 ====================
remove(){
    header
    yellow "将完全卸载以下内容："
    echo "  - OpenResty"
    echo "  - 反代配置 / 服务"
    echo "  - SSL 证书文件"
    echo "  - acme.sh 及所有证书备份"
    echo "  - 中国 IP 库"
    echo
    read -p "⚠️ 确认完全卸载？(y): " OK
    if [[ "$OK" == "y" || "$OK" == "Y" ]]; then
        systemctl stop openresty 2>/dev/null || true
        systemctl stop emby-proxy 2>/dev/null || true
        systemctl disable openresty 2>/dev/null || true
        systemctl disable emby-proxy 2>/dev/null || true
        apt remove --purge -y openresty* >/dev/null 2>&1
        apt autoremove -y >/dev/null 2>&1
        rm -f "$CONF" "$SERVICE"
        rm -rf "$SSL_DIR"
        rm -rf /usr/local/openresty
        rm -rf "$ACME_HOME"
        rm -rf "$ACME_WEBROOT"
        rm -f /etc/apt/sources.list.d/openresty.list
        rm -f /usr/share/keyrings/openresty.gpg
        rm -f "$CHINA_IP_CONF"
        # 清理 acme.sh 定时任务
        crontab -l 2>/dev/null | grep -v 'acme.sh' | crontab - 2>/dev/null || true
        systemctl daemon-reload
        green "✅ 已全部卸载干净"
    else
        yellow "已取消"
    fi
    pause
}

# ==================== 主菜单 ====================
menu(){
    while true; do
        header
        echo "[1] 🚀 安装/初始化"
        echo "[2] 🛡️ 域名白名单管理"
        echo "[3] 🇨🇳 中国大陆IP限制"
        echo "[4] 🔍 查看配置"
        echo "[5] 🔄 重载服务"
        echo "[6] 🔐 重新申请/更新证书"
        echo "[7] 🗑️ 卸载"
        echo "[0] 退出"
        read -p "👉 请选择: " M
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

# ==================== 脚本入口 ====================
if [ "$(id -u)" != "0" ]; then
    red "❌ 请使用 root 运行"
    exit 1
fi
init
menu
