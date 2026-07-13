#!/bin/bash
# ============================================================
# Emby Dynamic Proxy Manager v2.1.0
#
# 基于稳定版升级
#
# 功能:
#  - 动态Emby反代
#  - IPv4 / IPv6访问
#  - WebSocket
#  - Range断点续传
#  - 大文件流式代理
#  - 域名白名单
#  - 白名单为空=不限
#  - 自动安装
#  - 自动升级
#  - 自动备份
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
# root检查
# ============================

check_root(){

[ "$(id -u)" = "0" ] || {
echo "请使用root运行"
exit 1
}

}



# ============================
# 安装Node
# ============================

install_node(){

command -v node >/dev/null && {

echo "Node已安装: $(node -v)"

return

}


curl -fsSL https://deb.nodesource.com/setup_20.x | bash -

apt update

apt install -y nodejs

}



# ============================
# 安装Caddy
# ============================

install_caddy(){

command -v caddy >/dev/null && {

echo "Caddy已安装"

return

}


apt update


apt install -y \
curl \
gnupg \
debian-keyring \
debian-archive-keyring \
apt-transport-https



curl -1sLf \
https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
| gpg --dearmor \
-o /usr/share/keyrings/caddy.gpg



curl -1sLf \
https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
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
# 留空表示不限域名
#
# 示例:
# emby.example.com

EOF


fi


}



# ============================
# 读取版本
# ============================

get_version(){

[ -f "$VERSION_FILE" ] \
&& cat "$VERSION_FILE" \
|| echo "未安装"

}



# ============================
# 写入版本
# ============================

write_version(){

echo "$VERSION" > "$VERSION_FILE"

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


echo "旧版本备份完成"


}



# ============================
# 生成server.js
# 后续部分补充
# ============================

# ============================
# 生成Node代理核心
# 基于原稳定版
# ============================

create_node(){

cat >"$APP_DIR/server.js"<<'NODE'

const http=require("http");
const https=require("https");
const fs=require("fs");

const PORT=8787;
const ALLOW="/opt/emby-proxy/allow.list";


// ============================
// 白名单缓存
// 5分钟刷新一次
// 空白名单=不限
// ============================

let allowCache=[];
let allowTime=0;


function allowList(){

let now=Date.now();


if(now-allowTime<300000){

return allowCache;

}


try{


allowCache=fs.readFileSync(ALLOW,"utf8")
.split("\n")
.map(v=>v.trim())
.filter(v=>v&&!v.startsWith("#"))
.map(v=>
v.replace(/^https?:\/\//,"")
.replace(/\/.*$/,"")
.toLowerCase()
);



allowTime=now;


}catch(e){


allowCache=[];


}


return allowCache;


}




// ============================
// 域名白名单
// 空=全部允许
// ============================

function domainAllowed(host){


let list=allowList();


host=(host||"").toLowerCase();



if(!list.length){

return true;

}



return list.some(d=>{


return host===d ||
host.endsWith("."+d);


});


}




// ============================
// 解析代理目标
// ============================

function parseTarget(req){


let u=new URL(
req.url,
"http://localhost"
);



let raw=u.pathname.substring(1);



if(
!raw.startsWith("http://") &&
!raw.startsWith("https://")
){

return null;

}




let target=new URL(raw);



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
// HTTP代理
// ============================

function proxy(req,res,target){


let client=
target.protocol==="https:"
?
https
:
http;



let headers={
...req.headers
};



headers.host=target.host;



headers["x-forwarded-for"]=
req.socket.remoteAddress||"";


headers["x-real-ip"]=
req.socket.remoteAddress||"";


headers["x-forwarded-proto"]=
target.protocol.replace(":","");



let p=client.request({


protocol:target.protocol,


hostname:target.hostname,


port:
target.port||
(target.protocol==="https:"?443:80),


method:req.method,


path:
target.pathname+
target.search,


headers,


rejectUnauthorized:false,


timeout:0



},r=>{


res.writeHead(
r.statusCode,
r.headers
);



r.pipe(res);



});



p.on("error",e=>{


if(!res.headersSent){

res.writeHead(502);

}


res.end(
"Proxy Error:\n"+
e.message
);


});


req.pipe(p);


}




// ============================
// WebSocket代理
// 保持原稳定逻辑
// ============================

function proxyWS(req,socket,target){


let client=
target.protocol==="https:"
?
https
:
http;



let p=client.request({


protocol:target.protocol,


hostname:target.hostname,


port:
target.port||
(target.protocol==="https:"?443:80),


method:req.method,


path:
target.pathname+
target.search,


headers:req.headers,


rejectUnauthorized:false



});




p.on("upgrade",(ps)=>{



socket.write(
"HTTP/1.1 101 Switching Protocols\r\n\r\n"
);



ps.pipe(socket);

socket.pipe(ps);



});



p.on("error",()=>{


socket.destroy();


});



p.end();



}





// ============================
// HTTP入口
// ============================

const server=http.createServer((req,res)=>{


let target=parseTarget(req);



if(!target){


res.writeHead(200,{

"Content-Type":
"text/plain;charset=utf-8"

});


res.end(
`Emby Dynamic Proxy v2.1.0

使用:

http://服务器/https://Emby地址

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






// ============================
// WebSocket升级
// ============================

server.on("upgrade",(req,socket)=>{


let target=parseTarget(req);



if(!target||target.deny){


socket.destroy();

return;

}



proxyWS(req,socket,target);


});






// ============================
// 保持原稳定监听方式
// ============================

server.timeout=0;

server.keepAliveTimeout=0;

server.headersTimeout=0;



server.listen(
PORT,
"0.0.0.0",
()=>{

console.log(
"Emby proxy running:"+PORT
);

});

NODE

}



# ============================
# systemd服务
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
# Caddy配置
# ============================

create_caddy(){


mkdir -p /etc/caddy


cat >"$CADDY"<<EOF
:80 {

 reverse_proxy 127.0.0.1:$PORT {

  flush_interval -1

  transport http {

   dial_timeout 10s

   read_buffer 4096

   write_buffer 4096

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
# 安装 / 升级
# ============================

install(){


echo
echo "================================"
echo " Emby Dynamic Proxy v$VERSION"
echo "================================"
echo



init_dir



if [ -f "$VERSION_FILE" ];then


echo "检测到已安装"

echo "当前版本: $(get_version)"

echo "升级版本: $VERSION"


backup_old


else


echo "首次安装"


fi



install_node

install_caddy



create_node

create_service

create_caddy



write_version



systemctl restart emby-proxy



echo

echo "完成"

echo "当前版本: $(get_version)"


}
# ============================
# 添加白名单
# ============================

add_domain(){

init_dir


read -p "输入域名: " d


[ -z "$d" ] && return


# 清理协议和路径

d=$(echo "$d" | sed \
's#https\?://##;s#/.*##')



if grep -qx "$d" "$ALLOW";then

echo "已存在"

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


read -p "删除域名: " d


[ -z "$d" ] && return


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

echo "当前模式: 不限制域名"


fi


}



# ============================
# 重启服务
# ============================

restart(){


systemctl restart emby-proxy

systemctl restart caddy


echo "重启完成"


}



# ============================
# 状态
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
# 日志
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

echo "=============================="

echo "Emby Dynamic Proxy Manager"

echo

echo "脚本版本: $VERSION"

echo "安装版本: $(get_version)"

echo

echo "Node:"

node -v 2>/dev/null


echo

echo "Caddy:"

caddy version 2>/dev/null


echo "=============================="


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
echo " 当前安装版本: $(get_version)"
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
