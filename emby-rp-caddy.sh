#!/bin/bash
# ============================================================
# Emby Dynamic Proxy Manager v2.1.0
#
# 功能:
#  - 动态Emby反向代理
#  - IPv4 / IPv6
#  - WebSocket
#  - Range断点续传
#  - 大文件流式转发
#  - 白名单控制(为空不限)
#  - Caddy入口
#  - 自动安装
#  - 自动升级
#  - 版本管理
#
# ============================================================

APP_DIR="/opt/emby-proxy"
SERVICE="/etc/systemd/system/emby-proxy.service"
CADDY="/etc/caddy/Caddyfile"

ALLOW="$APP_DIR/allow.list"
VERSION_FILE="$APP_DIR/version"

BACKUP_DIR="/opt/emby-proxy-backup"

PORT=8787

VERSION="2.1.0"


# ============================
# Root检查
# ============================

check_root(){
    [ "$(id -u)" = "0" ] || {
        echo "请使用root运行"
        exit 1
    }
}


# ============================
# 安装Node20
# ============================

install_node(){

if command -v node >/dev/null;then
    echo "Node已安装 $(node -v)"
    return
fi

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -

apt update

apt install -y nodejs

}



# ============================
# 安装Caddy
# ============================

install_caddy(){

if command -v caddy >/dev/null;then
    echo "Caddy已安装"
    return
fi


apt update


apt install -y \
curl \
gnupg \
debian-keyring \
debian-archive-keyring \
apt-transport-https


curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
| gpg --dearmor \
-o /usr/share/keyrings/caddy.gpg


curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
> /etc/apt/sources.list.d/caddy.list


apt update

apt install -y caddy

}



# ============================
# 初始化目录
# ============================

init_dir(){

mkdir -p "$APP_DIR"

mkdir -p "$BACKUP_DIR"


if [ ! -f "$ALLOW" ];then

cat >"$ALLOW"<<EOF
# Emby白名单
# 留空表示允许所有域名
# 示例:
# emby.example.com

EOF

fi


}



# ============================
# 获取版本
# ============================

get_version(){

if [ -f "$VERSION_FILE" ];then
    cat "$VERSION_FILE"
else
    echo "未安装"
fi

}



# ============================
# 写入版本
# ============================

write_version(){

echo "$VERSION" > "$VERSION_FILE"

}



# ============================
# 创建Node核心
# ============================

create_node(){

cat >"$APP_DIR/server.js"<<'NODE'
const http=require("http");
const https=require("https");
const fs=require("fs");

const PORT=8787;
const ALLOW="/opt/emby-proxy/allow.list";

let allowCache=[];
let allowCacheTime=0;


// ============================
// 白名单缓存
// 5分钟刷新一次
// 空白名单=不限
// ============================

function getAllow(){

let now=Date.now();

if(now-allowCacheTime<300000){
return allowCache;
}

try{

allowCache=fs.readFileSync(ALLOW,"utf8")
.split("\n")
.map(x=>x.trim())
.filter(x=>x&&!x.startsWith("#"))
.map(x=>
x.replace(/^https?:\/\//,"")
.replace(/\/.*$/,"")
.toLowerCase()
);

allowCacheTime=now;

}catch(e){

allowCache=[];

}

return allowCache;

}



// ============================
// 域名检测
// ============================

function domainAllowed(host){

host=(host||"").toLowerCase();


let list=getAllow();


// 白名单为空，不限制

if(!list.length){

return true;

}


return list.some(d=>
host===d ||
host.endsWith("."+d)
);


}



// ============================
// 解析目标地址
// ============================

function parseTarget(req){

let u;

try{

u=new URL(
req.url,
"http://localhost"
);

}catch(e){

return null;

}


let raw=u.pathname.substring(1);


if(
!raw.startsWith("http://") &&
!raw.startsWith("https://")
){

return null;

}


let target;

try{

target=new URL(raw);

}catch(e){

return null;

}



if(!domainAllowed(target.hostname)){

return {
deny:true,
host:target.hostname
};

}



target.pathname=
u.pathname.replace(
/^\/https?:\/\/[^\/]+/,
""
)||"/";


target.search=u.search;


return target;

}




// ============================
// 请求头优化
// ============================

function headers(req,target){

let h={...req.headers};


// Emby必须

h.host=target.host;


// 转发真实IP

h["x-real-ip"]=
req.socket.remoteAddress||"";


h["x-forwarded-for"]=
req.socket.remoteAddress||"";


h["x-forwarded-proto"]=
target.protocol.replace(":","");


// 保留客户端信息

if(req.headers.origin){

h.origin=req.headers.origin;

}


if(req.headers.referer){

h.referer=req.headers.referer;

}


// 删除hop头

delete h.connection;

delete h["proxy-connection"];


return h;

}



// ============================
// HTTP代理
// ============================

function proxy(req,res,target){

let client=
target.protocol==="https:"
?
https
:
http;


let r=client.request({

protocol:target.protocol,

hostname:target.hostname,

port:
target.port||
(target.protocol==="https:"?443:80),


method:req.method,


path:
target.pathname+
target.search,


headers:headers(req,target),


rejectUnauthorized:false,


timeout:0


},proxyRes=>{


res.writeHead(
proxyRes.statusCode,
proxyRes.headers
);


proxyRes.pipe(res);


});



r.on("error",e=>{


if(!res.headersSent){

res.writeHead(502);

}

res.end(
"Proxy Error\n"+
e.message
);


});


req.pipe(r);

}



// ============================
// WebSocket代理
// ============================

function proxyWS(req,socket,target){


let client=
target.protocol==="https:"
?
https
:
http;



let r=client.request({

protocol:target.protocol,

hostname:target.hostname,

port:
target.port||
(target.protocol==="https:"?443:80),


method:req.method,


path:
target.pathname+
target.search,


headers:headers(req,target),


rejectUnauthorized:false


});



r.on("upgrade",
(proxyRes,proxySocket,head)=>{


let raw=
`HTTP/1.1 101 Switching Protocols\r\n`;


for(let k in proxyRes.headers){

raw+=
k+": "+
proxyRes.headers[k]+"\r\n";

}


raw+="\r\n";


socket.write(raw);



if(head&&head.length){

socket.write(head);

}


proxySocket.pipe(socket);

socket.pipe(proxySocket);


});



r.on("error",()=>{

socket.destroy();

});


r.end();


}




// ============================
// HTTP入口
// ============================

const server=http.createServer(
(req,res)=>{


let target=parseTarget(req);



if(!target){

res.writeHead(200,{
"Content-Type":
"text/plain;charset=utf-8"
});


res.end(
`Emby Dynamic Proxy v2.1.0

使用:

http://服务器/https://emby.example.com

`
);

return;

}



if(target.deny){

res.writeHead(403);

res.end(
"Domain not allowed\n"+
target.host
);

return;

}



proxy(req,res,target);


});





// WebSocket升级

server.on("upgrade",
(req,socket)=>{


let target=parseTarget(req);



if(!target||target.deny){

socket.destroy();

return;

}



proxyWS(req,socket,target);


});




// 超时优化

server.keepAliveTimeout=0;

server.headersTimeout=0;

server.requestTimeout=0;



server.listen(
PORT,
"::",
()=>{

console.log(
"Emby Proxy running:"+PORT
);

});
NODE

}



# ============================
# 创建systemd
# ============================

create_service(){

cat >"$SERVICE"<<EOF
[Unit]
Description=Emby Dynamic Proxy v$VERSION
After=network.target


[Service]
Type=simple
ExecStart=/usr/bin/node $APP_DIR/server.js
Restart=always
RestartSec=3
LimitNOFILE=65535


[Install]
WantedBy=multi-user.target
EOF


systemctl daemon-reload

systemctl enable emby-proxy

}



# ============================
# 创建Caddy配置
# ============================

create_caddy(){

mkdir -p /etc/caddy


cat >"$CADDY"<<EOF
:80 {

reverse_proxy 127.0.0.1:$PORT {

flush_interval -1

transport http {

dial_timeout 10s

keepalive 60s

read_buffer 8192

write_buffer 8192

}

}

}
EOF


caddy fmt --overwrite "$CADDY"


caddy validate --config "$CADDY" || {

echo "Caddy配置错误"

return 1

}


systemctl restart caddy

}



# ============================
# 备份旧版本
# ============================

backup_old(){

[ -d "$APP_DIR" ] || return


tar czf \
"$BACKUP_DIR/emby-proxy-$(date +%Y%m%d-%H%M%S).tar.gz" \
"$APP_DIR" \
2>/dev/null


echo "旧版本已备份"

}

# ============================
# 安装 / 升级
# ============================

install(){

echo
echo "================================"
echo " Emby Dynamic Proxy Manager v$VERSION"
echo "================================"
echo


init_dir


if [ -f "$VERSION_FILE" ];then


OLD=$(get_version)


echo "检测到已有安装"

echo "当前版本: $OLD"

echo "升级版本: $VERSION"


backup_old


else


echo "首次安装"


fi



install_node

install_caddy



# 保存白名单

if [ -f "$ALLOW" ];then

cp "$ALLOW" /tmp/emby_allow_backup

fi



create_node


create_service


create_caddy



# 恢复白名单

if [ -f /tmp/emby_allow_backup ];then

cp /tmp/emby_allow_backup "$ALLOW"

fi



write_version



systemctl restart emby-proxy



echo

echo "================================"

echo "完成"

echo "当前版本: $(get_version)"

echo "================================"


}


# ============================
# 白名单添加
# ============================

add_domain(){

init_dir


read -p "输入域名: " d


[ -z "$d" ] && return


# 清理格式

d=$(echo "$d" | sed \
's#https\?://##;s#/.*##')


if grep -qx "$d" "$ALLOW";then

echo "已经存在"

return

fi


echo "$d" >> "$ALLOW"


echo "添加成功: $d"


}



# ============================
# 删除白名单
# ============================

del_domain(){

echo

echo "当前白名单:"

grep -v "^#" "$ALLOW"


echo

read -p "输入删除域名: " d


sed -i "/^$d$/d" "$ALLOW"


echo "删除完成"


}



# ============================
# 查看白名单
# ============================

show_domain(){

echo

echo "========== 白名单 =========="

if grep -v "^#" "$ALLOW" | grep -q .;then

grep -v "^#" "$ALLOW"

else

echo "空"

echo "当前为不限域名模式"

fi

}



# ============================
# 重启
# ============================

restart(){

systemctl restart emby-proxy

systemctl restart caddy


echo "重启完成"

}



# ============================
# 查看状态
# ============================

status(){

echo

echo "====== Emby Proxy ======"

systemctl status emby-proxy --no-pager


echo

echo "====== Caddy ======"

systemctl status caddy --no-pager

}



# ============================
# 查看日志
# ============================

logs(){

journalctl \
-u emby-proxy \
-n 100 \
--no-pager

}



# ============================
# 查看版本
# ============================

version_info(){

echo

echo "============================"

echo "Emby Dynamic Proxy"

echo

echo "管理版本:"
echo "$VERSION"

echo

echo "安装版本:"
get_version


echo

echo "Node:"
node -v 2>/dev/null


echo

echo "Caddy:"

caddy version 2>/dev/null


echo "============================"

}



# ============================
# 卸载
# ============================

uninstall(){

echo "开始卸载"


systemctl stop emby-proxy 2>/dev/null

systemctl disable emby-proxy 2>/dev/null


rm -f "$SERVICE"


rm -rf "$APP_DIR"


systemctl daemon-reload


echo "卸载完成"

}



# ============================
# 菜单
# ============================

menu(){

while true
do

clear


echo "================================="
echo " Emby Dynamic Proxy Manager v$VERSION"
echo " 当前安装: $(get_version)"
echo "================================="

echo

echo "1. 安装 / 升级"

echo "2. 添加白名单"

echo "3. 删除白名单"

echo "4. 查看白名单"

echo "5. 重启服务"

echo "6. 查看状态"

echo "7. 查看日志"

echo "8. 卸载"

echo "9. 查看版本"

echo "0. 退出"


echo


read -p "选择: " n


case $n in

1)
install
;;

2)
add_domain
;;

3)
del_domain
;;

4)
show_domain
;;

5)
restart
;;

6)
status
;;

7)
logs
;;

8)
uninstall
;;

9)
version_info
;;

0)
exit
;;

*)
echo "错误"

;;

esac


echo

read -p "回车继续..."

done


}



# ============================
# 启动
# ============================

check_root

menu
