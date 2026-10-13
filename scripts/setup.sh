#!/usr/bin/env bash
# git-push-cn / 一键配置：per-URL 代理 + gh 凭据 + 验证
#
# 幂等，可反复跑。用法（在 Git Bash 里跑）:
#   bash setup.sh            # 自动探测梯子端口
#   bash setup.sh 7891       # 手动指定端口
#
# 退出码: 0 = 配置成功且验证通过；1 = 失败
set -u

PORT="${1:-}"

echo "=== 1/5 确定梯子端口 ==="
if [ -z "$PORT" ]; then
  PORT=$(netstat -ano 2>/dev/null | grep -i LISTENING | awk '{print $2}' \
        | grep -oE ':[0-9]+$' | tr -d ':' | sort -un \
        | grep -xE '7890|7891|7892|7897|10808|10809|1080|1081|8080|2080|20171' | head -1)
fi
if [ -z "$PORT" ]; then
  echo "  [FAIL] 没找到代理端口。请确认梯子在运行，或手动指定: bash setup.sh <端口>"
  exit 1
fi
echo "  使用端口 127.0.0.1:$PORT"

echo
echo "=== 2/5 实测该端口能否连通 github（不通就不写入配置）==="
C=$(curl -s -o /dev/null -w '%{http_code}' --ssl-no-revoke --max-time 25 \
      -x "http://127.0.0.1:$PORT" https://github.com 2>/dev/null || true)
if [ "$C" != "200" ]; then
  echo "  [FAIL] 经 127.0.0.1:$PORT 访问 github.com 返回 ${C:-超时/失败}"
  echo "         先确认梯子在跑、换个节点，或换端口后重试。"
  exit 1
fi
echo "  [OK]   经该端口访问 github.com = 200"

echo
echo "=== 3/5 写入 github 专用代理（只影响 github.com，不动其他仓库）==="
git config --global --replace-all 'http.https://github.com/.proxy' "http://127.0.0.1:$PORT"
echo "  [OK]   http.https://github.com/.proxy = http://127.0.0.1:$PORT"

echo
echo "=== 4/5 配置凭据（gh 提供，避免 could not read Username）==="
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    gh auth setup-git >/dev/null 2>&1 && echo "  [OK]   已把 git 凭据接到 gh"
  else
    echo "  [WARN] gh 未登录 → 先跑: gh auth login"
  fi
else
  echo "  [WARN] 没找到 gh 命令，跳过（push 时会要账号密码）"
fi

SV=$(git config --get http.sslverify 2>/dev/null || true)
if [ -n "$SV" ] && [ "$SV" != "true" ]; then
  echo "  [WARN] 检测到 http.sslverify=$SV（证书校验被关，有 MITM 风险）"
  echo "         建议执行: git config --global --unset http.sslverify"
fi

echo
echo "=== 5/5 验证（真实 ls-remote）==="
if git ls-remote --exit-code https://github.com/octocat/Hello-World.git HEAD >/dev/null 2>&1; then
  echo "  [OK]   验证通过：git 已能连通 GitHub"
  echo
  echo "=== 完成。以后梯子换端口时只需一条命令 ==="
  echo "  git config --global --replace-all 'http.https://github.com/.proxy' 'http://127.0.0.1:<新端口>'"
  exit 0
else
  echo "  [FAIL] 验证失败 —— 跑 scripts/diagnose.sh 看逐项细节"
  exit 1
fi
