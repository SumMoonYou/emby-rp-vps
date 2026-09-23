#!/bin/bash
# ==================================================
# Emby 动态反代管理脚本
# Version: v3.5
# --------------------------------------------------
# 功能概述：
#   1. 动态反向代理：通过 URL 路径直接指定目标地址
#      例如访问 https://your.domain/https://target.com/path
#      Nginx 会用 Lua 解析出 target.com，并把请求代理过去
#   2. 部署模式二选一：
#      - 域名模式：可申请 Let's Encrypt 证书，启用 HTTPS
#      - IP 模式：仅监听 80 端口，不需要域名和证书
#   3. 中国大陆 IP 访问限制：
#      - IPv4 基于 china_ip_list 判断，非中国 IP 返回 403
#      - IPv6 默认全部放行（不参与限制）
#   4. 域名白名单过滤：只允许反代指定的目标域名，防止被滥用为开放代理
#   5. 首页伪装：开启后，所有错误/根路径访问均返回一个简约博客首页
#   6. 自动配置 OpenResty 软件源：
#      - 按系统代号从新到旧尝试，直到找到可用源
#      - 官方 GPG 签名失败时自动回退 trusted=yes
#   7. 日志自动轮转：保留 7 天，自动压缩旧日志
#
# 系统要求：Debian / Ubuntu，必须以 root 运行
# ==================================================

VER="v3.5"

# ==================================================
# 路径定义
# ==================================================
CONF="/etc/emby-rp.conf"                                      # 主配置：模式、域名、开关等
NGINX="/usr/local/openresty/nginx/conf/nginx.conf"            # OpenResty 主配置
LUA="/usr/local/openresty/nginx/conf/lua_init.lua"            # Lua 初始化：加载白名单到共享字典
ALLOW_FILE="/usr/local/openresty/nginx/conf/allow_domains.txt" # 白名单独立文件，每行一个域名
CAMO_FILE="/usr/local/openresty/nginx/conf/camo_index.html"   # 伪装首页（简约博客）
SERVICE="/etc/systemd/system/emby-proxy.service"              # 自定义 systemd 服务
LOGROTATE="/etc/logrotate.d/emby-proxy"                       # 日志轮转配置
SSL_DIR="/usr/local/openresty/nginx/conf/ssl"                 # SSL 证书存放目录
ACME_HOME="/root/.acme.sh"                                    # acme.sh 安装目录
ACME_WEBROOT="/var/www/acme"                                  # ACME webroot 验证目录
CHINA_IP_CONF="/usr/local/openresty/nginx/conf/china_ip.conf" # 中国 IPv4 段（geo 格式）
CHINA_IP_URL="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"

# ==================================================
# 颜色输出函数
# ==================================================
green(){ echo -e "\033[32m$1\033[0m"; }    # 成功
red(){ echo -e "\033[31m$1\033[0m"; }      # 错误
yellow(){ echo -e "\033[33m$1\033[0m"; }   # 警告
blue(){ echo -e "\033[36m$1\033[0m"; }     # 提示
pause(){ echo; read -p "按回车返回..." ; } # 暂停等待

# 顶部标题栏
header(){
    clear
    echo -e "\033[36m╔══════════════════════════════════════════╗\033[0m"
    echo -e "\033[36m║\033[0m        \033[1m动态反代管理面板  $VER\033[0m          \033[36m║\033[0m"
    echo -e "\033[36m╚══════════════════════════════════════════╝\033[0m"
    echo
}

# 二级菜单标题
subheader(){
    echo -e "\033[36m──────────────────────────────────────────\033[0m"
    echo -e "  \033[1m$1\033[0m"
    echo -e "\033[36m──────────────────────────────────────────\033[0m"
}

# 状态显示：开启/关闭
status_on(){ green "已开启"; }
status_off(){ yellow "已关闭"; }

# ==================================================
# 服务控制辅助
# ==================================================
# 重启服务：先停系统自带 openresty，避免和 emby-proxy 冲突
svc_restart(){
    systemctl stop openresty 2>/dev/null
    systemctl disable openresty 2>/dev/null
    systemctl daemon-reload
    systemctl restart emby-proxy 2>/dev/null || {
        pkill -f 'nginx: master' 2>/dev/null
        sleep 1
        /usr/local/openresty/bin/openresty
    }
}
# 平滑重载
svc_reload(){ systemctl reload emby-proxy 2>/dev/null || openresty -s reload 2>/dev/null || true; }
# 停止服务
svc_stop(){
    systemctl stop emby-proxy 2>/dev/null
    systemctl stop openresty 2>/dev/null
    pkill -f 'nginx: master' 2>/dev/null
    true
}

# ==================================================
# 配置读写
# ==================================================
# 初始化配置：文件不存在则创建默认值
init(){
    if [ ! -f "$CONF" ]; then
        cat > "$CONF" <<EOF
MODE="domain"
DOMAIN=""
FILTER="0"
ALLOW_DOMAIN=""
HTTPS="0"
CHINA_ONLY="1"
CAMO="0"
EOF
    fi
    source "$CONF"
    # 兼容旧版本配置：缺失字段补默认值
    : "${MODE:=domain}"
    : "${DOMAIN:=}"
    : "${HTTPS:=0}"
    : "${CHINA_ONLY:=1}"
    : "${FILTER:=0}"
    : "${ALLOW_DOMAIN:=}"
    : "${CAMO:=0}"
}

# 保存当前变量到配置文件
save(){
    cat > "$CONF" <<EOF
MODE="$MODE"
DOMAIN="$DOMAIN"
FILTER="$FILTER"
ALLOW_DOMAIN="$ALLOW_DOMAIN"
HTTPS="$HTTPS"
CHINA_ONLY="$CHINA_ONLY"
CAMO="$CAMO"
EOF
}

# ==================================================
# 中国 IP 库管理
# ==================================================
# 下载并转换为 geo 模块可用的格式（每行：CIDR 1;）
update_china_ip(){
    blue "ℹ️ 更新中国IP库..."
    mkdir -p "$(dirname "$CHINA_IP_CONF")"
    local tmp="/tmp/china_ip_list.txt"
    if ! curl -fsSL --connect-timeout 15 --max-time 60 "$CHINA_IP_URL" -o "$tmp"; then
        red "❌ 下载失败"
        return 1
    fi
    awk '!/^[[:space:]]*#/ && NF>=1 {print $1 " 1;"}' "$tmp" > "$CHINA_IP_CONF"
    rm -f "$tmp"
    if [ ! -s "$CHINA_IP_CONF" ]; then
        red "❌ IP库为空，请检查源"
        return 1
    fi
    green "✅ 更新完成（$(wc -l < "$CHINA_IP_CONF") 条，仅 IPv4）"
}

# ==================================================
# 依赖安装
# ==================================================
install_pkg(){
    blue "ℹ️ 安装基础依赖..."
    apt update >/dev/null 2>&1
    apt install -y curl wget socat gnupg2 ca-certificates \
        software-properties-common lsb-release apt-transport-https cron logrotate >/dev/null 2>&1
    green "✅ 依赖安装完成"
}

# 安装 OpenResty：优先官方签名源，失败回退 trusted=yes；系统代号不支持时向前回退
install_openresty(){
    if command -v openresty >/dev/null 2>&1; then
        green "✅ OpenResty 已安装"
        return 0
    fi
    blue "ℹ️ 开始安装 OpenResty..."

    local CODENAME
    CODENAME=$(lsb_release -sc)

    local CANDIDATES
    case "$CODENAME" in
        trixie)   CANDIDATES="trixie bookworm bullseye" ;;
        bookworm) CANDIDATES="bookworm bullseye" ;;
        bullseye) CANDIDATES="bullseye" ;;
        noble)    CANDIDATES="noble jammy" ;;
        jammy)    CANDIDATES="jammy focal" ;;
        focal)    CANDIDATES="focal" ;;
        *)        CANDIDATES="$CODENAME bookworm jammy" ;;
    esac

    local chosen=""
    local code
    for code in $CANDIDATES; do
        blue "ℹ️ 尝试源代号: $code"
        rm -f /etc/apt/sources.list.d/openresty.list
        rm -f /usr/share/keyrings/openresty.gpg

        local use_official=0
        if wget -qO- https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg 2>/dev/null; then
            echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/debian $code openresty" \
                > /etc/apt/sources.list.d/openresty.list
            if apt update >/dev/null 2>&1 && apt-cache policy openresty 2>/dev/null | grep -q "Candidate:"; then
                use_official=1
            fi
        fi

        if [ "$use_official" = "0" ]; then
            rm -f /usr/share/keyrings/openresty.gpg
            echo "deb [trusted=yes] http://openresty.org/package/debian $code openresty" \
                > /etc/apt/sources.list.d/openresty.list
            apt update >/dev/null 2>&1
        fi

        if apt-cache policy openresty 2>/dev/null | grep -q "Candidate:"; then
            chosen="$code"
            green "✅ 使用源代号: $code"
            break
        else
            yellow "⚠️ $code 源无 openresty 包，尝试下一个"
        fi
    done

    if [ -z "$chosen" ]; then
        red "❌ 所有候选源均不可用，请检查网络或手动配置源"
        return 1
    fi

    blue "ℹ️ 下载并安装 openresty..."
    if ! apt install -y openresty; then
        red "❌ apt install 失败，请检查上方报错"
        return 1
    fi

    if ! command -v openresty >/dev/null 2>&1; then
        red "❌ 安装后仍找不到 openresty 命令"
        return 1
    fi
    systemctl enable openresty >/dev/null 2>&1
    green "✅ OpenResty 安装完成"
}

# 安装 acme.sh（证书申请工具）
install_acme(){
    if [ -f "$ACME_HOME/acme.sh" ]; then
        green "✅ acme.sh 已安装"
        return 0
    fi
    if [ -z "$DOMAIN" ]; then
        red "❌ 请先设置域名再安装 acme.sh"
        return 1
    fi
    blue "ℹ️ 安装 acme.sh..."
    curl -s https://get.acme.sh | sh -s email=admin@"$DOMAIN" >/dev/null 2>&1
    export PATH="$ACME_HOME:$PATH"
    [ -f /root/.bashrc ] && source /root/.bashrc 2>/dev/null
    if [ ! -f "$ACME_HOME/acme.sh" ]; then
        red "❌ 安装失败"
        return 1
    fi
    "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1
    green "✅ acme.sh 安装完成"
}

# ==================================================
# 证书相关
# ==================================================
issue_cert(){
    local domain="$1"
    mkdir -p "$SSL_DIR" "$ACME_WEBROOT"
    blue "ℹ️ 申请证书 $domain ..."
    export PATH="$ACME_HOME:$PATH"

    local bak=""
    if [ -f "$NGINX" ]; then
        bak="${NGINX}.bak.$$"
        cp -a "$NGINX" "$bak"
    fi

    write_acme_temp_nginx "$domain"
    svc_restart
    sleep 1

    "$ACME_HOME/acme.sh" --issue -d "$domain" -w "$ACME_WEBROOT" --keylength 2048 --force >/dev/null 2>&1
    local ok=$?
    if [ $ok -ne 0 ]; then
        yellow "⚠️ webroot 失败，尝试 standalone"
        svc_stop
        fuser -k 80/tcp 2>/dev/null || true
        "$ACME_HOME/acme.sh" --issue -d "$domain" --standalone --keylength 2048 --force >/dev/null 2>&1
        ok=$?
    fi

    if [ -n "$bak" ] && [ -f "$bak" ]; then
        mv -f "$bak" "$NGINX"
    fi

    if [ $ok -ne 0 ]; then
        red "❌ 证书申请失败"
        return 1
    fi

    "$ACME_HOME/acme.sh" --install-cert -d "$domain" \
        --key-file       "$SSL_DIR/${domain}.key" \
        --fullchain-file "$SSL_DIR/${domain}.fullchain.pem" \
        --reloadcmd      "systemctl reload emby-proxy 2>/dev/null || openresty -s reload 2>/dev/null || true" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        red "❌ 证书安装失败"
        return 1
    fi
    chmod 600 "$SSL_DIR/${domain}.key"
    chmod 644 "$SSL_DIR/${domain}.fullchain.pem"
    green "✅ 证书申请并安装成功"
}

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

# ==================================================
# Lua 初始化 + 伪装首页
# ==================================================
write_lua(){
    mkdir -p "$(dirname "$LUA")"

    # ---------- 白名单文件 ----------
    : > "$ALLOW_FILE"
    if [ -n "$ALLOW_DOMAIN" ]; then
        IFS="|" read -ra ARR <<< "$ALLOW_DOMAIN"
        for d in "${ARR[@]}"; do
            [ -n "$d" ] && echo "$d" >> "$ALLOW_FILE"
        done
    fi

    # ---------- 伪装首页（简约博客） ----------
    cat > "$CAMO_FILE" <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Stream Notes</title>
<style>
  :root { --fg:#222; --muted:#888; --bg:#fafafa; --accent:#3b6ea5; }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--fg);
    font: 16px/1.7 -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
  }
  .wrap { max-width: 680px; margin: 0 auto; padding: 64px 24px 96px; }
  header { margin-bottom: 48px; }
  header h1 { font-size: 26px; margin: 0 0 8px; letter-spacing: .5px; }
  header p { color: var(--muted); margin: 0; font-size: 14px; }
  article { padding: 20px 0; border-bottom: 1px solid #eaeaea; }
  article:last-child { border-bottom: none; }
  article h2 { font-size: 18px; margin: 0 0 6px; }
  article h2 a { color: var(--fg); text-decoration: none; }
  article h2 a:hover { color: var(--accent); }
  article .meta { color: var(--muted); font-size: 13px; margin-bottom: 8px; }
  article p { margin: 0; color: #555; }
  footer { margin-top: 64px; color: var(--muted); font-size: 13px; text-align: center; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>Stream Notes</h1>
    <p>记录一些关于流媒体、网络与自建服务的小事。</p>
  </header>

  <article>
    <h2><a href="#">用 OpenResty 搭建轻量反向代理</a></h2>
    <div class="meta">2026-03-12 · 网络</div>
    <p>通过 Lua 在请求阶段解析路径，把动态目标地址交给 proxy_pass，实现一个极简的通用反代。</p>
  </article>

  <article>
    <h2><a href="#">流媒体播放的缓冲与 Range 请求</a></h2>
    <div class="meta">2026-02-28 · 流媒体</div>
    <p>关闭 proxy_buffering、打开 proxy_force_ranges，可以显著改善拖动进度条时的体验。</p>
  </article>

  <article>
    <h2><a href="#">给自建服务加一层访问控制</a></h2>
    <div class="meta">2026-02-10 · 安全</div>
    <p>用 geo 模块做地区限制、用共享字典做域名白名单，成本低但足够挡住大部分滥用。</p>
  </article>

  <article>
    <h2><a href="#">关于日志轮转的一点经验</a></h2>
    <div class="meta">2026-01-22 · 运维</div>
    <p>logrotate 配合 nginx 的 USR1 信号，可以在不中断服务的前提下切分日志。</p>
  </article>

  <footer>© 2026 Stream Notes · 保持简单</footer>
</div>
</body>
</html>
HTML

    # ---------- Lua 初始化脚本 ----------
    cat > "$LUA" <<EOF
-- 从共享字典读取配置
local dict = ngx.shared.allow_domain
dict:set("filter",     "$FILTER")
dict:set("camo",       "$CAMO")
dict:set("china_only", "$CHINA_ONLY")

-- 伪装首页内容
local cf = io.open("$CAMO_FILE", "r")
if cf then
    dict:set("camo_html", cf:read("*a"))
    cf:close()
end

-- 白名单从独立文件读取，避免字符串注入
local f = io.open("$ALLOW_FILE", "r")
if f then
    local lines = {}
    for line in f:lines() do
        line = line:gsub("%s+", "")
        if line ~= "" then lines[#lines+1] = line end
    end
    f:close()
    dict:set("domains", table.concat(lines, "|"))
end
EOF
}

# ==================================================
# systemd / logrotate
# ==================================================
make_systemd(){
    cat > "$SERVICE" <<EOF
[Unit]
Description=Emby Dynamic Reverse Proxy
After=network.target

[Service]
Type=forking
PIDFile=/usr/local/openresty/nginx/logs/nginx.pid
ExecStartPre=/usr/local/openresty/nginx/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/local/openresty/nginx/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/local/openresty/nginx/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=-/sbin/start-stop-daemon --quiet --stop --retry QUIT/5 --pidfile /usr/local/openresty/nginx/logs/nginx.pid
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl disable openresty 2>/dev/null
    systemctl stop openresty 2>/dev/null
    systemctl enable emby-proxy.service >/dev/null 2>&1
}

make_logrotate(){
    cat > "$LOGROTATE" <<EOF
/usr/local/openresty/nginx/logs/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -f /usr/local/openresty/nginx/logs/nginx.pid ] && kill -USR1 \$(cat /usr/local/openresty/nginx/logs/nginx.pid) 2>/dev/null || true
    endscript
}
EOF
    green "✅ logrotate 已配置（保留 7 天）"
}

# ==================================================
# 生成反代配置
# ==================================================
gen_proxy_location(){
    cat > /tmp/rp_location.$$ <<'LOC'
    location / {
        set $upstream "";
        set $target_host "";
        set $target_scheme "";
        rewrite_by_lua_block {
            -- 统一的错误/提示渲染：按伪装开关决定返回 HTML 还是纯文本
            local function render_error(status, msg)
                local dict = ngx.shared.allow_domain
                ngx.status = status
                if dict:get("camo") == "1" then
                    local html = dict:get("camo_html")
                    if html and html ~= "" then
                        ngx.header.content_type = "text/html; charset=utf-8"
                        ngx.print(html)
                        return ngx.exit(status)
                    end
                end
                ngx.header.content_type = "text/plain; charset=utf-8"
                ngx.say(msg)
                return ngx.exit(status)
            end

            local dict = ngx.shared.allow_domain

            -- 中国 IP 限制（IPv6 在 geo 中恒为 1，放行）
            if dict:get("china_only") == "1" and ngx.var.is_cn == "0" then
                return render_error(403, "⚠️ 403 仅限中国大陆IP访问")
            end

            -- 解析请求路径：/https://target.com/path?args
            local uri = ngx.var.request_uri
            local pure_uri, args = uri:match("^([^?]*)%??(.*)$")
            local target = pure_uri:sub(2)
            if target == "" then
                return render_error(400, "❌ 400 缺少目标地址")
            end

            -- 无协议时默认补 https://
            local url = target
            if not url:match("^https?://") then
                url = "https://" .. url
            end

            -- 白名单校验
            if dict:get("filter") == "1" then
                local check_host = url:match("^https?://([^/]+)")
                if check_host then
                    check_host = check_host:lower()
                    check_host = check_host:match("^([^:]+)") or check_host
                end
                local allow = false
                for domain in string.gmatch(dict:get("domains") or "", "[^|]+") do
                    domain = domain:lower()
                    domain = domain:match("^([^:]+)") or domain
                    if check_host == domain or (#check_host > #domain and check_host:sub(-#domain - 1) == "." .. domain) then
                        allow = true
                        break
                    end
                end
                if not allow then
                    return render_error(403, "⚠️ 403 不在白名单")
                end
            end

            -- 拆解目标地址
            local scheme, host, path = url:match("^(https?://)([^/]+)(.*)")
            if not host then
                return render_error(400, "❌ 400 地址解析失败")
            end
            if path == "" then path = "/" end

            -- 重写 URI 和参数
            ngx.req.set_uri(path)
            if args and args ~= "" then
                ngx.req.set_uri_args(args)
            end

            -- 设置代理目标变量
            ngx.var.target_scheme = scheme:gsub("://", "")
            ngx.var.target_host = host
            ngx.var.upstream = scheme .. host
        }

        proxy_pass $upstream;
        proxy_set_header Host $target_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $target_scheme;

        proxy_ssl_server_name on;
        proxy_ssl_name $target_host;
        proxy_ssl_verify off;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Range $http_range;
        proxy_set_header If-Range $http_if_range;
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
    cat /tmp/rp_location.$$
    rm -f /tmp/rp_location.$$
}

make_nginx(){
    write_lua

    if [ "$CHINA_ONLY" = "1" ] && [ ! -f "$CHINA_IP_CONF" ]; then
        update_china_ip || true
    fi

    local sname="$DOMAIN"
    [ "$MODE" = "ip" ] && sname="_"

    # 中国 IP geo 块：0=境外，1=中国（含 IPv6 全放行）
    local geo_block=""
    if [ "$CHINA_ONLY" = "1" ]; then
        geo_block="
    geo \$is_cn {
        include $CHINA_IP_CONF;
        0.0.0.0/0 0;
        ::/0 1;
    }
"
    fi

    gen_proxy_location > /tmp/rp_loc.txt

    if [ "$MODE" = "domain" ] && [ "$HTTPS" = "1" ]; then
        {
            cat <<EOF
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
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 0;

    server {
        listen 80;
        listen [::]:80;
        server_name $sname;
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
        server_name $sname;
        ssl_certificate     $SSL_DIR/$DOMAIN.fullchain.pem;
        ssl_certificate_key $SSL_DIR/$DOMAIN.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
            cat /tmp/rp_loc.txt
            cat <<EOF
    }
}
EOF
        } > "$NGINX"
    else
        {
            cat <<EOF
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
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 0;

    server {
        listen 80;
        listen [::]:80;
        server_name $sname;
EOF
            cat /tmp/rp_loc.txt
            cat <<EOF
    }
}
EOF
        } > "$NGINX"
    fi
    rm -f /tmp/rp_loc.txt

    if ! openresty -t 2>/tmp/rp_test_err.txt; then
        red "❌ 配置检测失败："
        cat /tmp/rp_test_err.txt
        rm -f /tmp/rp_test_err.txt
        return 1
    fi
    rm -f /tmp/rp_test_err.txt
    svc_restart
    green "✅ 配置已加载"
    blue "ℹ️ nginx.conf 大小: $(wc -c < "$NGINX") 字节"
}

# ==================================================
# 功能菜单
# ==================================================
install(){
    header
    subheader "安装 / 初始化"

    install_pkg
    install_openresty || { pause; return; }

    echo
    echo -e "  \033[1m请选择部署模式：\033[0m"
    echo -e "    \033[32m[1]\033[0m 域名（可申请 HTTPS 证书）"
    echo -e "    \033[32m[2]\033[0m IP  （仅 HTTP，不需要证书）"
    echo
    read -p "  选择 [1/2]: " MODE_CHOICE
    case "$MODE_CHOICE" in
        2)
            MODE="ip"
            DOMAIN=""
            HTTPS="0"
            ;;
        *)
            MODE="domain"
            read -p "  绑定域名: " DOMAIN
            if [ -z "$DOMAIN" ]; then
                red "❌ 域名不能为空"
                pause
                return
            fi
            read -p "  开启 HTTPS？(y/N): " SSL_CHOICE
            [[ "$SSL_CHOICE" =~ ^[yY]$ ]] && HTTPS="1" || HTTPS="0"
            ;;
    esac

    FILTER="0"
    ALLOW_DOMAIN=""
    CHINA_ONLY="1"
    CAMO="0"
    save

    if [ "$CHINA_ONLY" = "1" ]; then
        update_china_ip || yellow "⚠️ IP 库更新失败，可稍后在菜单 [3] 重试"
    fi

    if [ "$MODE" = "domain" ] && [ "$HTTPS" = "1" ]; then
        install_acme || { red "❌ acme 安装失败，回退 HTTP"; HTTPS="0"; save; }
        if [ "$HTTPS" = "1" ]; then
            issue_cert "$DOMAIN" || { red "❌ 证书失败，回退 HTTP"; HTTPS="0"; save; }
        fi
    fi

    make_systemd
    make_nginx
    make_logrotate
    svc_restart

    echo
    green "✅ 部署成功"
    echo -e "  \033[36m──────────────────────────────────────────\033[0m"
    if [ "$MODE" = "ip" ]; then
        LOCAL_IP=$(hostname -I | awk '{print $1}')
        echo -e "  访问格式: \033[1mhttp://$LOCAL_IP/目标地址\033[0m"
    elif [ "$HTTPS" = "1" ]; then
        echo -e "  访问格式: \033[1mhttps://$DOMAIN/目标地址\033[0m"
    else
        echo -e "  访问格式: \033[1mhttp://$DOMAIN/目标地址\033[0m"
    fi
    pause
}

renew_cert(){
    header
    subheader "更新证书"

    if [ "$MODE" != "domain" ] || [ -z "$DOMAIN" ]; then
        red "❌ 当前不是域名模式，无法申请证书"
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

china_ip_menu(){
    while true; do
        header
        subheader "中国大陆 IP 限制"

        echo -n "  状态:   "
        [ "$CHINA_ONLY" = "1" ] && status_on || status_off
        [ -f "$CHINA_IP_CONF" ] && echo "  IPv4库: $(wc -l < "$CHINA_IP_CONF") 条"
        echo "  IPv6:   默认放行"
        echo
        echo -e "    \033[32m[1]\033[0m 开启限制"
        echo -e "    \033[32m[2]\033[0m 关闭限制"
        echo -e "    \033[32m[3]\033[0m 更新 IP 库"
        echo -e "    \033[32m[0]\033[0m 返回"
        echo
        read -p "  选择: " C
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

white(){
    while true; do
        header
        subheader "域名白名单"

        echo -n "  状态:   "
        [ "$FILTER" = "1" ] && status_on || status_off
        echo "  列表:   ${ALLOW_DOMAIN:-无}"
        echo
        echo -e "    \033[32m[1]\033[0m 开启限制"
        echo -e "    \033[32m[2]\033[0m 关闭限制"
        echo -e "    \033[32m[3]\033[0m 添加域名"
        echo -e "    \033[32m[4]\033[0m 删除域名"
        echo -e "    \033[32m[5]\033[0m 清空域名"
        echo -e "    \033[32m[0]\033[0m 返回"
        echo
        read -p "  选择: " W
        case $W in
            1) FILTER="1" ;;
            2) FILTER="0" ;;
            3)
                read -p "  域名: " ADD
                [ -n "$ADD" ] && {
                    [ -z "$ALLOW_DOMAIN" ] && ALLOW_DOMAIN="$ADD" || ALLOW_DOMAIN="$ALLOW_DOMAIN|$ADD"
                }
                ;;
            4)
                read -p "  删除: " DEL
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

# 首页伪装管理
camo_menu(){
    while true; do
        header
        subheader "首页伪装"

        echo -n "  状态:   "
        [ "$CAMO" = "1" ] && status_on || status_off
        echo "  说明:   开启后，所有错误/根路径访问均返回简约博客首页"
        echo "          关闭后，恢复纯文本提示"
        echo
        echo -e "    \033[32m[1]\033[0m 开启伪装"
        echo -e "    \033[32m[2]\033[0m 关闭伪装"
        echo -e "    \033[32m[3]\033[0m 预览伪装页"
        echo -e "    \033[32m[0]\033[0m 返回"
        echo
        read -p "  选择: " C
        case $C in
            1) CAMO="1"; save; make_nginx ;;
            2) CAMO="0"; save; make_nginx ;;
            3)
                if [ -f "$CAMO_FILE" ]; then
                    echo
                    blue "ℹ️ 伪装页已生成于: $CAMO_FILE"
                    echo "  大小: $(wc -c < "$CAMO_FILE") 字节"
                else
                    yellow "⚠️ 尚未生成，请先开启一次伪装"
                fi
                pause
                ;;
            0) return ;;
            *) red "❌ 输入错误" ;;
        esac
    done
}

show(){
    header
    subheader "当前配置"

    echo -e "  模式:     $([ "$MODE" = "ip" ] && echo "IP" || echo "域名")"
    if [ "$MODE" = "domain" ]; then
        echo -e "  域名:     $DOMAIN"
        echo -n "  HTTPS:    "; [ "$HTTPS" = "1" ] && status_on || status_off
    else
        LOCAL_IP=$(hostname -I | awk '{print $1}')
        echo -e "  本机IP:   $LOCAL_IP"
    fi
    echo -n "  中国IP:   "; [ "$CHINA_ONLY" = "1" ] && green "已开启（IPv6 放行）" || status_off
    echo -n "  首页伪装: "; [ "$CAMO" = "1" ] && status_on || status_off
    echo -n "  白名单:   "; [ "$FILTER" = "1" ] && status_on || status_off
    echo -e "  白名单列表: ${ALLOW_DOMAIN:-无}"

    if [ "$MODE" = "domain" ] && [ "$HTTPS" = "1" ] && [ -f "$SSL_DIR/$DOMAIN.fullchain.pem" ]; then
        echo -n "  证书到期: "
        openssl x509 -in "$SSL_DIR/$DOMAIN.fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "未知"
    fi
    echo -e "  nginx.conf: $(wc -c < "$NGINX" 2>/dev/null || echo 0) 字节"
    echo -e "  日志保留:   7 天"
    pause
}

reload(){
    header
    subheader "重载服务"

    if openresty -t >/dev/null 2>&1; then
        svc_reload
        green "✅ 重载成功"
    else
        red "❌ 配置错误"
        openresty -t
    fi
    pause
}

remove(){
    header
    subheader "卸载"

    yellow "将卸载 OpenResty、证书、配置、IP 库、logrotate、伪装页"
    echo
    read -p "  确认卸载？(y/N): " OK
    if [[ "$OK" =~ ^[yY]$ ]]; then
        svc_stop
        systemctl disable emby-proxy 2>/dev/null || true
        apt remove --purge -y openresty* >/dev/null 2>&1
        apt autoremove -y >/dev/null 2>&1
        rm -rf "$CONF" "$SERVICE" "$SSL_DIR" \
               "$ACME_HOME" "$ACME_WEBROOT" "$CHINA_IP_CONF" \
               "$ALLOW_FILE" "$LOGROTATE" "$CAMO_FILE" \
               /etc/apt/sources.list.d/openresty.list \
               /usr/share/keyrings/openresty.gpg
        crontab -l 2>/dev/null | grep -v 'acme.sh' | crontab - 2>/dev/null || true
        systemctl daemon-reload
        green "✅ 已卸载"
    else
        yellow "已取消"
    fi
    pause
}

# ==================================================
# 主菜单
# ==================================================
menu(){
    while true; do
        header
        echo -e "  \033[1m请选择操作：\033[0m"
        echo
        echo -e "    \033[32m[1]\033[0m  安装 / 初始化"
        echo -e "    \033[32m[2]\033[0m  域名白名单"
        echo -e "    \033[32m[3]\033[0m  中国IP限制"
        echo -e "    \033[32m[4]\033[0m  首页伪装"
        echo -e "    \033[32m[5]\033[0m  查看配置"
        echo -e "    \033[32m[6]\033[0m  重载服务"
        echo -e "    \033[32m[7]\033[0m  更新证书"
        echo -e "    \033[32m[8]\033[0m  卸载"
        echo -e "    \033[32m[0]\033[0m  退出"
        echo
        read -p "  选择: " M
        case $M in
            1) install ;;
            2) white ;;
            3) china_ip_menu ;;
            4) camo_menu ;;
            5) show ;;
            6) reload ;;
            7) renew_cert ;;
            8) remove ;;
            0) clear; exit 0 ;;
            *) red "❌ 输入错误" ;;
        esac
    done
}

# ==================================================
# 入口
# ==================================================
if [ "$(id -u)" != "0" ]; then
    red "❌ 请使用 root 运行"
    exit 1
fi
init
menu
