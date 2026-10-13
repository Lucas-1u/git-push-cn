# 兜底方案：用 GitHub API 直传文件（不走 git）

**什么时候用**：`github.com:443` 连不上、梯子也挂了、或在沙箱里不想折腾代理，而你又必须把改动送上远端。

**能力边界**：只能**写文件**（新增/覆盖），**不能 clone / pull / 删文件**。因为反向操作要自己用 `git/trees` 反查。

**前提**：`gh` 已登录，且 token 至少有 `repo` scope（公开仓库也够用）。

```bash
gh auth status          # 确认登录 + scopes 里有 repo
```

---

## 1. 单文件上传（实测有效，2026-10-08 用小智的 README / LICENSE 验证过）

**新增文件**：

```bash
# ① 内容转 base64（不能直接塞命令行参数，太长会被截断）
python -c "import base64,io;io.open('b64.txt','w').write(base64.b64encode(io.open('README.md','rb').read()).decode())"

# ② 上传
gh api --method PUT repos/<owner>/<repo>/contents/README.md \
  -f message="提交说明" \
  -F content=@b64.txt
```

**更新已有文件**：必须额外带该文件当前的 sha，否则 422。

```bash
# 取当前 sha
SHA=$(gh api repos/<owner>/<repo>/contents/README.md --jq '.sha')

python -c "import base64,io;io.open('b64.txt','w').write(base64.b64encode(io.open('README.md','rb').read()).decode())"

gh api --method PUT repos/<owner>/<repo>/contents/README.md \
  -f message="更新说明" \
  -F content=@b64.txt \
  -f sha="$SHA"
```

**要点**：
- `-F content=@文件` 是从文件读（`-f` 是字符串，`-F` 才认 `@`）。base64 太长必须走文件。
- 路径里的子目录直接写：`contents/deploy/deploy.sh`。
- 二进制文件同样先 base64，**但 `PUT /contents` 只适合小文件**；大文件（>1MB 级别）请改用 git 通道。

---

## 2. 批量上传（循环调用，每个文件产生一个 commit）

```bash
OWNER=<owner>; REPO=<repo>
while IFS= read -r f; do
  rel="${f#./}"
  python -c "import base64,io,sys;io.open('b64.txt','w').write(base64.b64encode(io.open(sys.argv[1],'rb').read()).decode())" "$f"
  # 已存在则带 sha，不存在则新建
  SHA=$(gh api "repos/$OWNER/$REPO/contents/$rel" --jq '.sha' 2>/dev/null || true)
  if [ -n "$SHA" ]; then
    gh api --method PUT "repos/$OWNER/$REPO/contents/$rel" -f message="上传 $rel" -F content=@b64.txt -f sha="$SHA" >/dev/null
  else
    gh api --method PUT "repos/$OWNER/$REPO/contents/$rel" -f message="上传 $rel" -F content=@b64.txt >/dev/null
  fi
  echo "  ↑ $rel"
done < <(find . -type f -not -path './.git/*')
```

> 缺点：54 个文件 = 54 个 commit，历史会很碎。仅作应急。
> 想一次提交整棵树，得用 Git Data API（`POST /git/blobs` → `POST /git/trees` → `POST /git/commits` → `PATCH /git/refs/heads/<branch>`），
> 能指定自定义 author/committer 与时间；**本机尚未实测过这条路径**，需要时先在小仓库试。

---

## 3. 上传之后：本地与远端会分叉

API 在远端生成的 commit 与本地那个同内容的 commit **不是同一个**（哈希不同），于是分叉。
对齐步骤（**顺序别乱**）：

```bash
# ① 先确认内容一致，再动手
gh api repos/<owner>/<repo>/contents/<path> --jq '.content' | base64 -d > /tmp/remote_file
md5sum /tmp/remote_file <本地文件>

# ② 拉取远端
git fetch origin

# ③ mixed reset 对齐到远端（不动工作区，本地未提交改动保留）
git reset origin/main

# ④ 确认
git rev-parse HEAD; git rev-parse origin/main    # 两者应相等
```

> `git reset --mixed`（默认）只移动 HEAD 与索引，**工作区文件不动**。
> 别用 `--hard`，那会丢掉工作区。
> 本地被丢弃的那个 commit 不会消失，仍可用 `git reflog` 找回。

---

## 4. 核验远端到底传上去了什么

```bash
# 列远端全部文件
gh api repos/<owner>/<repo>/git/trees/main?recursive=1 --jq '.tree[].path'

# 抽查某个文件的内容（base64 解码后比对 md5）
gh api repos/<owner>/<repo>/contents/<path> --jq '.content' | base64 -d | md5sum
```

**不要只看本地**——脱敏、漏传、传错都在这一步暴露（2026-10-08 就是用这招确认服务器 IP / 域名 / 本地路径全被替换掉的）。
