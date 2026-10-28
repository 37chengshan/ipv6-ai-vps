---
name: claude-cli-network
description: 给 Claude Code CLI 配置网络出口（HTTP 代理、NO_PROXY、关闭遥测），并验证它确实走了指定出口而不是直连。适用于「Claude 流量必须从住宅/指定 IP 出去」「TUN 关闭后要失败关闭」的场景；不涉及购买 VPS 或更换订阅。
license: MIT
compatibility: macOS / Linux，Claude Code CLI（native 或 npm 安装），需要 curl 与 python3；不修改系统代理与其它 CLI 的配置。
---

# Claude CLI 网络配置

把 Claude Code 的网络出口固定到一个本地代理端口，并验证「走代理、不走直连、失败即断」。

## 适用场景

- 需要 Claude 的请求统一从某个出口（住宅 IP / 指定节点）出去
- 关闭 TUN 或系统代理时，Claude 必须报错而不是从本地网络直连
- 排查「Claude 连不上 / 走了数据中心 IP / 忽快忽慢」这类问题

## 不要做的事

- **不要给 Claude Code 配 SOCKS 代理**：它只支持 `http(s)://`，SOCKS 会导致连接失败。
- 不要把代理写进 `~/.zshrc` / `~/.bashrc` 的全局变量。很多环境有「shell 显式代理变量」检查，全局变量会被记为异常；用 settings.json 的 `env` 作用域更精确。
- 不要在未确认的情况下关闭 TUN 或系统代理；先看下面的「失败关闭检查」。

## 1. 确认代理端口

```bash
# 代理客户端（Clash/mihomo 系）的混合端口，常见 7890
lsof -nP -iTCP:7890 -sTCP:LISTEN
curl -x http://127.0.0.1:7890 -s -o /dev/null -w '%{http_code}\n' https://www.gstatic.com/generate_204
# 期望 204
```

端口不通时先修客户端，**不要**把设置指向 TUN 内网地址或改成 SOCKS。

## 2. 写入配置

用仓库脚本（会备份原文件、只改 `env` 段）：

```bash
bash scripts/configure-claude-cli.sh --proxy http://127.0.0.1:7890
```

等价的 `~/.claude/settings.json`：

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

要点：

| 变量 | 作用 |
|---|---|
| `HTTP_PROXY` / `HTTPS_PROXY` | 所有 API / 遥测 / MCP 子进程请求都走该代理，连不上就失败（不会回落直连） |
| `NO_PROXY` | 本地回环不走代理 |
| `DO_NOT_TRACK=1` | 关闭 Datadog 等遥测上报，减少无谓流量与地域不一致 |

修改后**重启 Claude 会话**：运行中的进程不会重新读取 settings。

撤销：

```bash
bash scripts/configure-claude-cli.sh --remove
```

## 3. 验证

```bash
# 1) 配置是否被读到（debug 日志里应出现 settingsEnv keys）
claude --debug -p "ok" --output-format text
grep -i "settingsEnv" ~/.claude/debug/*.txt | tail -1

# 2) 出口是否为目标 IP
curl -s https://claude.ai/cdn-cgi/trace | grep -E '^(ip|loc)='
curl -s -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/v1/models   # 401 = 链路通

# 3) 失败关闭：把代理指向一个死端口，CLI 必须报错而不是直连
HTTPS_PROXY=http://127.0.0.1:9 claude -p "ping" 2>&1 | tail -3
```

判断标准：

| 结果 | 含义 |
|---|---|
| `ip=` 是住宅/目标出口，`loc=US` | 正常 |
| `ip=` 是机房 IP | 规则没命中（检查客户端的分流规则与节点名） |
| 死端口下 CLI 仍返回内容 | 说明它绕过了代理（检查是否还有更外层代理或 TUN） |
| `401` | 链路可达，只是未认证 |

## 4. 失败关闭检查（关闭 TUN / 系统代理前必做)

```bash
# 代理端口消失时，Claude 必须失败
curl -s -m 3 -x http://127.0.0.1:9 https://api.anthropic.com -o /dev/null -w '%{http_code}\n'
# 期望 000 / curl 非 0
```

如果担心某些程序无视 `env` 硬连，可以在系统层再加一道（见仓库 README 的「系统级兜底」）：用 pf 丢弃目标为 Anthropic 网段的直连包。代理流量不受影响，因为它连的是 VPS 地址，不是 Anthropic 的 IP。

## 5. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `Not logged in` | 凭据读不出来（钥匙串权限 / 未登录） | 交互式 `claude /login`；macOS 若反复弹钥匙串，执行 `security set-generic-password-partition-list -S apple-tool:,apple: -s "Claude Code-credentials"` 一次 |
| `ECONNREFUSED 127.0.0.1:7890` | 代理客户端没启动 / 端口被改 | 修客户端；不要改成直连 |
| 首次慢、之后快 | 双栈竞争（AAAA 先试后回落） | 客户端 `ipv6: false`，并让 DNS 只返回 A |
| 请求偶发 403 / 验证 | 出口 IP 与 DNS 地域不一致 | DNS 走代理内的 DoH（见主 README） |
| 后台 agent 配置不生效 | supervisor 进程复用了旧环境 | `claude daemon stop --any` 后重开，或重启会话 |

## 6. 与其它 CLI 的关系

- `codex` 之类如果把模型请求指向本地网关（如 `http://127.0.0.1:10100/v1`），网关本身已经走代理，**不要**再给它们叠加一份 `HTTPS_PROXY`，否则可能双重代理。
- 浏览器/桌面应用不受 `~/.claude/settings.json` 影响，需要单独的分流规则。
