---
name: git-push-cn
description: "国内网络 + Windows 环境下让 git 稳定连通 GitHub（push / pull / clone / fetch），并在推送前做密钥与隐私扫描。触发场景：git push 报 schannel / TLS 握手失败 / Connection was reset / Failed to connect；报 could not read Username （terminal prompts disabled）；push 退出码为 0 但远端没变化（静默失败）；梯子开着但 git 推不上去；给新项目接 GitHub 远端；需要判断该走代理、SSH 还是 API 直传；准备把仓库推上 GitHub（尤其公开仓库）前检查 .env / API Key / 数据库 / 服务器 IP / 本地绝对路径会不会泄露。"
description_zh: "国内网络下 git 连通 GitHub 的诊断 / 配置 / 推送前防泄漏手册"
description_en: "Make git push/pull/clone work against GitHub behind the GFW on Windows, and scan for leaked secrets before pushing"
version: 1.2.0
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# 国内网络下让 git 连通 GitHub

面向任意 AI Agent 的通用 Skill，不绑定特定平台。**你的 agent 应该先读完这一份，再决定要不要按本机情况改造。**

## 先确认三件事（大多数问题卡在这里）

排查任何报错之前，先看这三条配置在不在：

| 项 | 应有值 | 命令 |
|---|---|---|
| github 专用代理 | `http://127.0.0.1:7890`（换成你的梯子端口） | `git config --get 'http.https://github.com/.proxy'` |
| 凭据助手 | 指向 gh | `git config --get-all 'credential.https://github.com.helper'` |
| 证书校验 | **未设置**（= 默认开启） | `git config --get http.sslverify` |

三条都正常却还是推不上去 → 跳到「症状 → 病因 对照表」。
任一条不对 → 直接跑「一键修复」。

---

## 🔴 第 0 步（不可跳过）：推送前密钥与隐私扫描

**这是本 skill 里唯一"犯了就不可逆"的错误** —— 网络问题重试就好，密钥推到公开仓库会立刻被爬虫抓走，删了也来不及。

**任何 `git push` / `gh api` 上传之前，必须先跑：**

```bash
bash scripts/scan-secrets.sh           # 扫当前仓库
bash scripts/scan-secrets.sh <目录>    # 扫指定仓库
```

**退出码 0 = 没有阻断项；1 = 有 `[DANGER]`，必须先处理完再推。**

### 硬性要求（写死，无例外）

1. **`.env` 及其等价物一律不得进入版本库。**
   包括 `.env`、`.env.local`、`.env.production`、`*.key`、`*.pem`、`*.p12`、
   `credentials*`、`token*`、`*.db` / `*.sqlite`。
   > 但 `*.example` / `*.sample` / `*.template` / `*.dist` 是**给人看的占位模板**，理应提交 —— 别把它们一起"保护"掉，否则新人拿到仓库不知道该配什么。

2. **不能只靠 `.gitignore` 眼过一遍 —— 要用 `git check-ignore` 实测。**
   经典翻车：`.gitignore` 挡住了 `.env` / `*.db`，却**漏了 `data/`（几十 MB，含用户数据分片）**。
   还有更隐蔽的：**已经被 git 跟踪过的文件，之后再加进 `.gitignore` 是无效的**，必须 `git rm --cached <文件>`。
   > 精确匹配坑：`grep "^\.env"` 会**误命中 `.env.example`**，别用它判断 `.env` 有没有被忽略。

3. **提交前必须人工过一遍暂存区清单。**
   ```bash
   git add -A
   git diff --cached --name-only      # ← 睁眼看这份清单，别直接 commit
   ```
   脚本会给出来，但**最终判定必须是人看一眼**：数量对不对？有没有多出不该有的目录？

4. **`git add -A` 是高风险动作**，尤其在项目根目录跑。
   宁可 `git add <具体路径>`。跑之前先确认工作区没有游离的 `.env` / 数据库 / 备份文件。

5. **公开仓库推送前，扫服务器 IP / 域名 / 本地绝对路径。**
   - 服务器 IP（如 `<你的服务器 IP>`）
   - 私有域名（会暴露站点归属）
   - `C:\Users\<用户名>` / `/c/Users/<用户名>`（暴露 Windows 用户名）
   - 真实姓名 / 学号 / 手机号 / 邮箱
   > 文档里 `123.45.67.89` 这类**占位符**是安全的，脚本已排除；真 IP 必须替换成 `<your-server-ip>`。

6. **不能只看本地 —— 推完必须反查远端。**
   ```bash
   gh api repos/<owner>/<repo>/git/trees/main?recursive=1 --jq '.tree[].path'
   ```
   这个清单才是**真正公开的东西**。脱敏、漏传、传错都在这一步暴露。

### 万一已经推上去了

**顺序不能错**：先**吊销密钥**（去服务商后台重置 / 删除 API Key），再清理仓库历史。
只删文件再 commit 是**没用的** —— 密钥还留在 git 历史里，`git log -p` 一翻就见。
清理历史要用 `git filter-repo` 或 BFG，改完还得强推。**但只要密钥没吊销，清历史就是白费功夫。**

> 补充：**改成私有仓库也不够** —— fork 出来的副本、爬虫缓存、CI 日志都还在。

### 别把密钥直接贴进对话 / 命令行

`git push` 到含 token 的 URL（`https://<token>@github.com/...`）会把凭据写进
`.git/config` 和 shell history；用 `gh` 的凭据助手（`gh auth setup-git`，见下方配置）就不会有这个问题。
同理，**别把 API Key 原文贴进聊天窗口**——它是会被记录下来的。

---

## 核心原理（一句话）

**Git for Windows 不读 Windows 系统代理，也不吃梯子的"全局模式"。**

梯子开"系统代理"（注册表 `ProxyEnable=1`）只有浏览器认；"全局模式"改的是**路由规则**，不等于**接管流量**。
git 用的 libcurl 只认两样东西：`http_proxy` 环境变量，或 git 自己的 `http.proxy` 配置。

→ 所以"我梯子开着，为什么 git 推不上去"的根因就是这个。要么给 git 显式配代理，要么让梯子开 **TUN 模式**（虚拟网卡真接管全部流量）。

> **注意：`github.com` 的封锁是间歇性的。** 同一个晚上可能"22:20 直连被 reset、22:55 直连又通了"。
> 所以**不要因为一次测通了就删掉配置**，也不要因为用户说"之前明明能推"就否定诊断结论。配置留着无害，墙恢复时才是刚需。

---

## 30 秒诊断

```bash
bash scripts/diagnose.sh              # 自动探测端口，逐项打 ✅/❌
bash scripts/diagnose.sh 7891         # 也可手动指定端口
```

诊断项：梯子端口 → git 三项配置 → 经梯子访问 github → git 读 → git 写（dry-run）。

## 一键修复

```bash
bash scripts/setup.sh                 # 自动探测端口 + 配置 + 验证
bash scripts/setup.sh 7891            # 指定端口
```

它做三件事：① 先实测该端口能连通 github 才写入配置；② 写 **per-URL 代理**；
③ `gh auth setup-git` 接上凭据；最后跑一次真实 `ls-remote` 验证。

## 手动配置（等价于上面脚本）

```bash
# 1) 代理：只对 github.com 生效（关键：别用全局 http.proxy）
git config --global --replace-all 'http.https://github.com/.proxy' 'http://127.0.0.1:7890'

# 2) 凭据：让 gh 提供 github 凭据（不配会报 could not read Username）
gh auth setup-git

# 3) 验证
git ls-remote --exit-code https://github.com/octocat/Hello-World.git HEAD && echo OK
```

> **为什么用 per-URL 而不是全局 `http.proxy`**：全局写法在梯子关闭/换端口时会把**所有** git 操作
> （含 gitee、内网仓库）一起搞死 —— 死代理配置可能悄悄遗留数周，直到你发现连公司仓库都拉不动。
> per-URL 只影响 github.com，最坏情况也只是 github 不通，与没配时等价。

---

## 症状 → 病因 对照表

| 报错 / 现象 | 真正原因 | 处理 |
|---|---|---|
| `schannel: failed to receive handshake` | `github.com:443` 被重置，git 没吃到代理 | 配 per-URL 代理 |
| `schannel: server closed abruptly (missing close_notify)` | 同上 | 同上 |
| `Recv failure: Connection was reset` | 同上 | 同上 |
| `Failed to connect to github.com:443 after 21045 ms` | 直连被墙且无代理 | 同上 |
| `CONNECT tunnel failed, response 502` | 在带沙箱代理的 agent 环境里（沙箱代理挡了 github.com） | 配 per-URL 代理（**config 优先级高于环境变量**），或临时 `env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY` |
| `could not read Username for 'https://github.com'` | 凭据助手（GCM）里没有 github 凭据 | `gh auth setup-git` |
| **退出码 0 但远端没变化** | 静默失败 | 别信退出码，见下方"怎么确认真的推上去了" |
| `CRYPT_E_NO_REVOCATION_CHECK` / 证书吊销检查失败 | Windows schannel 查 CRL 失败 | `git config --global http.schannelCheckRevoke false`（**只关吊销检查**） |
| 换了梯子端口后突然全挂 | 配置里端口是旧的 | `--replace-all 'http.https://github.com/.proxy' 'http://127.0.0.1:<新端口>'` |

---

## 怎么确认"真的推上去了"

**不要相信退出码**（会静默失败，退出码 0 但远端没变）。

```bash
git rev-parse HEAD            # 本地
git rev-parse origin/main     # 远端跟踪（先 git fetch）
```

**更可靠的判读 —— 看远端跟踪日志**：

```bash
cat .git/logs/refs/remotes/origin/main
#   update by push            ← 真的推上去了
#   fetch origin: fast-forward ← 是从远端拉下来的
```

> 结论：**内容没有变化的 push 不会写日志**，所以看到 `update by push` 一定是真推送成功。

**最强验证（端到端，含对象上传）**——造一个零改动临时 commit 推上去再删：

```bash
C=$(git commit-tree HEAD^{tree} -p HEAD -m "connectivity test")
git push origin "$C:refs/heads/__conn_test__"
gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/__conn_test__
```

（`--dry-run` 不走对象上传，只验证认证链路；上面这条才是全链路。）

---

## 三条路线怎么选

| 路线 | 依赖梯子 | 能力 | 何时用 |
|---|---|---|---|
| **HTTPS + per-URL 代理** | 是（梯子常开） | push / pull / clone 全功能 | 默认方案，即本手册主体 |
| **SSH** | **否**（`github.com:22` 与 `ssh.github.com:443` 直连可达） | 全功能 | 想彻底摆脱梯子；详情见 `references/troubleshooting.md` |
| **API 直传** | 否（走 api.github.com） | 只能传文件，**不能 clone/pull** | 梯子挂了、沙箱里、临时改一两个文件；详见 `references/api-fallback.md` |

更省心的替代：把梯子切到 **TUN 模式** —— git 零配置，且 pip / npm / python 等所有不认系统代理的工具一起治好。

---

## 硬性禁忌

- 🔴 **别让 `.env` / 密钥 / 数据库文件出门**：这是唯一不可逆的错误，网络报错能重试，密钥泄露不能。分不清就**先跑 `scripts/scan-secrets.sh`**。已在远端 → **先吊销密钥**，再清历史。
- ❌ **别设 `http.sslverify=false`**：那是关掉 HTTPS 证书校验，会暴露 token 给中间人。真遇到吊销检查报错就用 `http.schannelCheckRevoke=false`（只关吊销检查）。
- ❌ **别用全局 `http.proxy`**：梯子一挂，所有 git 操作（含国内仓库）全部失败。用 per-URL。
- ❌ **别把 token 写进 remote URL**（`https://<token>@github.com/...`）：会落进 `.git/config`。用 `gh auth setup-git`。
- ❌ **别相信 push 的退出码**：用 `rev-parse` 或 reflog 判读。

---

## 给 agent 的改造建议

这份 skill 的默认形态是**一份写得足够细的说明书**，不是必须照抄的代码。装好之后建议按本机情况过一遍：

| 检查项 | 为什么 |
|---|---|
| 代理端口 | `7890` 是 Clash 系默认值。用 v2ray / sing-box 的话常见是 `10808` / `10809`。`scripts/diagnose.sh` 会自动探测一批常见端口 |
| 是否为 Windows | 本文的 `schannel` / `CRL` / `C:\Users` 相关内容是 Windows 专属。macOS 用 Secure Transport、Linux 用 OpenSSL，报错文本和排查路径都不同 |
| 报告语言 | `scripts/` 里的输出目前是中文。要英文输出的话直接改脚本里的 `echo` 文案 |
| 是否需要梯子 | 如果目标环境本身能直连 GitHub（比如境外 CI），本 skill 的网络部分可以整个跳过，只保留第 0 步的扫描 |
| 凭据方式 | 本手册推荐 `gh auth setup-git`。如果环境里没有 `gh`，可以换成 GCM（Git Credential Manager）或 SSH key |

> 改之前建议先原样跑一遍 `scripts/diagnose.sh`，把本机的真实状态记下来 ——
> 有基线才知道自己改对了没有。

---

## 资源

- `scripts/scan-secrets.sh` —— **推送前安全扫描**（7 段：敏感文件是否被忽略 / 已跟踪的敏感文件 / 暂存区清单 / 硬编码密钥 / IP+路径隐私 / 大目录覆盖 / 全局自检），只读、不发网络请求
- `scripts/diagnose.sh` —— 一键诊断连通性，逐项 ✅/❌（跑之前不用读，直接执行）
- `scripts/setup.sh` —— 一键配置 + 验证（幂等，可反复跑）
- `references/api-fallback.md` —— 梯子彻底不通时的 API 直传兜底（单文件 / 批量 / 整仓 Git Data API，含对齐流程）
- `references/troubleshooting.md` —— 完整排错树、SSH 方案细节、沙箱注意事项、真实案例
