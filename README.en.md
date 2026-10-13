# git-push-cn

> Make `git push / pull / clone / fetch` work reliably against GitHub from mainland China
> on Windows — and scan for leaked secrets **before** you push.

[![Platform](https://img.shields.io/badge/platform-Windows-0078D4)](#)
[![Shell](https://img.shields.io/badge/shell-bash%20%2F%20Git%20Bash-4EAA25)](#)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**Language:** [简体中文](README.md) | English

---

## A platform-agnostic Agent Skill

This repository is a **Skill for any AI agent** — it isn't tied to a specific platform or
client. If your agent can read files and run shell commands, it can use this.

**Recommended workflow: have your agent read it through first, then decide what to adapt.**

Hand the directory to your agent (drop it into its skill / rules / knowledge directory, or
just point at the path) and let it read `SKILL.md`. Then let *it* decide:

- Which checks don't apply on this machine? (macOS uses Secure Transport, not schannel, for instance.)
- Which paths, ports, or commands need to be swapped for local reality?
- Should the content be rewritten into whatever form it handles best — rule files, tool
  descriptions, workflow orchestration…?

> In other words: **the default form of this skill is "a thoroughly written manual",
> not "a set of code to copy verbatim".** It carries a lot of real cases and hard-won
> notes — those are knowledge, not dogma. An agent that reads it and tailors it usually
> does better than one that copies it wholesale.

The three shell scripts are **also fully usable without any AI** — just clone the repo and
run them by hand in Git Bash. Both paths work.

```
git-push-cn/
├── SKILL.md                    # Main doc: diagnosis table + fixes + hard rules
├── README.md                   # Chinese version
├── README.en.md                # The file you are reading (English)
├── LICENSE                     # MIT
├── scripts/
│   ├── diagnose.sh             # One-shot connectivity diagnosis, per-item ✅/❌
│   ├── setup.sh                # One-shot setup (per-URL proxy + gh credentials), idempotent
│   └── scan-secrets.sh         # Pre-push secret/privacy scan, read-only
└── references/
    ├── troubleshooting.md      # Full troubleshooting tree, SSH route, TUN mode, real cases
    └── api-fallback.md         # GitHub API fallback when the proxy is completely dead
```

---

## The problem it solves

The classic one: **"My VPN is on — why can't git push?"**

Because **Git for Windows does not read the Windows system proxy.**

| VPN mode | Who is affected | Does git benefit? |
|---|---|---|
| System proxy (registry `ProxyEnable=1`) | Browsers, some apps | ❌ **git ignores this** |
| Routing rule "global mode" | Only decides *whether* to use the proxy | ❌ It doesn't hand traffic **to** the proxy |
| **TUN mode** (virtual NIC) | Every program | ✅ Truly captures all traffic |
| **Telling git explicitly** | git itself | ✅ `http.proxy` config or `http_proxy` env var |

git's libcurl only honours the last two. Either configure the proxy explicitly (this skill's
main approach) or switch your VPN client to TUN mode.

> Worth knowing: the block on `github.com` is **intermittent**. On the same evening you may see
> a direct connection reset at 22:20 and succeed at 22:55. So **don't delete the config just
> because one test passed** — it costs nothing to keep, and it's essential once the wall returns.

---

## Symptoms covered

| Error / symptom | Real cause |
|---|---|
| `schannel: failed to receive handshake` | `github.com:443` reset; git isn't using the proxy |
| `schannel: server closed abruptly` | Same as above |
| `Recv failure: Connection was reset` | Same as above |
| `Failed to connect to github.com:443 after 21045 ms` | Blocked direct connection, no proxy |
| `CONNECT tunnel failed, response 502` | Inside an agent sandbox with a proxy (its proxy blocks github.com) |
| `could not read Username for 'https://github.com'` | No GitHub credentials in the credential helper (GCM) |
| **Exit code 0 but the remote is unchanged** | Silent failure — never trust the exit code |
| `CRYPT_E_NO_REVOCATION_CHECK` | Windows schannel CRL lookup failure |

The full symptom → cause → fix table lives in [`SKILL.md`](SKILL.md).

---

## Quick start

**Requirements:** Windows + [Git for Windows](https://git-scm.com/download/win)
(scripts run inside Git Bash). Pushing to private repos also needs a logged-in
[`gh`](https://cli.github.com/).

### 1. Diagnose (30 seconds, read-only)

```bash
bash scripts/diagnose.sh            # auto-detect the proxy port
bash scripts/diagnose.sh 7891       # or specify the port manually
```

It reports ✅/❌ for each item: proxy port → the three git settings → reaching GitHub through
the proxy → git read → git write (dry-run).

### 2. Fix (idempotent, safe to re-run)

```bash
bash scripts/setup.sh
```

Three things happen: ① it **verifies the port can actually reach GitHub before writing any
config**; ② it writes a **per-URL proxy**; ③ it wires credentials via `gh auth setup-git`;
then it runs a real `ls-remote` as verification.

> **Why per-URL instead of a global `http.proxy`**: a global setting breaks **every** git
> operation (gitee, internal repos, everything) the moment your VPN is off or changes ports.
> A per-URL setting only affects `github.com`, so the worst case is identical to having no
> config at all.

### 3. Scan before pushing (**cannot be skipped**)

```bash
bash scripts/scan-secrets.sh
```

**Exit code 0 = nothing blocking; 1 = there are `[DANGER]` items — resolve them before pushing.**

It covers 7 sections: whether sensitive files are ignored → already-tracked sensitive files →
staged file list → hardcoded keys → IP / domain / local-path privacy → large-directory coverage
→ final self-check. **Read-only; makes no network requests.**

---

## Manual setup (equivalent to setup.sh)

```bash
# 1) Proxy: applies to github.com only (key point: never use a global http.proxy)
git config --global --replace-all 'http.https://github.com/.proxy' 'http://127.0.0.1:7890'

# 2) Credentials: let gh supply GitHub credentials (otherwise: could not read Username)
gh auth setup-git

# 3) Verify
git ls-remote --exit-code https://github.com/octocat/Hello-World.git HEAD && echo OK
```

After your VPN changes ports, just re-run step 1 with the new port.

---

## 🔴 Remember before you push

The **only irreversible mistake** this skill guards against is a secret leak —
network errors can be retried, but a key pushed to a public repo is **scraped instantly**
and deleting it afterwards is too late.

- **`.env` and its equivalents must never enter the repository.** That includes `*.key` /
  `*.pem` / `*.p12` / `credentials*` / `token*` / `*.db`.
  But `*.example` / `*.sample` / `*.template` are **placeholder templates meant to be
  committed** — don't "protect" them too, or newcomers won't know what to configure.
- **Don't eyeball `.gitignore`** — test it with `git check-ignore`. A subtler trap:
  **once a file has been tracked by git, adding it to `.gitignore` later has no effect**;
  you must `git rm --cached <file>`.
- **`git add -A` is a high-risk action**, especially at the project root. Prefer
  `git add <specific-path>`.
- **Always verify the remote after pushing** — that file list is what's actually public:
  ```bash
  gh api repos/<owner>/<your-repo>/git/trees/main?recursive=1 --jq '.tree[].path'
  ```
- **If it's already pushed — order matters: revoke the key first, clean history second.**
  Deleting the file and committing does nothing; the key stays visible via `git log -p`.
  And as long as the key isn't revoked, cleaning history is a waste of effort.

---

## Choosing between the three routes

| Route | Needs VPN | Capability | When to use |
|---|---|---|---|
| **HTTPS + per-URL proxy** | Yes (VPN always on) | Full push / pull / clone | The default |
| **SSH** | **No** (`github.com:22` and `ssh.github.com:443` are directly reachable) | Full | To drop the VPN entirely → `references/troubleshooting.md` |
| **API direct upload** | No (goes via `api.github.com`) | File upload only, **no clone/pull** | VPN down, sandboxed, or a quick one- or two-file change → `references/api-fallback.md` |

A less fiddly alternative: switch your VPN to **TUN mode** — git needs zero config, and every
other tool that ignores the system proxy (pip, npm, python) is fixed at the same time.

---

## Hard no-gos

- ❌ **Never set `http.sslverify=false`** — that disables HTTPS certificate validation and
  exposes your token to a man-in-the-middle. For revocation-check errors use
  `http.schannelCheckRevoke=false` (**revocation check only**).
- ❌ **Never use a global `http.proxy`** — one VPN outage kills every git operation,
  including domestic hosts.
- ❌ **Never put a token in the remote URL** (`https://<token>@github.com/...`) — it lands in
  `.git/config` and your shell history. Use `gh auth setup-git`.
- ❌ **Never trust push's exit code** — compare `git rev-parse HEAD` with `origin/main`, or
  look for `update by push` in `.git/logs/refs/remotes/origin/main`.

---

## Installing it into your agent

There is no "standard path" — every agent puts its skills somewhere different. The general recipe:

```bash
# 1) Clone it somewhere convenient
git clone https://github.com/Lucas-1u/git-push-cn.git ~/git-push-cn

# 2) Then place it however your agent expects (pick one)
#    Claude Code / WorkBuddy style: <config-dir>/skills/git-push-cn/
#    Cursor / Windsurf style:       add to .cursor/rules/ or your project rule file
#    ChatGPT / Claude web:          paste SKILL.md into project knowledge, upload scripts
#    Custom agent:                  just hand it the directory path and let it read
```

**Not sure how to place it? Ask your agent.** Give it the clone path and let it inspect the
directory and figure out which files go where — it's a better judge than guesswork.

Once installed, triggers include: push failing with schannel / TLS handshake / Connection was
reset, `could not read Username`, exit code 0 but no remote change, or wanting to check a repo
for leaks before publishing it.

---

## License

[MIT](LICENSE) © 2026 Lucas-1u
