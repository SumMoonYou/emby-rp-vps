#!/bin/bash
# ============================================================
# Emby Dynamic Proxy Manager v1.4
#
# Dynamic Emby Reverse Proxy
#
# 支持:
# - HTTPS 443 自动证书
# - HTTP 80模式
# - WebSocket
# - Range流媒体
# - KeepAlive
# - 白名单控制
# - 空白名单默认放行
# - Caddy反代优化
#
# 不修改系统TCP参数
# ============================================================

APP_DIR="/opt/emby-proxy"
SERVICE="/etc/systemd/system/emby-proxy.service"
CADDY="/etc/caddy/Caddyfile"
ALLOW="$APP_DIR/allow.list"

PORT=8787
DOMAIN=""
LISTEN_PORT="443"



check_root(){
[ "$(id -u)" = "0" ] || {
echo "请使用root运行"
exit 1
}
}



install_node(){

command -v node >/dev/null && {
echo "Node已安装"
return
}

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -

apt update
apt install -y nodejs

}




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
# 留空=允许所有目标域名
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



const httpAgent=new http.Agent({
keepAlive:true,
maxSockets:1024,
maxFreeSockets:256,
timeout:60000
});



const httpsAgent=new https.Agent({
keepAlive:true,
maxSockets:1024,
maxFreeSockets:256,
timeout:60000,
rejectUnauthorized:false
});



let allowCache=[];
let allowTime=0;



function allowList(){

let now=Date.now();

if(now-allowTime<60000)
return allowCache;


try{

allowCache=fs.readFileSync(ALLOW,"utf8")
.split("\n")
.map(v=>v.trim())
.filter(v=>v&&!v.startsWith("#"));


allowTime=now;

return allowCache;


}catch(e){

return [];

}

}




function domainAllowed(host){

let list=allowList();


if(!list.length)
return true;


host=host.toLowerCase();


return list.some(d=>{

d=d.replace(/^https?:\/\//,"")
.replace(/\/.*$/,"")
.trim()
.toLowerCase();


return host===d||host.endsWith("."+d);

});

}





function parseTarget(req){


let u=new URL(req.url,"http://localhost");


let raw=u.pathname.substring(1);


if(
!raw.startsWith("http://") &&
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
target.protocol==="https:"?https:http;


let agent=
target.protocol==="https:"?httpsAgent:httpAgent;



let headers={
...req.headers,
host:target.host,
"x-real-ip":req.socket.remoteAddress,
"x-forwarded-for":req.socket.remoteAddress
};



// 禁止重复压缩
delete headers["accept-encoding"];


// 保留Range请求
if(req.headers.range)
headers.range=req.headers.range;



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

agent,

rejectUnauthorized:false,

highWaterMark:1024*1024


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
`Emby Dynamic Proxy v1.4

Proxy OK

Usage:

https://${req.headers.host}/https://Emby地址

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








// WebSocket

server.on("upgrade",(req,socket)=>{


let target=parseTarget(req);



if(!target||target.deny){

socket.destroy();

return;

}



let client=
target.protocol==="https:"?https:http;


let agent=
target.protocol==="https:"?httpsAgent:httpAgent;



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


headers:{
...req.headers,
host:target.host
},


agent,

rejectUnauthorized:false


});



p.on("upgrade",(proxySocket)=>{


socket.write(
"HTTP/1.1 101 Switching Protocols\r\n"+
"Upgrade: websocket\r\n"+
"Connection: Upgrade\r\n\r\n"
);



proxySocket.pipe(socket);

socket.pipe(proxySocket);


});



p.on("error",()=>{

socket.destroy();

});


p.end();


});





server.timeout=0;

server.keepAliveTimeout=65000;

server.headersTimeout=70000;

server.maxConnections=2000;



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
create_service(){

cat >"$SERVICE"<<EOF
[Unit]
Description=Emby Dynamic Proxy Manager v1.4
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/node --max-old-space-size=512 $APP_DIR/server.js
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF


systemctl daemon-reload

systemctl enable emby-proxy

systemctl restart emby-proxy

}





create_caddy(){


mkdir -p /etc/caddy



if [ "$LISTEN_PORT" = "80" ]; then


cat >"$CADDY"<<EOF
http://$DOMAIN {


    reverse_proxy 127.0.0.1:$PORT {


        flush_interval -1


        transport http {


            dial_timeout 5s

            response_header_timeout 60s

            keepalive 60s

            keepalive_idle_conns 256

            read_buffer 65536

            write_buffer 65536


        }


    }


}
EOF



else


cat >"$CADDY"<<EOF
$DOMAIN {


    reverse_proxy 127.0.0.1:$PORT {


        flush_interval -1


        transport http {


            dial_timeout 5s

            response_header_timeout 60s

            keepalive 60s

            keepalive_idle_conns 256

            read_buffer 65536

            write_buffer 65536


        }


    }


}
EOF


fi




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


echo "================================"

echo " Emby Dynamic Proxy Manager v1.4"

echo "================================"


echo


read -p "请输入Emby反代域名: " DOMAIN



[ -z "$DOMAIN" ] && {


echo "域名不能为空"

return


}



read -p "请输入公网访问端口(默认443): " LISTEN_PORT



[ -z "$LISTEN_PORT" ] && LISTEN_PORT=443



if [ "$LISTEN_PORT" != "80" ] && [ "$LISTEN_PORT" != "443" ]; then


echo "仅支持80或443"

return


fi




[ -f "$SERVICE" ] && clean_old



install_node

install_caddy



init_dir

create_node

create_service



if create_caddy

then



echo

echo "=============================="

echo "安装完成"

echo "=============================="


echo


if [ "$LISTEN_PORT" = "443" ]; then


echo "访问地址:"
echo "https://$DOMAIN"


else


echo "访问地址:"
echo "http://$DOMAIN"


fi


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



d=$(echo "$d" | sed 's#https\?://##;s#/.*##')



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



echo "删除完成"


}






show_domain(){


echo "========== 白名单 =========="


grep -v "^#" "$ALLOW"



echo



echo "说明:"
echo "为空表示允许所有目标域名"


}






restart(){


systemctl restart emby-proxy

systemctl restart caddy



echo "重启完成"


}





status(){


echo "====== Emby Proxy ======"


systemctl status emby-proxy --no-pager



echo



echo "====== Caddy ======"


systemctl status caddy --no-pager


}






logs(){


journalctl -u emby-proxy -n 100 --no-pager


}






menu(){


while true

do


clear



echo "===================================="

echo " Emby Dynamic Proxy Manager v1.4"

echo "===================================="

echo


echo "1. 安装 / 重装"

echo "2. 添加白名单"

echo "3. 删除白名单"

echo "4. 查看白名单"

echo "5. 重启服务"

echo "6. 查看状态"

echo "7. 查看日志"

echo "8. 卸载"

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



0)

exit

;;



*)

echo "错误"

;;


esac



read -p "回车继续..."

done


}





check_root

menu
