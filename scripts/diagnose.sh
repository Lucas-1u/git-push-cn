#!/usr/bin/env bash
# git-push-cn / 一键诊断：本机 git → GitHub 通路是否可用
#
# 用法（在 Git Bash 里跑）:
#   bash diagnose.sh            # 自动探测梯子端口
#   bash diagnose.sh 7891       # 手动指定端口
#
# 退出码: 0 = 全部通过；1 = 有问题
set -u

PORT="${1:-}"
FAIL=0

ok()   { printf '  [OK]   %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=1; }
warn() { printf '  [WARN] %s\n' "$1"; }

echo "=== 1/5 梯子端口 ==="
if [ -z "$PORT" ]; then
  PORT=$(netstat -ano 2>/dev/null | grep -i LISTENING | awk '{print $2}' \
        | grep -oE ':[0-9]+$' | tr -d ':' | sort -un \
        | grep -xE '7890|7891|7892|7897|10808|10809|1080|1081|8080|2080|20171' | head -1)
fi
if [ -n "$PORT" ]; then
  ok "找到本地代理端口 127.0.0.1:$PORT"
else
  bad "没找到常见代理端口 —— 梯子没开？或用了不常见的端口（可手动传入：bash diagnose.sh <端口>）"
fi

echo
echo "=== 2/5 git 三项配置 ==="
P=$(git config --get 'http.https://github.com/.proxy' 2>/dev/null || true)
if [ -n "$P" ]; then ok "github 专用代理 = $P"; else bad "未配置 http.https://github.com/.proxy（git 不会走梯子）"; fi

SV=$(git config --get http.sslverify 2>/dev/null || true)
if [ -z "$SV" ] || [ "$SV" = "true" ]; then
  ok "证书校验开启（sslverify 未设置 = 默认 true）"
else
  bad "http.sslverify=$SV —— 证书校验被关闭，存在中间人截获 token 风险，应执行: git config --global --unset http.sslverify"
fi

if git config --get-all 'credential.https://github.com.helper' 2>/dev/null | grep -q 'auth git-credential'; then
  ok "凭据助手已接 gh"
else
  bad "凭据助手未接 gh（push 会报 could not read Username）→ 执行: gh auth setup-git"
fi

echo
echo "=== 3/5 网络连通性 ==="
if [ -n "$PORT" ]; then
  C=$(curl -s -o /dev/null -w '%{http_code}' --ssl-no-revoke --max-time 25 \
        -x "http://127.0.0.1:$PORT" https://github.com 2>/dev/null || true)
  if [ "$C" = "200" ]; then ok "经梯子访问 github.com = 200"; else bad "经梯子访问 github.com = ${C:-超时/失败}（节点问题？换个节点再试）"; fi
fi
C2=$(curl -s -o /dev/null -w '%{http_code}' --ssl-no-revoke --noproxy '*' --max-time 15 https://api.github.com 2>/dev/null || true)
if [ "$C2" = "200" ]; then
  ok "直连 api.github.com = 200（API 直传兜底可用）"
else
  warn "直连 api.github.com = ${C2:-失败}（只影响兜底方案，不影响主方案）"
fi
C3=$(curl -s -o /dev/null -w '%{http_code}' --ssl-no-revoke --noproxy '*' --max-time 15 https://github.com 2>/dev/null || true)
if [ "$C3" = "200" ]; then
  warn "直连 github.com 也通 —— 当前网络没墙（这种状态是间歇性的，墙恢复后代理配置就是必需品，保持配置不要删）"
else
  ok "直连 github.com 不通（${C3:-超时}）—— 符合预期，所以才必须走代理或 SSH"
fi

echo
echo "=== 4/5 git 读（公开仓库，不需要凭据）==="
if git ls-remote --exit-code https://github.com/octocat/Hello-World.git HEAD >/dev/null 2>&1; then
  ok "git ls-remote 通过"
else
  bad "git ls-remote 失败 —— 按上面的报错对照 SKILL.md 的「症状→病因」表处理"
fi

echo
echo "=== 5/5 git 写（当前目录是仓库时才测）==="
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  URL=$(git remote get-url origin 2>/dev/null || true)
  if [ -n "$URL" ]; then
    printf '  当前仓库 origin = %s\n' "$URL"
    if OUT=$(git push --dry-run 2>&1); then
      ok "push --dry-run 通过（认证正常）: $(printf '%s' "$OUT" | tail -1)"
    else
      bad "push --dry-run 失败:"
      printf '%s\n' "$OUT" | tail -3 | sed 's/^/         /'
    fi
  else
    warn "当前仓库没有 origin，跳过"
  fi
else
  warn "当前目录不是 git 仓库，跳过写测试"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "=== 结论：通路正常，可以直接 git push ==="
else
  echo "=== 结论：存在失败项（见上方 [FAIL]）—— 先跑 scripts/setup.sh 修复 ==="
fi
exit "$FAIL"
