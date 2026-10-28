#!/bin/sh
# verify-egress.sh — 在客户端（Mac/手机/路由器后的设备）验证 AI 出口矩阵
#
# 前置：客户端走 FlClash/Clash TUN，住宅链路可用。
# 用法：
#   sh verify-egress.sh            # 人类可读
#   sh verify-egress.sh --quiet    # 只返回码
#
# 判定：
#   v6  → Cloudflare trace 返回 2600:1700:… 才算通过
#   v4  → trace 返回机房 IPv4（例外域名，显式走 direct）
#   any → 不关心出口，只要 TCP/TLS 通
set -u

quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1
fail=0

trace_ip() {
  curl -sS -m 10 "https://$1/cdn-cgi/trace" 2>/dev/null | sed -n 's/^ip=//p' | head -1
}

code_of() {
  curl -sS -m 10 -o /dev/null -w '%{http_code}' "https://$1/" 2>/dev/null
}

say() { [ "$quiet" -eq 1 ] || printf '%s\n' "$*"; }

say "domain                                     expect  result  exit"
check_v6() {
  host=$1
  ip=$(trace_ip "$host")
  if [ -z "$ip" ]; then
    say "$(printf '%-42s %-7s %-7s %s' "$host" v6 FAIL '(no trace)')"
    fail=1
  else
    case "$ip" in
      2600:1700:*) ok=OK ;;
      *) ok=FAIL; fail=1 ;;
    esac
    say "$(printf '%-42s %-7s %-7s %s' "$host" v6 "$ok" "$ip")"
  fi
}

check_v4() {
  host=$1
  ip=$(trace_ip "$host")
  if [ -z "$ip" ]; then
    say "$(printf '%-42s %-7s %-7s %s' "$host" v4 FAIL '(no trace)')"
    fail=1
    return
  fi
  case "$ip" in
    *:*) ok=FAIL; fail=1 ;;
    23.246.166.75) ok=OK ;;
    *) ok=WARN ;;
  esac
  say "$(printf '%-42s %-7s %-7s %s' "$host" v4 "$ok" "$ip")"
}

check_any() {
  host=$1
  code=$(code_of "$host")
  if [ "${code:-000}" = "000" ]; then
    say "$(printf '%-42s %-7s %-7s %s' "$host" any FAIL 'unreachable')"
    fail=1
  else
    say "$(printf '%-42s %-7s %-7s %s' "$host" any OK "http=$code")"
  fi
}

# 必须走住宅 IPv6 的 AI 端点
check_v6 claude.ai
check_v6 chatgpt.com
check_v6 ws.chatgpt.com

# 显式 IPv4 例外（走机房 direct，不占住宅额度）
check_v4 openai.com
check_v4 files.oaiusercontent.com

# 只验证可达性的 API 端点
check_any api.anthropic.com
check_any api.openai.com

[ "$quiet" -eq 1 ] || {
  echo
  if [ "$fail" -eq 0 ]; then
    echo "RESULT: PASS"
  else
    echo "RESULT: FAIL（AI 出口矩阵不符合预期，先看 aether-flowd / sing-box 规则）"
  fi
}
exit "$fail"
