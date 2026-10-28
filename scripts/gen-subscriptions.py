#!/usr/bin/env python3
"""从示例模板生成客户端订阅：Clash YAML / base64 链接 / sing-box JSON。

用法：
  python3 gen-subscriptions.py --host 203.0.113.10 --uuid UUID \
      --public-key PBK --short-id SID --sni www.microsoft.com \
      --hy2-password PASS [--direct-port 443] [--resi-port 8444] [--hy2-port 8443] \
      [--outdir ./out]
"""
import argparse
import base64
import json
import pathlib


def build_links(a):
    ip, uuid, pbk, sid, sni = a.host, a.uuid, a.public_key, a.short_id, a.sni

    def vless(port, name):
        return (
            f"vless://{uuid}@{ip}:{port}?encryption=none&flow=xtls-rprx-vision"
            f"&security=reality&sni={sni}&fp=chrome&pbk={pbk}&sid={sid}"
            f"&type=tcp&headerType=none#{name}"
        )

    links = [vless(a.direct_port, "vps-direct"), vless(a.resi_port, "vps-resi")]
    if a.hy2_password:
        links.append(
            f"hysteria2://{a.hy2_password}@{ip}:{a.hy2_port}"
            f"?sni={sni}&insecure=1&alpn=h3#vps-hy2"
        )
    return links


def build_singbox(a):
    def vless(tag, port):
        return {
            "type": "vless",
            "tag": tag,
            "server": a.host,
            "server_port": port,
            "uuid": a.uuid,
            "flow": "xtls-rprx-vision",
            "tls": {
                "enabled": True,
                "server_name": a.sni,
                "utls": {"enabled": True, "fingerprint": "chrome"},
                "reality": {"enabled": True, "public_key": a.public_key, "short_id": a.short_id},
            },
        }

    out = {
        "log": {"level": "info", "timestamp": True},
        "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080}],
        "outbounds": [
            vless("vps-direct", a.direct_port),
            vless("vps-resi", a.resi_port),
            {"type": "direct", "tag": "direct"},
        ],
        "route": {"rules": [{"ip_is_private": True, "outbound": "direct"}], "final": "vps-resi"},
    }
    if a.hy2_password:
        out["outbounds"].insert(
            2,
            {
                "type": "hysteria2",
                "tag": "vps-hy2",
                "server": a.host,
                "server_port": a.hy2_port,
                "password": a.hy2_password,
                "tls": {"enabled": True, "server_name": a.sni, "alpn": ["h3"], "insecure": True},
            },
        )
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", required=True)
    p.add_argument("--uuid", required=True)
    p.add_argument("--public-key", required=True)
    p.add_argument("--short-id", required=True)
    p.add_argument("--sni", default="www.microsoft.com")
    p.add_argument("--hy2-password", default="")
    p.add_argument("--direct-port", default="443")
    p.add_argument("--resi-port", default="8444")
    p.add_argument("--hy2-port", default="8443")
    p.add_argument("--template", default=str(pathlib.Path(__file__).parent.parent / "configs/client/clash.example.yaml"))
    p.add_argument("--outdir", default="./out")
    a = p.parse_args()

    if not a.hy2_password:
        a.hy2_password = ""

    out = pathlib.Path(a.outdir)
    out.mkdir(parents=True, exist_ok=True)

    template = pathlib.Path(a.template).read_text()
    clash = (
        template.replace("203.0.113.10", str(a.host))
        .replace("8444", str(a.resi_port))
        .replace("YOUR_HY2_PASSWORD", a.hy2_password)
        .replace("YOUR_UUID", a.uuid)
        .replace("YOUR_REALITY_PUBLIC_KEY", a.public_key)
        .replace("YOUR_REALITY_SHORT_ID", a.short_id)
        .replace("YOUR_SNI", a.sni)
    )
    (out / "clash.yaml").write_text(clash)

    links = build_links(a)
    (out / "links.txt").write_text("\n".join(links) + "\n")
    (out / "sub.txt").write_text(base64.b64encode(("\n".join(links) + "\n").encode()).decode() + "\n")
    (out / "singbox.json").write_text(json.dumps(build_singbox(a), indent=2, ensure_ascii=False) + "\n")

    print(f"written to {out}: clash.yaml / sub.txt / links.txt / singbox.json")
    print("注意：这些文件包含凭据，不要提交到公开仓库。")


if __name__ == "__main__":
    main()
