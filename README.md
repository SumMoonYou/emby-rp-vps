# Emby Dynamic Proxy Manager

一个轻量、高性能的 Emby 动态反向代理管理工具。

基于 **Node.js + Caddy** 架构，实现动态目标代理、HTTPS 自动证书、WebSocket、Range 流媒体播放支持。

适用于：

- Emby
- Jellyfin
- Plex（部分场景）
- 其他支持 HTTP/WebSocket 的媒体服务


## ✨ 特性

### 🚀 高性能代理

- Node.js 原生 HTTP/HTTPS 代理
- KeepAlive 连接复用
- TCP 连接池优化
- 大文件流式传输
- Range 断点续播支持
- 视频拖动不卡顿


### 🔐 HTTPS 自动证书

使用 Caddy 自动管理 SSL：

- Let's Encrypt 自动申请证书
- 自动续期
- HTTP 自动跳转 HTTPS
- 支持 HTTP/2


### 🎬 Emby 完整支持

支持：

- Web 页面
- Emby APP
- WebSocket
- 视频播放
- 快进/拖动
- 字幕加载
- 海报图片
- 媒体信息


### 🛡 域名白名单

支持代理目标限制。

### ⚙️ 安装

caddy版本
```
bash -c "$(curl -L https://raw.githubusercontent.com/SumMoonYou/emby-rp-vps/refs/heads/main/emby-rp-caddy.sh)" @ install
```

OpenResty
```
bash -c "$(curl -L https://raw.githubusercontent.com/SumMoonYou/emby-rp-vps/refs/heads/main/emby-rp-openresty.sh)" @ install
```

