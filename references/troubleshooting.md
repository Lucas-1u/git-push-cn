# 排错细节 / 备选路线 / 历史案例

## 0. 原理：为什么"梯子开着"却推不上去

Windows 上流量进梯子有三条路，**只有后两条对 git 有效**：

| 梯子工作模式 | 谁受影响 | git 能用吗 |
|---|---|---|
| 系统代理（注册表 `HKCU\...\Internet Settings` 的 `ProxyEnable=1` / `ProxyServer`） | 浏览器、部分 App | ❌ **Git for Windows 不读这个设置** |
| 路由规则"全局模式" | 只是决定"走不走代理" | ❌ 它不负责把流量**交给**代理 |
| **TUN 模式**（虚拟网卡） | 所有程序 | ✅ 真正接管全部流量 |
| 显式告诉 git | git 自己 | ✅ `http.proxy` 配置 或 `http_proxy` 环境变量 |

**结论**：要么给 git 显式配代理（本手册主方案），要么让梯子开 TUN 模式。

> 排查时容易误判：用户看到浏览器能上 GitHub，就以为"梯子没问题"。
> 但对 git 来说梯子等于不存在——这两个是**独立**的。判断依据请看 `diagnose.sh` 的 2/5 与 3/5 段。

### ⚠️ 封锁是**间歇性**的，别被单次结果骗了（2026-10-13 实测）

同一个晚上、同一台机器、同一份网络配置，`github.com` 直连的表现前后矛盾：

| 时刻 | 直连 github.com | 说明 |
|---|---|---|
| 22:20 | ❌ `Connection was reset` | git push 失败，排查由此开始 |
| 22:55 | ✅ HTTP 200 | 同一台机器，什么都没改 |

用出口 IP 交叉验证过（`api.ip.sb/ip` 直连 `58.48.235.73` vs 经代理 `142.202.242.194`，**IP 不同 → 确实是真直连**，不是 TUN 在接管）。

**结论**：
- 判断"能不能推"不能靠一次测试，**配置要留着**——直连能通时它无害，墙恢复时它就是救命的。
- 用户说"之前明明能推"和"现在推不了"可能**都成立**，不要据此否定配置。
- 真正的稳定解是：显式配置代理（本手册）或走 SSH（第 2 节）。

---

## 1. 完整排错顺序

```
git push 失败
├─ 报 CONNECT tunnel failed / 502 ?
│   → 在带沙箱代理的 agent 环境里（沙箱代理挡了 github.com）
│   → 配 per-URL 代理即可（git config 优先级高于环境变量）
│   → 或临时: env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY <命令>
│
├─ 报 schannel / Recv failure / Failed to connect ?
│   → github.com:443 被重置。查 git config --get 'http.https://github.com/.proxy'
│   → 没配就配；配了但端口不是梯子当前端口就改
│
├─ 报 could not read Username ?
│   → 凭据问题，不是网络问题。gh auth setup-git
│   → 若 gh 未登录：gh auth login
│
├─ 退出码 0 但远端没变 ?
│   → 静默失败。用 git rev-parse HEAD / origin/main 或 .git/logs/refs/remotes/origin/main 判读
│   → 看到 update by push 才是真推上去了
│
└─ 都配了还是不行 ?
    ├─ 检查梯子节点（curl -x http://127.0.0.1:<port> https://github.com 要 200）
    ├─ 换节点 / 换端口
    └─ 全都不行 → 走 SSH（见下）或 API 直传（见 api-fallback.md）
```

---

## 2. SSH 路线（不依赖梯子）

**为什么可行**：实测 `github.com:22` 与 `ssh.github.com:443` 都能**直连**握手成功
（返回 `Permission denied (publickey)` 就代表通道正常，只差一个 key 登记）。
被墙/被重置的只是 `github.com:443` 的 HTTPS。

```bash
# 自检（看到 Permission denied (publickey) 就是通的）
ssh -T git@github.com
ssh -T -p 443 git@ssh.github.com
```

**本机现状**：已存在免密私钥 `~/.ssh/id_ed25519`（2026-09-17 生成，原给阿里云服务器用），
但**尚未登记到 GitHub 账号**。登记有两条路：

### (a) Deploy key —— 纯 API，不用打开网页

```bash
# 把公钥挂到某个仓库上（需要 token 有 repo scope）
gh api -X POST repos/<owner>/<repo>/keys \
  -f title="local-dev" \
  -f key="$(cat ~/.ssh/id_ed25519.pub)" \
  -F read_only=false
```

然后换 remote：

```bash
git remote set-url origin git@github.com:<owner>/<repo>.git
ssh -T git@github.com        # 应显示 Hi <owner>/<repo>! You've successfully authenticated
git push
```

- 优点：**不需要梯子**，不需要浏览器，一条命令。
- 缺点：**一仓一 key**，每建一个新仓库都要重复一次。

### (b) 账号级 key —— 一次配置，所有仓库通用

需要 `admin:public_key` scope，而加权限要走 device flow（浏览器打开 `github.com/login/device` 输验证码），
所以**必须先能访问 github.com**（梯子在跑就行）：

```bash
gh auth refresh -h github.com -s admin:public_key     # 按提示在浏览器输验证码
gh ssh-key add ~/.ssh/id_ed25519.pub --title "laptop"
```

---

## 3. 更省心的替代：TUN 模式

把梯子切到 TUN 模式（虚拟网卡接管全部流量）后：

- git 零配置即可用（可以顺手删掉 per-URL 代理配置）
- pip / npm / conda / python requests 等**所有不认系统代理的工具**一起治好
- 梯子关闭时自动回落到直连，不会留下"死代理"配置

代价：需要管理员权限装虚拟网卡驱动；个别软件可能冲突。

---

## 4. 沙箱环境注意事项

不少 agent 运行时（含各类云端 IDE、托管 agent 平台）会给 shell 注入一个**沙箱代理**，
通常形如 `http_proxy=http://127.0.0.1:<port>`。它**会挡 github.com**，于是：

- **现象**：`CONNECT tunnel failed, response 502` —— 这是沙箱代理拒绝了 CONNECT，
  不是你本机网络有问题。**别去调证书或 TLS 设置，方向是错的。**
- **`git config` 的 `http.proxy` 优先级高于环境变量** → 只要配了 per-URL 代理，
  沙箱里 git 也能正常联网（已实测）。这是首选解法。
- **临时绕过**：把代理环境变量临时清掉再跑单条命令 ——
  `env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY <命令>`。
  注意这只对那一条命令生效。
- 沙箱里 `curl` 测**真实直连**要加 `--noproxy '*'`，否则它走的是沙箱代理，
  你测到的是代理而不是直连 —— 结论会完全反过来。
- **SSH 是非 HTTP 通道**，沙箱里可能被直接拦掉（需要用户授权）。
  你自己的终端不受这个限制，可以在本机终端里走 SSH 路线。

---

## 5. 判读"push 到底成没成"（附实测依据）

| 观察 | 含义 |
|---|---|
| `.git/logs/refs/remotes/origin/main` 出现 `update by push` | ✅ 真的推上去了 |
| 同一文件出现 `fetch origin: fast-forward` | 是从远端**拉下来**的，不是本地推的 |
| `git push` 输出 `Everything up-to-date` | 认证链路通，只是没有新内容 |
| 退出码 0 | ⚠️ 不可信，**必须**用上面两条交叉确认 |

> 实测依据（2026-10-13）：另建测试仓库验证过——**内容无变化的 push 不会写任何 reflog 条目**，
> 所以 reflog 里的 `update by push` 一定是真实的对象+引用更新。

判断某个 commit 是"push 上去的"还是"API 在远端建的"，看作者邮箱：
- 本地 git 配置的身份（如 `265476920+<user>@users.noreply.github.com`）→ 是 push 上去的
- 账号邮箱 / GitHub display name → 是 API 在远端创建的 commit

---

## 7. 密钥泄露了怎么办（顺序不能错）

**核心原则：先吊销，后清理。** 弄反了就是白忙。

### 为什么"删文件再 commit"没用

git 是内容寻址的快照系统，`git rm .env` + commit 只是在新快照里删掉了它 —— **旧快照里那份 `.env` 原封不动地留在历史里**。
任何人 `git log -p --all -- .env` 或 `git cat-file` 就能翻出来。同理，**仅仅改成私有仓库也不够**（fork 出来的副本、爬虫缓存、CI 日志都还在）。

### 正确的处置顺序

```
① 立刻吊销密钥（最优先，做完这一步损失才止住）
   ├─ 云厂商控制台 → 删除 / 重置该 API Key
   ├─ 数据库密码 → 改密码
   ├─ 云服务器密钥对 → 换 key
   └─ 千万别跳过这步去做清理历史，那是自我安慰

② 评估暴露面
   ├─ 仓库是公开的吗？公开了多久？（GitHub 上公开 = 已被爬虫抓走，默认按"已泄露"处理）
   ├─ 有没有大模型/爬虫会把公开仓库训练进语料？（是的，所以更要吊销）
   └─ 看 GitHub 的 Security → Secret scanning alerts（公开仓库免费自动开）

③ 清理历史（只在 ① 完成后做，且需要协作说明）
   pip install git-filter-repo        # 比 git filter-branch 快几个数量级
   git filter-repo --path .env --invert-paths --path data/ --invert-paths
   # 然后所有人都要重新 clone（历史被重写了，不能简单 pull）

④ 善后
   ├─ 确认 .env 已进 .gitignore（用 git check-ignore 实测）
   ├─ 补一个 .env.example 说明需要哪些变量（不含真值）
   └─ 如果历史里有其他敏感文件，一并清掉再一起强推
```

### 典型风险点清单（通用案例）

下面这张表来自一次真实的开源前检查，**路径已替换为示意值** —— 换成你自己项目里对应的位置看一遍：

| 位置类型 | 典型内容 | 处理 |
|---|---|---|
| `<项目目录>/.env` | **真实 API Key / 数据库口令** | 整个目录不外发；推送前必跑扫描 |
| `<项目目录>/.env` + `.env.example` | 模板该提交，真值不该 | 用 `git check-ignore` 确认 `.env` 被忽略；`.env.example` 里必须是占位值 |
| `<项目目录>/data/` | 数十 MB 的数据分片 + 聊天记录库 `chat.db` | 必须被忽略（**这类目录最容易被漏掉**） |
| 项目文档 | 服务器 IP、私有域名、`C:\Users\<用户名>` 本地路径 | 公开前逐处替换为占位符 |

> 通用规律：`.env` 大家都会记得忽略，**真正翻车的是 `data/` / `uploads/` / `backups/`
> 这类"看起来不像密钥"的目录**。它们不含 key，但可能含用户数据，而且体积大 ——
> 一旦推上去，改起来比删个文件麻烦得多。

### 给公开仓库的最低要求

推送前**一定**跑一遍：

```bash
bash scripts/scan-secrets.sh
```

看到 `EXIT=0` 且没有任何 `[DANGER]` 才算过。**`[WARN]` 也要看**——它提示的是"可能没问题但你要确认"。

---

## 8. 真实案例：一次完整的误诊与修复

**起因 · push 开始报错**
- 某个仓库的首次提交**成功推上去了**（网络恰好的窗口；`.git/logs/...` 有 `update by push`）
- 随后补 README / LICENSE 时 push 开始报 `schannel: failed to receive handshake`，
  重试、`http.sslBackend=openssl`、`http.version=HTTP/1.1` 全无效，且**静默失败**
- 当时改走 API 直传完成，之后 `git fetch` + `git reset origin/main` 对齐

**复查 · 定位根因**
- 才发现：梯子其实**一直开着**（系统代理 `127.0.0.1:7890`），
  但 **git 不读 Windows 系统代理** → 梯子对 git 等于不存在
- 修复：per-URL 代理 + `gh auth setup-git`，真实 push 验证通过（临时分支推完即删）
- 同时撤销了一条历史遗留的 `http.sslverify=false`（证书校验曾被静默关闭）

**教训**：报错文本（`schannel` / TLS）会把人往"本地证书配置"的方向带，
实际是**网络层**问题。排查时先问一句"梯子是什么模式、git 到底有没有吃到它"。

> 事后看，走了弯路的关键是：看到 TLS 相关报错就去调 `sslBackend` / `http.version` /
> 证书设置，而这些**全都不是病因**。**先分层再排查** —— 先确认"流量有没有到 GitHub"，
> 再去看"握手能不能成"。

**教训**：报错文本（`schannel` / TLS）会把人往"本地证书配置"的方向带，实际是**网络层**问题。
先问一句"梯子是什么模式、git 有没有吃到它"。
