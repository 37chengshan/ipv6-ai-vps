#!/usr/bin/env bash
# 给 Claude Code CLI 写入代理与遥测开关（合并到 ~/.claude/settings.json，保留其它键）
#
#   bash configure-claude-cli.sh --proxy http://127.0.0.1:7890
#   bash configure-claude-cli.sh --remove
#   bash configure-claude-cli.sh --print
#
# 说明：
# - Claude Code 不支持 SOCKS 代理，--proxy 必须是 http(s)://
# - 写入 settings.json 的 env 对交互会话、后台 agent、MCP 子进程同时生效
# - 每次修改都会先备份为 settings.json.bak-<时间戳>
set -euo pipefail

TARGET="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
PROXY=""
NO_PROXY_VALUE="127.0.0.1,localhost,::1"
DO_NOT_TRACK=1
MODE="apply"

while [ $# -gt 0 ]; do
  case "$1" in
    --proxy) PROXY="$2"; shift 2 ;;
    --no-proxy) NO_PROXY_VALUE="$2"; shift 2 ;;
    --no-telemetry-off) DO_NOT_TRACK=0; shift ;;
    --remove) MODE="remove"; shift ;;
    --print) MODE="print"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

python3 - "$TARGET" "$PROXY" "$NO_PROXY_VALUE" "$DO_NOT_TRACK" "$MODE" <<'PY'
import json, os, pathlib, shutil, sys, time

target = pathlib.Path(os.path.expanduser(sys.argv[1]))
proxy, no_proxy, do_not_track, mode = sys.argv[2], sys.argv[3], sys.argv[4] == "1", sys.argv[5]

if mode == "print":
    if target.exists():
        print(json.dumps(json.loads(target.read_text()), indent=2, ensure_ascii=False))
    else:
        print("{}")
    raise SystemExit(0)

if proxy and not proxy.startswith(("http://", "https://")):
    raise SystemExit("--proxy 必须是 http:// 或 https://（Claude Code 不支持 SOCKS）")

data = {}
if target.exists():
    data = json.loads(target.read_text() or "{}")
    backup = target.with_suffix(f".json.bak-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(target, backup)
    print(f"备份: {backup}")

env = dict(data.get("env") or {})
for key in ("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "DO_NOT_TRACK"):
    env.pop(key, None)
if mode != "remove":
    if proxy:
        env["HTTP_PROXY"] = proxy
        env["HTTPS_PROXY"] = proxy
    env["NO_PROXY"] = no_proxy
    if do_not_track:
        env["DO_NOT_TRACK"] = "1"

if env:
    data["env"] = env
else:
    data.pop("env", None)

target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print(f"写入: {target}")
print(json.dumps({"env": data.get("env", {})}, indent=2, ensure_ascii=False))
PY
