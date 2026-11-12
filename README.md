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
  0. **IPv4 例外**：`sentry.io` / `statsigapi.net` / `intercom.io` / `intercomcdn.com` /
     `servd-anthropic-website.b-cdn.net` / `openai.com` / `downloads.claude.ai`，
     以及 `*.oaiusercontent.com`
     → `outbound: direct`（显式走机房 IPv4；这些域名公开 DNS 只有 A，
     或属于遥测/CDN，拿住宅 IP 没有意义）
  1. `action: resolve` + `strategy: ipv6_only`
  2. `ip_version: 4` → `action: reject`
  3. 其余 → `outbound: resi6`（绑定住宅 `/128`）

- **机房入口的兜底（2026-11-06）**：`vless-direct(443)` 与 `hy2-direct(8443)` 现在对
  `ai-labs-domains`（Claude/Anthropic + OpenAI 全家族）直接 `reject`，并额外 reject
  `160.79.104.0/21` 与 `2607:6bc0::/32`。含义：**即使某台设备的规则缺失/过期、把 AI 域名
  送到了机房入口，服务端也不会让它从机房出去**——要么走住宅入口，要么失败。故障面从
  「静默泄漏」变成「立刻连不上」，便于定位那台设备。

- **掐断而不是回退**：住宅出站 `resi6` 同时设置 `inet4_bind_address: "127.0.0.1"`，
  再加上 `ipv6_only`，任何拿不到 AAAA 的目标都会直接失败，不可能从机房 IPv4 出去。
  实测：临时移出例外的 A-only 域名返回 000（超时/重置），不会走 IPv4。
- 机房侧另有 `aether-ai-guard.service`（nftables）丢弃对 `160.79.104.0/21` 的 IPv4 出站，
  作为 Anthropic 方向的双保险。

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

### 5. 拥塞控制：启用 BBR（必做）

默认的 `cubic` 在丢包链路上会把窗口砍到 2 个报文，吞吐随之塌到几十 KB/s。同一台 VPS、同一条链路实测：

| 指标 | cubic（默认） | BBR |
|---|---|---|
| 单连接吞吐 | 20–46 KB/s | **205–262 KB/s** |
| `cwnd` | 2 MSS | 21–24 MSS |
| 重传占比 | 34% | 接近 0 |
| ChatGPT 首页 663 KB | 20–30 秒 | **2.5 秒** |

服务端三条命令，不需要重启 sing-box：

```bash
modprobe tcp_bbr
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr
```

持久化，重启后仍然生效：

```bash
printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf
echo tcp_bbr > /etc/modules-load.d/bbr.conf
```

确认是否生效：

```bash
sysctl -n net.ipv4.tcp_congestion_control        # bbr
ss -tin state established "( sport = :8444 )" | grep -oE 'cwnd:[0-9]+'
# 新建的连接应看到两位数 cwnd；仍是 cwnd:2 说明没生效（旧连接不会切换算法）
```

> 只影响新建连接。改完要开一个新页面或重连一次才走新算法。

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

`rules` 段顺序不能乱（2026-11-08 起 84 条）：

1. 私网 / 本机 CIDR → `DIRECT`
2. **进程级兜底**：`PROCESS-NAME,claude` + `PROCESS-PATH-REGEX,.*/claude/versions/.*`
   → `RESI`，同进程的 UDP/QUIC 一律 `REJECT`。
   原因：`~/.local/bin/claude` 是 symlink，mihomo 解析真实路径后 process 名是版本号，
   只写 `PROCESS-NAME` 匹配不到；路径规则才是 CLI 的可靠兜底。
3. `AND,((NETWORK,UDP),(DOMAIN-SUFFIX,...))` / `(DOMAIN-KEYWORD,...)` → `REJECT`（QUIC 拒绝）
4. AI 域名（后缀 + 关键字）→ `RESI`（Claude / OpenAI / Google / 遥测 / 客服 widget）
   关键字兜底 `claude` / `anthropic` / `openai` 负责清单外的新域名；`vsassets.io` 先钉回机房，
   因为 VS Code 市场里带厂商名的静态资源不是 AI 流量。Cloudflare 验证组件单独处理：
   `auth.exa.ai` 与 `challenges.cloudflare.com` 走住宅，否则 Turnstile 会把机房 IP 判成可疑。
5. Anthropic 自有网段与 ASN → `RESI`
6. `GEOIP,CN → DIRECT`
7. `MATCH → Proxy`（机房）

完整域名清单见 [`rules/ai-domains.txt`](rules/ai-domains.txt)，覆盖：

- Claude / Anthropic：`anthropic.com`、`claude.ai`、`claude.com`、`clau.de`、`claudemcpclient.com`、`claudemcpcontent.com`、`claudeusercontent.com`、`anthropic.auth0.com`、`anthropic-com.ghost.io`
- OpenAI：`openai.com`、`chatgpt.com`、`oaistatic.com`、`oaiusercontent.com`、`sora.com`
- Google（不含 YouTube）：`google.com`、`googleapis.com`、`gstatic.com`、`googleusercontent.com`、`gmail.com`、`google.com.hk`
- 遥测 / 客服：`sentry.io`、`statsigapi.net`、`browser-intake-us5-datadoghq.com`、`intercom.io`、`intercomcdn.com`、`cdn.usefathom.com`
- 兜底：`IP-CIDR,160.79.104.0/21`、`IP-CIDR6,2607:6bc0::/32`、`IP-ASN,399358`
- **关键字兜底（2026-11-06）**：`DOMAIN-KEYWORD,claude` / `anthropic` / `openai`——清单外的新域名
  （同厂商的新注册域、新 CDN）也会留在住宅出口。唯一例外是先于关键字匹配的
  `DOMAIN-SUFFIX,vsassets.io`（VS Code 市场 CDN，30 天实测 373MB/239MB，非 AI 流量，留在机房）。
  顺带把过宽的 `DOMAIN-KEYWORD,sift` 收窄成 `DOMAIN-SUFFIX,siftscience.com`。

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

**自动更新**：建议关闭（本项目按需手动更新），在 `~/.claude/settings.json` 写
`"env": { "DISABLE_AUTOUPDATER": "1" }`；`claude doctor` 会显示
`Auto-updates: disabled (set by env: DISABLE_AUTOUPDATER)`。
`downloads.claude.ai` 只有 A 记录，已列入 IPv4 例外；否则更新会在住宅入口被掐断
（表现为 `Failed to fetch version ... Socket is closed`）。

完整操作手册见 [`skills/claude-cli-network/SKILL.md`](skills/claude-cli-network/SKILL.md)（可直接作为 agent skill 安装使用）。

---

## 验证

一键检查（在客户端跑，需经代理 TUN）：

```bash
sh scripts/verify-egress.sh
# 期望：claude.ai / chatgpt.com / ws.chatgpt.com = 2600:1700:…（住宅 v6）
#       openai.com / files.oaiusercontent.com = 23.246.166.75（显式例外，走机房 v4）
#       RESULT: PASS
```

手工核对：

```bash
curl -s https://claude.ai/cdn-cgi/trace | grep -E '^(ip|loc)='
# 期望：ip=2600:1700:…  loc=US

curl -s https://chatgpt.com/cdn-cgi/trace | grep -E '^ip='
# 期望：同上，住宅 IPv6

# 例外域名：显式走机房 IPv4
curl -s https://openai.com/cdn-cgi/trace | grep -E '^ip='
# 期望：ip=23.246.166.75

# 失败关闭：不在例外清单里的 IPv4-only 目标必须直接失败
# （临时把某域名从例外里移除后测试；期望 000 / curl 非 0）
```

服务端侧核对：

```bash
systemctl is-active sing-box aether-flowd aether-ai-guard
sing-box check -c /etc/sing-box/config.json
nft list table inet ai_guard | grep counter   # packets/bytes 应长期为 0
ss -tin state established "( sport = :8444 )" | grep -oE 'cwnd:[0-9]+|bytes_retrans:[0-9]+'
# 期望：cwnd 两位数、bytes_retrans 很小；出现 cwnd:2 说明 BBR 没生效或链路在丢包
python3 - <<'SQL'
import sqlite3, time
c = sqlite3.connect("/var/lib/aether-usage/flows.db")
since = int(time.time()) - 900
for r in c.execute("select outbound,sum(up),sum(down) from flows where minute>=? group by outbound", [since]):
    print(r)
SQL
```

---

## 告警语义

服务端已经把出口固定为「住宅 IPv6 或直接失败」，**不需要任何周期性探测**。
客户端的 Claude Radar 已移除探测逻辑（`/api/probe` 返回 404），
告警完全基于 mihomo 的真实连接记录，零额外流量：

| 触发条件 | 含义 | 处理 |
|---|---|---|
| 真实 Claude 连接的出站不是住宅（`exit=datacenter`，5 分钟内） | **疑似泄漏**：流量走了机房出口 | 立即通知并附域名，检查例外清单 / `inet4_bind_address` / 客户端规则 |
| 真实 Claude 连接连续失败（3 次，5 分钟内） | 链路不可用 | 通知「Claude 连接连续失败」，查住宅额度或隧道 |

“当前出口”卡片直接显示最近一条真实连接的家宽 IPv6，不再依赖探测记录。
历史 `probe` 记录已从事件库清理，界面只保留「真实流量 / 全部」两个视图。

## 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| AI 流量走了机房 | 域名规则写在 `GEOIP,CN` 之后，或节点名写错 | 规则顺序：UDP 拒绝 → 域名 → IP → GeoIP → MATCH |
| 某台设备 Claude/ChatGPT 突然连不上（服务端 reject） | 该设备用的是旧 profile 或纯节点订阅，把 AI 域名送到了 443 机房入口；服务端 2026-11-06 起 fail-closed | 用 `flows.db` 的 `src` 定位设备，换成带规则的客户端配置；这是「不泄漏就断」的预期行为 |
| 某些站点解析到国内 CDN，被判直连 | 用国内 DoH 解析国外域名 | 国外域名走 `#Proxy` 的 DoH，国内用 `geosite:cn` 策略 |
| 页面加载一半失败 | QUIC 走 UDP 绕过规则 | 对 AI 域名 `REJECT` UDP，让浏览器回落 TCP |
| 页面能开但很慢，大图/视频出不来 | 服务端 `cwnd` 掉到 2、重传三成以上，不是带宽不够 | 开 BBR，见「拥塞控制」；用 `ss -tin` 看 `cwnd` 与 `bytes_retrans` 确认 |
| Claude 发消息一直加载，最后报 `ECONNRESET` | 会话上下文太大，单个请求体积大，链路抖一下就整条断 | 开新会话（交接钩子会在 380k 提醒）；请求越小越抗抖 |
| 日志出现 `REALITY: processed invalid connection` | 客户端配置与服务端对不上（`short_id` / SNI），或公网探测 | 核对两端 `short_id` 与 SNI；不一致就重新导入客户端配置 |
| 客户端偶尔直连 | 客户端开了 IPv6 | 关掉客户端 IPv6，`ipv6: false` |
| 家宽 IPv6 目标连不上 | 目标只有 A 记录，且不在例外清单 | 预期：失败关闭，不会回落 IPv4；确需使用就加进例外（走机房 v4） |
| 例外域名走了住宅 | 例外规则排在 `resolve` 之后 | 例外必须放在 `route.rules` 最前面 |
| 出口偶尔变成机房 IPv4 | 旧配置 `prefer_ipv6` 会回退 | 用 `ipv6_only` + `inet4_bind_address: 127.0.0.1`，见上文 |
| 三个 `/128` 被识别为同一用户 | 商家分配的接口标识相同 | 找商家换不同后缀，或只用其中一个 |

---

## 配额与风险

- 住宅 IPv6 通常按**账户**计费：常见额度 80 GiB/周、200 GiB/月、150 并发（以商家为准）。
- 住宅地址往往**不轮换**，声誉长期绑定，不要在同一地址上跑高并发或异常流量。
- 本文不包含任何真实地址、UUID、密钥或订阅 token；示例统一使用文档保留段（`203.0.113.0/24`、`2001:db8::/32`）。

---

## 可选：出口观测与兜底

| 组件 | 作用 | 安装 |
|---|---|---|
| `scripts/flowd.py` | 通过 sing-box `clash_api` 每 1 秒采样，按「域名 / 出站 / 客户端 IP」写入 `/var/lib/aether-usage/flows.db`（保留 8 天） | 见 `scripts/units/aether-flowd.service` |
| `scripts/ai-guard.nft` | 机房侧 nftables 兜底，禁止 IPv4 出站到 `160.79.104.0/21` | `sudo nft -f scripts/ai-guard.nft` + `scripts/units/aether-ai-guard.service` |

启用观测前需要在服务器侧给 sing-box 打开 clash_api：

```json
"experimental": { "clash_api": { "external_controller": "127.0.0.1:2092" } }
```

采样器的已知局限：只记录采样瞬间仍存活的连接，**1 秒内建完就关的短连接会被漏掉**，
所以 `flows.db` 适合定位「谁在吃流量」，不适合与账单逐字节对账。

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
scripts/verify-egress.sh           # 客户端出口矩阵检查
scripts/flowd.py                   # 可选：按域名/出站采集流量（sing-box clash_api）
scripts/ai-guard.nft               # 可选：机房侧 IPv4 出站兜底（nftables）
skills/claude-cli-network/SKILL.md # 可作为 agent skill 使用：Claude CLI 网络配置与验证
```

## License

MIT
