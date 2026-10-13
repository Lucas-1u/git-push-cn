# git-push-cn

> 国内网络 + Windows 环境下，让 `git push / pull / clone / fetch` 稳定连通 GitHub，
> 并在**推送前**扫描密钥与隐私泄露。

[![Platform](https://img.shields.io/badge/platform-Windows-0078D4)](#)
[![Shell](https://img.shields.io/badge/shell-bash%20%2F%20Git%20Bash-4EAA25)](#)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**语言 / Language：** 简体中文 | [English](README.en.md)

---

## 这是一个通用 Agent Skill

本仓库是一份**面向任意 AI Agent 的 Skill** —— 不绑定某个特定平台或客户端。
只要你的 agent 有读文件 + 跑 shell 的能力，它就能用。

**推荐用法：先让你的 agent 通读一遍，再决定要不要改造。**

把这个目录交给你的 agent（放在它的 skill / 规则 / 知识库目录下，或直接指出路径），
让它读一遍 `SKILL.md`，然后由它自己判断：

- 哪些诊断项在这台机器上不适用？（比如 macOS 用的是 Secure Transport 而非 schannel）
- 哪些路径 / 端口 / 命令需要替换成本机实际情况？
- 要不要把这些内容改写成它自己最擅长的形态（规则文件、工具描述、工作流编排……）？

> 换句话说：**这份 skill 的默认形态是"一份写得足够细的说明书"，
> 而不是"一套必须原样照抄的代码"。** 它自带大量真实案例和踩坑记录 ——
> 那些是知识，不是教条。你的 agent 读完再裁，通常比直接照搬效果更好。

目录里的三个 shell 脚本**也可以完全脱离 AI 单独用** —— 你完全可以只 `git clone` 下来，
在 Git Bash 里手动跑。两条路都通。

```
git-push-cn/
├── SKILL.md                    # 主文档：诊断表 + 修复步骤 + 硬性禁忌
├── README.md                   # 你正在看的这份（中文）
├── README.en.md                # 英文版
├── LICENSE                     # MIT
├── scripts/
│   ├── diagnose.sh             # 一键诊断连通性，逐项 ✅/❌
│   ├── setup.sh                # 一键配置（per-URL 代理 + gh 凭据），幂等
│   └── scan-secrets.sh         # 推送前密钥 / 隐私扫描，只读
└── references/
    ├── troubleshooting.md      # 完整排错树、SSH 方案、TUN 模式、真实案例
    └── api-fallback.md         # 梯子全挂时的 GitHub API 直传兜底
```

---

## 它解决什么问题

最常见的那个问题：**"我梯子明明开着，为什么 git 推不上去？"**

因为 **Git for Windows 不读 Windows 系统代理**。

| 梯子模式 | 谁受影响 | git 能用吗 |
|---|---|---|
| 系统代理（注册表 `ProxyEnable=1`） | 浏览器、部分 App | ❌ **git 不读这个** |
| 路由规则"全局模式" | 只决定"走不走代理" | ❌ 它不负责把流量**交给**代理 |
| **TUN 模式**（虚拟网卡） | 所有程序 | ✅ 真正接管全部流量 |
| **显式告诉 git** | git 自己 | ✅ `http.proxy` 配置 或 `http_proxy` 环境变量 |

git 用的 libcurl 只认后两样。要么给它显式配代理（本 skill 的主方案），
要么让梯子开 TUN 模式。

> 顺带一提：`github.com` 的封锁是**间歇性**的。同一个晚上可能 22:20 直连被 reset、
> 22:55 又通了。所以**不要因为一次测通就删掉配置** —— 配置留着无害，墙恢复时才是刚需。

---

## 覆盖的症状

| 报错 / 现象 | 真正原因 |
|---|---|
| `schannel: failed to receive handshake` | `github.com:443` 被重置，git 没吃到代理 |
| `schannel: server closed abruptly` | 同上 |
| `Recv failure: Connection was reset` | 同上 |
| `Failed to connect to github.com:443 after 21045 ms` | 直连被墙且无代理 |
| `CONNECT tunnel failed, response 502` | 在带沙箱代理的 agent 环境里（沙箱代理挡了 github.com） |
| `could not read Username for 'https://github.com'` | 凭据助手（GCM）里没有 github 凭据 |
| **退出码 0 但远端没变化** | 静默失败 —— 别信退出码 |
| `CRYPT_E_NO_REVOCATION_CHECK` | Windows schannel 查 CRL 失败 |

完整的「症状 → 病因 → 处理」对照表见 [`SKILL.md`](SKILL.md)。

---

## 快速开始

**要求：** Windows + [Git for Windows](https://git-scm.com/download/win)（脚本在 Git Bash 里跑）。
推送到私有仓库还需要 [`gh`](https://cli.github.com/) 登录。

### 1. 诊断（30 秒，只读）

```bash
bash scripts/diagnose.sh            # 自动探测梯子端口
bash scripts/diagnose.sh 7891       # 或手动指定端口
```

它会逐项打 ✅/❌：梯子端口 → git 三项配置 → 经梯子访问 github → git 读 → git 写（dry-run）。

### 2. 修复（幂等，可反复跑）

```bash
bash scripts/setup.sh
```

做三件事：① **先实测该端口能连通 github 才写入配置**；② 写 **per-URL 代理**；
③ `gh auth setup-git` 接上凭据；最后跑一次真实 `ls-remote` 验证。

> **为什么是 per-URL 而不是全局 `http.proxy`**：全局写法在梯子关闭 / 换端口时会把
> **所有** git 操作（含 gitee、内网仓库）一起搞死。per-URL 只影响 `github.com`，
> 最坏情况也只是 github 不通，与没配时等价。

### 3. 推送前扫描（**不可跳过**）

```bash
bash scripts/scan-secrets.sh
```

**退出码 0 = 没有阻断项；1 = 有 `[DANGER]`，先处理完再推。**

扫描 7 段内容：敏感文件是否被忽略 → 已跟踪的敏感文件 → 暂存区清单 →
硬编码密钥 → IP / 域名 / 本地路径隐私 → 大目录覆盖 → 全局自检。
**纯只读，不发任何网络请求。**

---

## 手动配置（等价于 setup.sh）

```bash
# 1) 代理：只对 github.com 生效（关键：别用全局 http.proxy）
git config --global --replace-all 'http.https://github.com/.proxy' 'http://127.0.0.1:7890'

# 2) 凭据：让 gh 提供 github 凭据（不配会报 could not read Username）
gh auth setup-git

# 3) 验证
git ls-remote --exit-code https://github.com/octocat/Hello-World.git HEAD && echo OK
```

梯子换端口后，只需重跑第 1 条、把端口换成新的。

---

## 🔴 推送前请记住

这个 skill 里**唯一"犯了就不可逆"的错误**是密钥泄露 ——
网络报错重试就好，密钥推到公开仓库会**立刻被爬虫抓走**，删了也来不及。

- **`.env` 及等价物一律不得进版本库。** 包括 `*.key` / `*.pem` / `*.p12` /
  `credentials*` / `token*` / `*.db`。
  但 `*.example` / `*.sample` / `*.template` 是**给人看的占位模板，理应提交** ——
  别把它们一起"保护"掉，否则新人拿到仓库不知道该配什么。
- **不能只靠 `.gitignore` 眼过一遍**，要用 `git check-ignore` 实测。
  更隐蔽的坑：**已被 git 跟踪过的文件，之后再加进 `.gitignore` 是无效的**，
  必须 `git rm --cached <文件>`。
- **`git add -A` 是高风险动作**，尤其在项目根目录跑。宁可 `git add <具体路径>`。
- **推完必须反查远端** —— 那份文件清单才是真正公开的东西：
  ```bash
  gh api repos/<owner>/<你的仓库>/git/trees/main?recursive=1 --jq '.tree[].path'
  ```
- **万一已经推上去了 —— 顺序不能错：先吊销密钥，再清理历史。**
  只删文件再 commit 是没用的，密钥还留在 `git log -p` 里。但只要密钥没吊销，
  清历史就是白费功夫。

---

## 三条路线怎么选

| 路线 | 依赖梯子 | 能力 | 何时用 |
|---|---|---|---|
| **HTTPS + per-URL 代理** | 是（梯子常开） | push / pull / clone 全功能 | 默认方案 |
| **SSH** | **否**（`github.com:22` 与 `ssh.github.com:443` 直连可达） | 全功能 | 想彻底摆脱梯子 → `references/troubleshooting.md` |
| **API 直传** | 否（走 `api.github.com`） | 只能传文件，**不能 clone/pull** | 梯子挂了、沙箱里、临时改一两个文件 → `references/api-fallback.md` |

更省心的替代：把梯子切到 **TUN 模式** —— git 零配置，且 pip / npm / python 等
所有不认系统代理的工具一起治好。

---

## 硬性禁忌

- ❌ **别设 `http.sslverify=false`** —— 那是关掉 HTTPS 证书校验，会暴露 token 给中间人。
  真遇到吊销检查报错就用 `http.schannelCheckRevoke=false`（**只关吊销检查**）。
- ❌ **别用全局 `http.proxy`** —— 梯子一挂，所有 git 操作（含国内仓库）全部失败。
- ❌ **别把 token 写进 remote URL**（`https://<token>@github.com/...`）——
  会落进 `.git/config` 和 shell history。用 `gh auth setup-git`。
- ❌ **别相信 push 的退出码** —— 用 `git rev-parse HEAD` 对比 `origin/main`，
  或看 `.git/logs/refs/remotes/origin/main` 里有没有 `update by push`。

---

## 怎么装到你的 agent 上

没有一个"标准路径"—— 各家 agent 放 skill 的位置都不一样。通用做法：

```bash
# 1) 先 clone 到一个顺手的目录
git clone https://github.com/Lucas-1u/git-push-cn.git ~/git-push-cn

# 2) 再按你的 agent 的要求放（常见几种，选一个）
#    Claude Code / WorkBuddy 一类：<配置目录>/skills/git-push-cn/
#    Cursor / Windsurf 一类：写进 .cursor/rules/ 或项目根的规则文件
#    ChatGPT / Claude 网页版：把 SKILL.md 正文贴进项目知识库，脚本单独上传
#    自建 agent：直接把目录路径喂给它，让它自己读
```

**不确定该怎么放？直接问你的 agent。** 把 clone 路径告诉它，让它自己看目录结构、
判断该把哪几个文件放在哪里 —— 它比自己瞎猜准。

装好后，触发场景包括：push 报 schannel / TLS 握手失败 / Connection was reset、
`could not read Username`、退出码 0 但远端没变化、准备把仓库推上 GitHub 前检查会不会泄露。

---

## License

[MIT](LICENSE) © 2026 Lucas-1u
