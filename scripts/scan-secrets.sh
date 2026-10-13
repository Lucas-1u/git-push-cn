#!/usr/bin/env bash
# git-push-cn / 推送前密钥与隐私扫描（只读，不改任何文件、不发任何网络请求）
#
# 目的：在 git add / commit / push / gh api 之前，把不该出门的东西全找出来。
#
# 用法（在 Git Bash 里，仓库根目录下跑）:
#   bash scan-secrets.sh                    # 扫当前目录
#   bash scan-secrets.sh /path/to/repo      # 扫指定仓库
#
# 退出码: 0 = 没发现阻断项；1 = 有 [BLOCK] / [DANGER] 项，先解决再推
set -u

REPO="${1:-.}"
cd "$REPO" 2>/dev/null || { echo "目录不存在: $REPO"; exit 1; }

FAIL=0
hit()   { printf '  [BLOCK]  %s\n' "$1"; FAIL=1; }
risk()  { printf '  [DANGER] %s\n' "$1"; FAIL=1; }
warn()  { printf '  [WARN]   %s\n' "$1"; }
ok()    { printf '  [OK]     %s\n' "$1"; }

# 需要被 .gitignore 覆盖的高危路径/模式（用 git check-ignore 实测，不靠眼看）
SENSITIVE_PATTERNS=(
  ".env*" "*.env" ".env.local" ".env.production"
  "*.key" "*.pem" "*.p12" "*.pfx" "id_rsa" "id_ed25519"
  "credentials*" "credential*" "*.credentials"
  "token*" "*.token" "*_token.txt"
  "*.db" "*.sqlite" "*.sqlite3"
  "config.secret.*" "secrets.*"
)

echo "=== 仓库: $(pwd)"
echo

echo "=== 1/7 文件是否会被提交（git check-ignore 实测）==="
# 只有先确认是 git 仓库，这一节才有意义
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  warn "当前目录不是 git 仓库 —— 跳过 gitignore 检查，只做静态扫描"
else
  FOUND_ANY=0
  SEEN=""
  for pat in "${SENSITIVE_PATTERNS[@]}"; do
    # 找真实存在的敏感文件
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      rel="${f#./}"
      case "$rel" in .git/*) continue ;; esac
      # 模板/示例文件本来就该公开，跳过（.env.example / secrets.sample 等）
      case "$(basename "$rel")" in
        *.example|*.sample|*.template|*.dist|*.tpl) continue ;;
      esac
      # 去重：多个 pattern（.env* 与 *.env）会命中同一个文件
      case "|$SEEN|" in *"|$rel|"*) continue ;; esac
      SEEN="$SEEN|$rel"
      FOUND_ANY=1
      if git check-ignore -q "$rel" 2>/dev/null; then
        warn "已被忽略（安全）: $rel"
      else
        risk "敏感文件未被忽略，会被推上远端: $rel"
      fi
    done < <(find . -maxdepth 4 -name "$pat" -not -path './.git/*' 2>/dev/null | head -20)
  done
  [ "$FOUND_ANY" -eq 0 ] && ok "没发现常见的敏感文件名（.env / *.key / *.db 等）"

  # 已被 git 跟踪的历史文件（最危险：ignore 对已跟踪文件无效）
  echo
  echo "=== 2/7 已跟踪文件里有没有敏感文件 ==="
  TRACKED=$(git ls-files 2>/dev/null | grep -iE '(^|/)(\.env($|\.)|[^/]*\.(key|pem|p12|pfx|db|sqlite|sqlite3)$|credentials?[^/]*$|tokens?[^/]*$)' \
            | grep -viE '\.(example|sample|template|dist|tpl)$' || true)
  if [ -n "$TRACKED" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      risk "已被 git 跟踪（.gitignore 挡不住，必须 git rm --cached）: $f"
    done <<< "$TRACKED"
  else
    ok "git 跟踪的文件里没有敏感文件"
  fi
fi

echo
echo "=== 3/7 待提交清单（暂存区，人工过一遍）==="
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  STAGED=$(git diff --cached --name-only 2>/dev/null || true)
  if [ -n "$STAGED" ]; then
    N=$(printf '%s\n' "$STAGED" | wc -l | tr -d ' ')
    printf '  暂存区共 %s 个文件：\n' "$N"
    printf '%s\n' "$STAGED" | sed 's/^/    /'
    # 精确匹配 .env，避免误命中 .env.example
    if printf '%s\n' "$STAGED" | grep -qxE '.*/\.env|\.env'; then
      risk "暂存区里有 .env（精确匹配，非 .env.example）"
    fi
    if printf '%s\n' "$STAGED" | grep -qiE '\.(key|pem|p12|pfx|db|sqlite3?)$'; then
      risk "暂存区里有密钥/数据库类文件"
    fi
  else
    warn "暂存区为空（记得 commit 前先 git add，再用本节复查一遍）"
  fi
else
  warn "非 git 仓库，跳过"
fi

echo
echo "=== 4/7 源码里的硬编码密钥（只扫会被提交的文件）==="
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SCAN=$(git ls-files 2>/dev/null || true)
else
  SCAN=$(find . -type f -not -path './.git/*' 2>/dev/null | head -500)
fi
if [ -n "$SCAN" ]; then
  PATTERNS=(
    'sk-[A-Za-z0-9_-]{16,}'
    'ghp_[A-Za-z0-9]{20,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'AKIA[0-9A-Z]{16}'
    'LTAI[0-9A-Za-z]{10,}'
    'AIza[0-9A-Za-z_-]{30,}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    '[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]['"'"'"]?\s*[:=]\s*['"'"'"][^'"'"'"]{12,}'
    '["'"'"']?(api[_-]?key|secret|access[_-]?token|password|passwd|app[_-]?secret)["'"'"']?\s*[:=]\s*["'"'"'][^"'"'"']{12,}["'"'"']'
  )
  FOUND=0
  for p in "${PATTERNS[@]}"; do
    # 排除模板/示例文件，避免噪声
    HITS=$(printf '%s\n' "$SCAN" | grep -vE '\.(example|sample|template|md|lock|min\.js)$|example/|sample/' \
           | tr '\n' '\0' | xargs -0 -r grep -lEI "$p" 2>/dev/null || true)
    if [ -n "$HITS" ]; then
      FOUND=1
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        risk "疑似硬编码密钥: $f  （模式: $p）"
        grep -nEIo "$p" "$f" 2>/dev/null | head -3 | sed 's/^/             /'
      done <<< "$HITS"
    fi
  done
  [ "$FOUND" -eq 0 ] && ok "没扫到常见格式的硬编码密钥"
fi

echo
echo "=== 5/7 隐私：服务器 IP / 域名 / 本地绝对路径 ==="
FOUND5=0
if [ -n "$SCAN" ]; then
  # 公网 IP（排除常见私有段与版本号）
  IPHITS=$(printf '%s\n' "$SCAN" | grep -vE '\.(md|lock)$' | tr '\n' '\0' \
           | xargs -0 -r grep -lEI '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' 2>/dev/null || true)
  for f in $IPHITS; do
    L=$(grep -nEIo '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$f" 2>/dev/null \
        | grep -vE '\b(0\.0\.0\.0|127\.0\.0\.1|255\.255\.255\.255|1\.2\.3\.4)\b' \
        | grep -vE '\b(10|172|192|169)\.' \
        | grep -vE '\b(123\.45\.67\.89|1\.1\.1\.1|8\.8\.8\.8|114\.114\.114\.114|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)\b' \
        | head -3 || true)
    if [ -n "$L" ]; then
      FOUND5=1
      risk "疑似硬编码 IP（文档占位符如 123.45.67.89 已排除）: $f"
      printf '%s\n' "$L" | sed 's/^/             /'
    fi
  done
  [ "$FOUND5" -eq 0 ] && ok "没扫到可疑的硬编码公网 IP"
fi

echo
echo "  本地绝对路径（会暴露 Windows 用户名）——"
PATHHITS=$(printf '%s\n' "$SCAN" | grep -vE '\.(md|lock)$' | tr '\n' '\0' \
           | xargs -0 -r grep -lEI 'C:\\+Users\\+[A-Za-z0-9._-]+|/c/Users/[A-Za-z0-9._-]+|C:/Users/[A-Za-z0-9._-]+' 2>/dev/null || true)
if [ -n "$PATHHITS" ]; then
  warn "以下文件含本地绝对路径（若仓库公开，建议替换为占位符）："
  printf '%s\n' "$PATHHITS" | head -10 | sed 's/^/             /'
else
  ok "没扫到本地绝对路径"
fi

echo
echo "=== 6/7 .gitignore 是否覆盖了项目里真实存在的大目录 ==="
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -f .gitignore ]; then
  MIss=0
  for d in data uploads backups backup logs *.bak-* .claude; do
    [ -e "$d" ] || continue
    if git check-ignore -q "$d" 2>/dev/null; then
      ok "$d 已被忽略"
    else
      MIss=1
      warn "$d 存在且未被忽略 —— 确认是否真的要公开（历史上 data/ 曾被漏掉）"
    fi
  done
  [ "$MIss" -eq 0 ] && ok "常见数据/备份目录都在忽略范围"
else
  warn "没有 .gitignore，或不是 git 仓库 —— 强烈建议先建 .gitignore"
fi

echo
echo "=== 7/7 全局自检 ==="
# .env 是否被精确覆盖（grep "^\.env" 会误命中 .env.example，所以用 check-ignore 逐文件测）
if [ -f .env ]; then
  if git check-ignore -q .env 2>/dev/null; then ok ".env 已被忽略"; else risk ".env 存在且未被忽略"; fi
fi
if [ -d .git ]; then
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | grep -iE '\.(env|key|pem|db)$' || true)
  if [ -n "$UNTRACKED" ]; then
    warn "工作区有未跟踪但未被忽略的敏感文件（一旦 git add -A 就会被带上）："
    printf '%s\n' "$UNTRACKED" | head -10 | sed 's/^/             /'
  else
    ok "没有「未忽略 + 敏感」的游离文件"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "=== 结论：未发现阻断项。推送前仍请人工过一遍第 3 节的暂存区清单 ==="
else
  echo "=== 结论：存在 [BLOCK] / [DANGER] 项 —— 先处理完再推 ==="
  echo "    （已被跟踪的敏感文件：git rm --cached <文件>，再写进 .gitignore）"
fi
exit "$FAIL"
