# ipv6-ai-vps

把「家宽 IPv6」当作 AI 服务出口的一整套落地笔记：**Claude / OpenAI / Google 走住宅 IPv6，其余流量走机房 IPv4**，并且服务端失败关闭——IPv4 目标一律拒绝，绝不静默回落。

> 目标读者：手里有一台带「住宅 IPv6 加值服务」的 VPS（例如把 ISP 家宽 /128 租给你绑定的商家），希望让 AI 服务看到的出口是「普通家庭宽带」，同时其它流量仍然走机房。

---

## 为什么需要这套东西

- 主流 AI 服务对出口 IP 的类型敏感：数据中心段容易被降权、限速、触发验证。
- 很多 VPS 商家提供「住宅 IPv6 附加服务」：给你一个或多个 ISP 家宽前缀里的 `/128`，绑在网卡上做**出站源地址**。
- 但 IPv6 在代理场景下天然容易出问题：
  - 客户端有 IPv6 时，`domain` 规则可能只命中 A 记录，AAAA 请求绕过代理直连；
  - DNS 走本地运营商解析，出口 IP 在海外、DNS 却在国内，地域不一致；
  - 住宅 IPv6 只承载 TCP 且不保证 AAAA 存在，QUIC 走 UDP 会绕开规则或直接失败。

所以这套方案的核心不是「把流量都塞进 IPv6」，而是：

1. **客户端只跑 IPv4**（`ipv6: false`），彻底消灭 v6 直连泄漏；
2. **按域名把 AI 流量钉到住宅 IPv6 节点**，其余走机房节点；
3. **服务端做失败关闭**：住宅入口只允许 IPv6 目标，IPv4 直接 `reject`；
4. **QUIC 提前拒绝**，逼浏览器回落 TCP；
5. **DNS 拆分**：国外域名经隧道用 Cloudflare DoH 解析，国内域名直连解析。

---

## 架构

```
                    ┌─────────────── 客户端 (Clash / mihomo) ───────────────┐
                    │  规则：AI 域名 → RESI 节点；其余 → DIRECT 节点        │
                    │  ipv6=false，QUIC(UDP) 对 AI 域名 REJECT              │
                    └───────────────┬──────────────────────────────────────┘
                                    │ VLESS + REALITY (TCP)
                    ┌───────────────┴───────────────┐
                    │            VPS (sing-box)     │
                    │  inbound 443  → outbound 直连  │ → 机房 IPv4/IPv6
                    │  inbound 8444 → outbound resi6 │ → 住宅 IPv6 /128
                    └───────────────────────────────┘
```

- 住宅入口的 `route.rules`：
  1. `action: resolve` + `strategy: prefer_ipv6`
  2. `ip_version: 4` → `action: reject`
  3. 其余 → `outbound: resi6`（该出站绑定住宅 `/128`）

这样即使某个域名只有 A 记录，连接会**直接失败**，而不是悄悄从机房 IPv4 出去。

---

## 前置条件

| 项目 | 要求 |
|---|---|
| VPS | Debian 12/13，root，公网 IPv4（住宅 IPv6 由商家分配并绑定在网卡上） |
| 住宅 IPv6 | 至少一个 `/128`，商家已在你机器上配好（可用 `ip -6 addr` 看到） |
| 客户端 | 支持 Clash/mihomo 规则（Clash Verge / FlClash / Stash / Clash Mi） |
| 端口 | 443（机房入口）、8444（住宅入口）、8443（Hysteria2，可选） |

> ⚠️ 先确认商家的 ToS 是否允许代理/中转。本文只讲技术实现，合规责任在使用者。

---

## 服务端部署

### 1. 安装 sing-box

```bash
bash <(curl -fsSL https://sing-box.app/install.sh)
sing-box version
```

### 2. 生成密钥

```bash
sing-box generate uuid                 # → UUID
sing-box generate reality-keypair      # → PrivateKey / PublicKey
openssl rand -hex 8                    # → short_id
openssl rand -hex 12                   # → hysteria2 密码（可选）
```

### 3. 配置

复制 `configs/server/sing-box.example.json`，替换这些占位符：

| 占位符 | 含义 |
|---|---|
| `YOUR_SNI` | REALITY 伪装域名（如 `www.microsoft.com`） |
| `YOUR_UUID` | 上面生成的 UUID |
| `YOUR_REALITY_PRIVATE_KEY` | REALITY 私钥 |
| `YOUR_REALITY_SHORT_ID` | short_id |
| `YOUR_HY2_PASSWORD` | Hysteria2 密码（不用可删该入站） |
| `RESIDENTIAL_IPV6` | 商家给你的住宅 `/128` |

```bash
sing-box check -c /etc/sing-box/config.json
systemctl enable --now sing-box
ss -lntu | grep -E ':443|:8443|:8444'
```

也可以直接用脚本：

```bash
sudo SNI=www.microsoft.com RESI6=2001:db8:1:2::10 bash scripts/setup-server.sh
```

### 4. 订阅（可选）

`scripts/gen-subscriptions.py` 会按 `configs/client/clash.example.yaml` 生成一份带真实参数的客户端配置，并同时输出 base64（v2rayN / Surge 系）与 JSON（sing-box）。

```bash
python3 scripts/gen-subscriptions.py \
  --host 203.0.113.10 --uuid "$UUID" --public-key "$PUB" --short-id "$SID" \
  --hy2-password "$HY2PASS" --sni www.microsoft.com \
  --outdir ./out
```

把 `out/` 目录用 nginx 静态托管，路径里带一段随机 token（别用 `sub.yaml` 这种可猜的名字）：

```nginx
server {
    listen 20086;
    root /srv/sub;
    location / { try_files $uri =404; }
}
```

---

## 客户端规则

`configs/client/clash.example.yaml` 是完整模板，关键部分：

```yaml
ipv6: false          # 客户端不碰 IPv6
dns:
  ipv6: false
  nameserver:
    - "https://1.1.1.1/dns-query#Proxy"     # 国外域名经隧道解析
  nameserver-policy:
    "geosite:cn": ["https://doh.pub/dns-query"]
```

`rules` 段顺序不能乱：

1. 私网 / 本机 CIDR → `DIRECT`
2. `AND,((NETWORK,UDP),(DOMAIN-SUFFIX,anthropic.com)),REJECT` 等 18 条 QUIC 拒绝
3. AI 域名 → `RESI`（Claude / OpenAI / Google / 遥测 / 客服 widget）
4. Anthropic 自有网段与 ASN → `RESI`
5. `GEOIP,CN → DIRECT`
6. `MATCH → Proxy`

完整域名清单见 [`rules/ai-domains.txt`](rules/ai-domains.txt)，覆盖：

- Claude / Anthropic：`anthropic.com`、`claude.ai`、`claude.com`、`clau.de`、`claudemcpclient.com`、`claudemcpcontent.com`、`claudeusercontent.com`、`anthropic.auth0.com`、`anthropic-com.ghost.io`
- OpenAI：`openai.com`、`chatgpt.com`、`oaistatic.com`、`oaiusercontent.com`、`sora.com`
- Google（不含 YouTube）：`google.com`、`googleapis.com`、`gstatic.com`、`googleusercontent.com`、`gmail.com`、`google.com.hk`
- 遥测 / 客服：`sentry.io`、`statsigapi.net`、`browser-intake-us5-datadoghq.com`、`intercom.io`、`intercomcdn.com`、`cdn.usefathom.com`
- 兜底：`IP-CIDR,160.79.104.0/21`、`IP-CIDR6,2607:6bc0::/32`、`IP-ASN,399358`

### iOS

- **推荐**：Clash 内核客户端（Stash / Clash Mi）直接导入上面那份 YAML，规则与桌面一致。
- Shadowrocket 只支持有限的规则语法（无 `AND` / `IP-ASN` / `PROCESS-NAME`），参考 `configs/client/shadowrocket.example.conf`，或用纯节点订阅 + 手动规则。

---

## Claude Code CLI 配置

浏览器走系统代理，而 Claude Code 只认自己的配置。让它稳定走指定出口，三件事：

```bash
bash scripts/configure-claude-cli.sh --proxy http://127.0.0.1:7890
```

写入 `~/.claude/settings.json`：

```json
{
  "env": {
    "HTTP_PROXY": "http://127.0.0.1:7890",
    "HTTPS_PROXY": "http://127.0.0.1:7890",
    "NO_PROXY": "127.0.0.1,localhost,::1",
    "DO_NOT_TRACK": "1"
  }
}
```

| 变量 | 为什么必须 |
|---|---|
| `HTTP(S)_PROXY` | 配了代理就**不会回落直连**：端口不通直接报错，符合失败关闭 |
| `NO_PROXY` | 本地回环（MCP、daemon）不走代理 |
| `DO_NOT_TRACK` | 关掉 Datadog 等遥测，少一类「出口不一致」的干扰 |

验证：

```bash
claude --debug -p "ok" --output-format text      # debug 日志里应出现 settingsEnv keys
grep -i settingsEnv ~/.claude/debug/*.txt | tail -1
curl -s https://claude.ai/cdn-cgi/trace | grep -E '^(ip|loc)='   # 期望住宅 IPv6 + US
curl -s -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/v1/models   # 401 = 链路通
```

注意：

- **不支持 SOCKS**，`--proxy` 必须是 `http(s)://`
- 修改后要重启会话；后台 agent 由 supervisor 托管，建议 `claude daemon stop --any` 后重开
- macOS 反复弹「钥匙串请求密码」时执行一次：
  `security set-generic-password-partition-list -S apple-tool:,apple: -s "Claude Code-credentials"`

完整操作手册见 [`skills/claude-cli-network/SKILL.md`](skills/claude-cli-network/SKILL.md)（可直接作为 agent skill 安装使用）。

---

## 验证

```bash
# AI 出口必须是住宅 IPv6
curl -s https://claude.ai/cdn-cgi/trace | grep -E '^(ip|loc)='
# 期望：ip=<住宅 IPv6>  loc=US

# 普通流量必须是机房
curl -s https://ipinfo.io/ip

# 服务端失败关闭：住宅入口访问 IPv4-only 目标必须失败
curl -x http://127.0.0.1:8444 -s -m 5 -o /dev/null -w '%{http_code}\n' https://1.1.1.1
# 期望：连接失败（000 / curl 非 0），而不是 200
```

---

## 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| AI 流量走了机房 | 域名规则写在 `GEOIP,CN` 之后，或节点名写错 | 规则顺序：UDP 拒绝 → 域名 → IP → GeoIP → MATCH |
| 某些站点解析到国内 CDN，被判直连 | 用国内 DoH 解析国外域名 | 国外域名走 `#Proxy` 的 DoH，国内用 `geosite:cn` 策略 |
| 页面加载一半失败 | QUIC 走 UDP 绕过规则 | 对 AI 域名 `REJECT` UDP，让浏览器回落 TCP |
| 客户端偶尔直连 | 客户端开了 IPv6 | 关掉客户端 IPv6，`ipv6: false` |
| 家宽 IPv6 目标连不上 | 目标只有 A 记录 | 这是预期：失败关闭，不会回落 IPv4 |
| 三个 `/128` 被识别为同一用户 | 商家分配的接口标识相同 | 找商家换不同后缀，或只用其中一个 |

---

## 配额与风险

- 住宅 IPv6 通常按**账户**计费：常见额度 80 GiB/周、200 GiB/月、150 并发（以商家为准）。
- 住宅地址往往**不轮换**，声誉长期绑定，不要在同一地址上跑高并发或异常流量。
- 本文不包含任何真实地址、UUID、密钥或订阅 token；示例统一使用文档保留段（`203.0.113.0/24`、`2001:db8::/32`）。

---

## 仓库结构

```
configs/
  server/sing-box.example.json     # 服务端：双入站 + 住宅出站 + 失败关闭
  client/clash.example.yaml        # 客户端：完整分流规则
  client/shadowrocket.example.conf # iOS Shadowrocket 精简版
rules/ai-domains.txt               # AI 域名清单
scripts/setup-server.sh            # 一键服务端部署（读环境变量）
scripts/gen-subscriptions.py       # 生成 Clash / base64 / sing-box 三种订阅
scripts/configure-claude-cli.sh    # 写入/撤销 Claude Code 的代理与遥测开关
skills/claude-cli-network/SKILL.md # 可作为 agent skill 使用：Claude CLI 网络配置与验证
```

## License

MIT
