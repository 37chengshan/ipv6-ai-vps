#!/usr/bin/env bash
# 在 Debian 12/13 上把 sing-box 配成「机房入口 + 住宅 IPv6 入口（失败关闭）」。
# 用法：
#   sudo SNI=www.microsoft.com RESI6=2001:db8:1:2::10 bash setup-server.sh
# 可选环境变量：HY2=1 生成 Hysteria2 入站（默认开启）；PORT_DIRECT=443 PORT_RESI=8444 PORT_HY2=8443
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SNI="${SNI:-www.microsoft.com}"
RESI6="${RESI6:?需要设置 RESI6（商家给你的住宅 IPv6 /128）}"
PORT_DIRECT="${PORT_DIRECT:-443}"
PORT_RESI="${PORT_RESI:-8444}"
PORT_HY2="${PORT_HY2:-8443}"
HY2="${HY2:-1}"

echo "==> 安装依赖"
apt-get update -qq
apt-get install -y -qq curl ca-certificates openssl jq >/dev/null

echo "==> 安装 sing-box"
if ! command -v sing-box >/dev/null; then
  bash -c "$(curl -fsSL https://sing-box.app/install.sh)"
fi

echo "==> 生成密钥"
mkdir -p /etc/sing-box && chmod 700 /etc/sing-box
UUID=$(sing-box generate uuid)
KP=$(sing-box generate reality-keypair)
PRIV=$(echo "$KP" | awk -F': *' '/[Pp]rivate/{print $2}')
PUB=$(echo "$KP" | awk -F': *' '/[Pp]ublic/{print $2}')
SID=$(openssl rand -hex 8)
HY2PASS=$(openssl rand -hex 12)

cat >/etc/sing-box/secrets.env <<EOF
UUID=$UUID
REALITY_PRIVATE=$PRIV
REALITY_PUBLIC=$PUB
REALITY_SHORT_ID=$SID
HY2_PASSWORD=$HY2PASS
RESIDENTIAL_IPV6=$RESI6
EOF
chmod 600 /etc/sing-box/secrets.env

echo "==> 生成配置"
[ -f /etc/sing-box/cert.pem ] || openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
  -keyout /etc/sing-box/key.pem -out /etc/sing-box/cert.pem -subj "/CN=${SNI}" >/dev/null 2>&1

cat >/etc/sing-box/config.json <<JSON
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-direct", "listen": "::", "listen_port": ${PORT_DIRECT},
      "users": [ { "name": "u1", "uuid": "${UUID}", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true, "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${SNI}", "server_port": 443 },
          "private_key": "${PRIV}",
          "short_id": [ "${SID}" ]
        }
      }
    },
    {
      "type": "vless", "tag": "vless-resi", "listen": "::", "listen_port": ${PORT_RESI},
      "users": [ { "name": "u1", "uuid": "${UUID}", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true, "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${SNI}", "server_port": 443 },
          "private_key": "${PRIV}",
          "short_id": [ "${SID}" ]
        }
      }
    }
$( if [ "$HY2" = "1" ]; then cat <<HY
    ,{
      "type": "hysteria2", "tag": "hy2-direct", "listen": "::", "listen_port": ${PORT_HY2},
      "users": [ { "name": "u1", "password": "${HY2PASS}" } ],
      "tls": {
        "enabled": true, "alpn": [ "h3" ],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    }
HY
fi )
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "direct", "tag": "resi6", "inet6_bind_address": "${RESI6}" }
  ],
  "route": {
    "rules": [
      { "inbound": [ "vless-resi" ], "action": "resolve", "strategy": "prefer_ipv6" },
      { "inbound": [ "vless-resi" ], "ip_version": 4, "action": "reject" },
      { "inbound": [ "vless-resi" ], "outbound": "resi6" }
    ],
    "final": "direct"
  }
}
JSON

echo "==> 校验并启动"
sing-box check -c /etc/sing-box/config.json
cat >/etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now sing-box
sleep 2
systemctl is-active sing-box
ss -lntu | grep -E ":${PORT_DIRECT}|:${PORT_RESI}|:${PORT_HY2}" || true

echo
echo "==> 完成。客户端参数："
echo "    server   : $(curl -fsS -m 5 https://api.ipify.org || echo '<你的公网 IPv4>')"
echo "    uuid     : ${UUID}"
echo "    publickey: ${PUB}"
echo "    short_id : ${SID}"
echo "    sni      : ${SNI}"
echo "    resi 端口: ${PORT_RESI}"
echo "（这些值同样保存在 /etc/sing-box/secrets.env，权限 600）"
