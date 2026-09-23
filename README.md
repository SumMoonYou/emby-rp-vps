# Emby 动态反代管理脚本

一个基于 OpenResty（Nginx + Lua）的动态反向代理管理脚本，通过 URL 路径直接指定目标地址，支持 HTTPS、中国大陆 IP 限制、域名白名单、日志轮转等功能。

## 特性

- **动态反向代理**：访问 `https://your.domain/https://target.com/path`，Nginx 自动解析目标地址并代理
- **部署模式二选一**
  - 域名模式：可申请 Let's Encrypt 证书，启用 HTTPS
  - IP 模式：仅监听 80 端口，不需要域名和证书
- **中国大陆 IP 访问限制**
  - IPv4 基于 `china_ip_list` 判断，非中国 IP 返回 403
  - IPv6 默认全部放行
- **域名白名单过滤**：只允许反代指定目标域名，防止被滥用为开放代理
- **自动配置 OpenResty 软件源**
  - 按系统代号从新到旧尝试，直到找到可用源
  - 官方 GPG 签名失败时自动回退 `trusted=yes`
- **日志自动轮转**：保留 7 天，自动压缩旧日志

## 系统要求

- Debian / Ubuntu
- 必须以 root 运行
- 建议 1 核 1G 以上

## 快速开始

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/SumMoonYou/emby-rp-vps/refs/heads/main/emby-rp-openresty-new.sh)" @ install

```

进入菜单后选择 `[1] 安装 / 初始化`，按提示操作。

## 访问格式

```
http(s)://你的域名或IP/目标地址
```

示例：

```
https://emby.example.com/https://cdn.example.org
https://emby.example.com/cdn.example.org          # 不带协议时默认补 https://
http://1.2.3.4/https://cdn.example.org            # IP 模式
```

## 菜单说明

| 选项 | 功能 |
|------|------|
| `[1]` | 安装 / 初始化，选择域名或 IP 模式 |
| `[2]` | 域名白名单管理：开关、增删、清空 |
| `[3]` | 中国大陆 IP 限制：开关、更新 IP 库 |
| `[4]` | 查看当前配置 |
| `[5]` | 重载服务（不中断连接） |
| `[6]` | 更新证书 |
| `[7]` | 卸载 |
| `[0]` | 退出 |

## 配置文件

| 路径 | 说明 |
|------|------|
| `/etc/emby-rp.conf` | 主配置：模式、域名、开关 |
| `/usr/local/openresty/nginx/conf/nginx.conf` | OpenResty 主配置 |
| `/usr/local/openresty/nginx/conf/lua_init.lua` | Lua 初始化，加载白名单到共享字典 |
| `/usr/local/openresty/nginx/conf/allow_domains.txt` | 白名单文件，每行一个域名 |
| `/usr/local/openresty/nginx/conf/china_ip.conf` | 中国 IPv4 段（geo 格式） |
| `/etc/systemd/system/emby-proxy.service` | systemd 服务 |
| `/etc/logrotate.d/emby-proxy` | 日志轮转配置 |

## 常见问题

### 访问显示 404 或 Nginx 欢迎页

检查 `nginx.conf` 是否被正确写入：

```bash
wc -c /usr/local/openresty/nginx/conf/nginx.conf
```

正常应该几千字节。如果只有 243 字节左右，是 OpenResty 默认配置，说明脚本没写成功。

检查服务是否冲突：

```bash
ps aux | grep -E 'nginx|openresty' | grep -v grep
```

应该只有一组 master + worker。如果有多组，先停掉系统自带的 openresty：

```bash
systemctl stop openresty
systemctl disable openresty
systemctl restart emby-proxy
```  

### 安装 OpenResty 失败

脚本会自动尝试多个系统代号。如果都失败，手动指定：

```bash
rm -f /etc/apt/sources.list.d/openresty.list
echo "deb [trusted=yes] http://openresty.org/package/debian bookworm openresty" > /etc/apt/sources.list.d/openresty.list
apt update
apt install -y openresty
```

### 证书申请失败

确认：

- 域名已解析到本机
- 80 端口对外开放
- 没有其他服务占用 80

失败后可重试菜单 `[6] 更新证书`。

### 中国大陆 IP 限制误伤

如果你在境外访问被 403，这是预期行为。测试时可先关闭：

菜单 `[3]` → `[2] 关闭限制`，测完再开。

### IPv6 用户不受限制

IPv6 默认全部放行，因为 `china_ip_list` 只含 IPv4。如需限制 IPv6，需要额外维护 IPv6 地址段。

## 卸载

菜单 `[7]` 一键卸载，会清理：

- OpenResty 软件包
- 配置文件、证书、IP 库
- systemd 服务
- logrotate 配置
- acme.sh 及其 cron

## 版本历史

| 版本 | 说明 |
|------|------|


## 性能说明

当前版本使用 `proxy_pass $upstream`，**没有启用 upstream keepalive**。原因是动态 http/https 上游与 keepalive 在 Nginx 中无法兼得：

- 要 keepalive 必须用 `upstream` + `balancer_by_lua_block`
- 但 `proxy_pass` 指向 upstream 时，URI 处理逻辑与变量 `proxy_pass` 不同，容易出问题
- 且 `proxy_pass` scheme 是静态的，无法运行时切换 http/https

对个人 Emby 反代场景，性能瓶颈通常在源站带宽和磁盘 IO，当前配置足够。

如需极致性能，可考虑只支持 HTTPS 目标的 keepalive 版本，但会牺牲 http 目标兼容性。

## 安全提醒

- **中国大陆 IP 限制**依赖 `china_ip_list`，只覆盖 IPv4。IPv6 全部放行。
- **白名单**建议开启，防止脚本被当作开放代理滥用。
- **`trusted=yes`** 会跳过 APT 签名验证，仅在官方源签名失败时使用。生产环境请关注 OpenResty 官方何时更新签名算法。
- **证书私钥**权限为 `600`，仅 root 可读。

## 许可

MIT
