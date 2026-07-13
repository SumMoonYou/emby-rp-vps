#!/bin/bash
# ============================================================
# Emby Dynamic Proxy Manager v1.0
# 动态Emby反代
# 支持: IPv4 IPv6 WebSocket Range 根域名白名单
# ============================================================

APP_DIR="/opt/emby-proxy"
SERVICE="/etc/systemd/system/emby-proxy.service"
CADDY="/etc/caddy/Caddyfile"
ALLOW="$APP_DIR/allow.list"
PORT=8787


check_root(){
[ "$(id -u)" = "0" ] || {
echo "请使用root运行"
exit 1
}
}


install_node(){

command -v node >/dev/null && {
echo "Node 已安装"
return
}

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -

apt update

apt install -y nodejs

}



install_caddy(){

command -v caddy >/dev/null && {
echo "Caddy 已安装"
return
}


apt update

apt install -y curl gnupg debian-keyring debian-archive-keyring apt-transport-https


curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
| gpg --dearmor \
-o /usr/share/keyrings/caddy.gpg


curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
> /etc/apt/sources.list.d/caddy.list


apt update

apt install -y caddy

}



init_dir(){

mkdir -p "$APP_DIR"


[ -f "$ALLOW" ] || cat >"$ALLOW"<<EOF
# Emby白名单
# 示例:
# emby.example.com

EOF

}




create_node(){


cat >"$APP_DIR/server.js"<<'NODE'

const http=require("http");
const https=require("https");
const fs=require("fs");

const PORT=8787;
const ALLOW="/opt/emby-proxy/allow.list";



function allowList(){

try{

return fs.readFileSync(ALLOW,"utf8")
.split("\n")
.map(v=>v.trim())
.filter(v=>v&&!v.startsWith("#"));

}catch(e){

return [];

}

}




// 根域名匹配

function domainAllowed(host){

let list=allowList();

if(!list.length)return false;


host=host.toLowerCase();


return list.some(d=>{

d=d.replace(/^https?:\/\//,"")
.replace(/\/.*$/,"")
.trim()
.toLowerCase();


return host===d || host.endsWith("."+d);

});


}





function parseTarget(req){

let u=new URL(
req.url,
"http://localhost"
);


let raw=u.pathname.substring(1);


if(
!raw.startsWith("http://")
&&
!raw.startsWith("https://")
)

return null;



let target=new URL(raw);



if(!domainAllowed(target.hostname))

return {
deny:true,
host:target.hostname
};



target.pathname=
u.pathname.replace(
/^\/https?:\/\/[^\/]+/,
""
)||"/";


target.search=u.search;


return target;

}




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

rejectUnauthorized:false


},r=>{


res.writeHead(
r.statusCode,
r.headers
);


r.pipe(res);


});



p.on("error",e=>{

res.writeHead(502);

res.end(
"Proxy Error:\n"+
e.message
);

});


req.pipe(p);


}




const server=http.createServer((req,res)=>{


let target=parseTarget(req);



if(!target){


res.writeHead(200,{
"Content-Type":
"text/plain;charset=utf-8"
});


res.end(
`Emby Dynamic Proxy v1.0

代理运行正常


使用方式:

http://${req.headers.host}/https://Emby地址


示例:

http://${req.headers.host}/https://emby.example.com


`
);


return;

}



if(target.deny){


res.writeHead(403);


res.end(
"403 Domain not allowed\n"+
target.host
);


return;

}



proxy(req,res,target);


});
server.on("upgrade",(req,socket)=>{


let target=parseTarget(req);


if(!target||target.deny){

socket.destroy();

return;

}



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


p.end();


});



server.timeout=0;

server.keepAliveTimeout=0;

server.headersTimeout=0;


server.listen(PORT,"0.0.0.0",()=>{

console.log(
"Emby proxy running:"+PORT
);

});

NODE

}



create_service(){


cat >"$SERVICE"<<EOF
[Unit]
Description=Emby Dynamic Proxy v1.0
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

systemctl restart emby-proxy

}




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




clean_old(){


systemctl stop emby-proxy 2>/dev/null

systemctl disable emby-proxy 2>/dev/null


rm -f "$SERVICE"

rm -rf "$APP_DIR"


systemctl daemon-reload

}




install(){


echo "开始安装 Emby Dynamic Proxy v5.5"



[ -f "$SERVICE" ] && clean_old


install_node

install_caddy

init_dir

create_node

create_service



if create_caddy
then

echo
echo "安装完成"
echo

echo "白名单:"
echo "$ALLOW"

else

echo "安装失败"

clean_old

fi


}




uninstall(){


echo "卸载中..."


systemctl stop emby-proxy 2>/dev/null

systemctl disable emby-proxy 2>/dev/null


rm -f "$SERVICE"

rm -rf "$APP_DIR"


systemctl daemon-reload


rm -f "$CADDY"

touch "$CADDY"


systemctl restart caddy


echo "卸载完成"

}




add_domain(){


init_dir


read -p "输入根域名: " d


[ -z "$d" ] && return


d=$(echo "$d" |
sed 's#https\?://##;s#/.*##')


grep -qx "$d" "$ALLOW" && {

echo "已经存在"

return

}



echo "$d" >> "$ALLOW"


echo "添加成功: $d"

}




del_domain(){


echo "当前白名单:"


grep -v "^#" "$ALLOW"


echo


read -p "删除域名: " d


sed -i "/^$d$/d" "$ALLOW"


echo "完成"

}



show_domain(){

echo "======白名单======"

grep -v "^#" "$ALLOW"

}



restart(){

systemctl restart emby-proxy

systemctl restart caddy

echo "完成"

}



status(){

systemctl status emby-proxy --no-pager

echo

systemctl status caddy --no-pager

}



logs(){

journalctl -u emby-proxy -n 100 --no-pager

}



menu(){


while true

do

clear


echo "=============================="

echo " Emby Dynamic Proxy Manager v1.0"

echo "=============================="

echo

echo "1. 安装 / 重装"

echo "2. 添加白名单"

echo "3. 删除白名单"

echo "4. 查看白名单"

echo "5. 重启"

echo "6. 状态"

echo "7. 日志"

echo "8. 卸载"

echo "0. 退出"


echo

read -p "选择: " n



case $n in

1) install ;;

2) add_domain ;;

3) del_domain ;;

4) show_domain ;;

5) restart ;;

6) status ;;

7) logs ;;

8) uninstall ;;

0) exit ;;

*) echo "错误" ;;

esac


read -p "回车继续..."

done

}



check_root

menu
