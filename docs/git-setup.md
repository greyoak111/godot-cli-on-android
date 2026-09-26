# 在 Android 上配置 git 推送 GitHub

本文记录在**无 root、无 Termux** 的安卓设备上把 git 跑通并推送到 GitHub 的完整过程，
包括踩到的坑与解法。实测环境：Lenovo TB320FC / Android 15。

---

## 结论先行

| 项目 | 结果 |
|---|---|
| git 客户端 | **2.55.0**（从 Termux 仓库抽取 aarch64 静态包） |
| 需要的安卓权限 | **一个都不需要**（不是特权操作，普通应用身份即可） |
| 认证方式 | **SSH 密钥**（推荐）或 Personal Access Token |
| 网络 | SSH 走 `ssh.github.com:443`（避开 22 端口封锁） |

> ⚠️ **GitHub 从 2021 年 8 月起不再接受账号密码**做 git 操作。
> 用 HTTPS 必须用 Personal Access Token，不是登录密码。

---

## 一、装 git

Termux 的仓库里有现成的 aarch64 包。核心包 `git` 的依赖：
`libcurl, libexpat, libiconv, less, openssl, pcre2, zlib`

装好后需要设置这几个环境变量——**因为 Termux 的包把
`/data/data/com.termux/files/usr` 硬编码进去了**：

```sh
P=<你的 prefix 路径>
export LD_LIBRARY_PATH="$P/lib"
export GIT_EXEC_PATH="$P/libexec/git-core"        # 181 个 helper 的位置
export GIT_TEMPLATE_DIR="$P/share/git-core/templates"
export GIT_SSL_CAINFO="$P/etc/tls/cert.pem"       # 否则报 error adding trust anchors
export SSL_CERT_FILE="$P/etc/tls/cert.pem"
export CURL_CA_BUNDLE="$P/etc/tls/cert.pem"
```

不设 `GIT_SSL_CAINFO` 会直接报：

```
fatal: unable to access 'https://github.com/...':
error adding trust anchors from file: /data/data/com.termux/files/usr/etc/tls/cert.pem
```

---

## 二、FUSE 文件系统的坑

把仓库放在 `/sdcard`（FUSE）时有三个问题：

### 1. dubious ownership

FUSE 把所有文件报成 `media_rw` 属主，git 拒绝操作：

```
fatal: detected dubious ownership in repository at '/storage/emulated/0/...'
```

```sh
git config --global --add safe.directory '*'
```

### 2. 文件权限位不可靠

FUSE 不保留 Unix 权限位，git 会误报大量 mode change：

```sh
git config --global core.fileMode false
```

### 3. 不支持符号链接

`cp -a` 复制含符号链接的目录会大面积 `Permission denied`。
用 `cp -RL`（解引用）代替，然后在目标位置重建链接。

---

## 三、SSH 密钥（推荐路线）

### 1. 生成密钥

设备上没有 `ssh-keygen`，从 Termux 抽 `openssh`（6.4MB）即可：

```sh
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "your-device@android"
```

### 2. 把公钥贴到 GitHub

👉 https://github.com/settings/keys → **New SSH key** → 粘贴 `id_ed25519.pub` 全文

### 3. 关键坑：ssh 无视 `$HOME`

**OpenSSH 不读 `$HOME`，它用 `getpwuid()` 返回的 home。**
安卓上那通常是 `/data/data/com.termux/files/home`（Termux 的残留路径），
结果是 ssh 去那里找配置和密钥，必然失败。

**解法：配置文件里全部用绝对路径。**

`~/.ssh/config`：

```
Host github.com
  HostName ssh.github.com     # 走 443 端口
  Port 443
  User git
  IdentityFile /绝对/路径/.ssh/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile /绝对/路径/.ssh/known_hosts
  StrictHostKeyChecking accept-new
```

并让 ssh 命令显式带 `-F`（写成包装器）：

```sh
#!/system/bin/sh
P=<prefix>
export LD_LIBRARY_PATH="$P/lib"
exec "$P/bin/ssh" -F /绝对/路径/.ssh/config "$@"
```

### 4. 关键坑：`core.sshCommand` 的引号

**不要**把带空格的参数塞进 `core.sshCommand`：

```sh
# ❌ git 会把整串当成一个程序名去 exec，报 cannot exec / unable to fork
git config --global core.sshCommand "ssh -F /path/to/config"

# ✅ 用单一绝对路径（包装器里已经带好了 -F）
git config --global core.sshCommand "/绝对/路径/bin/ssh"
```

### 5. 验证

```sh
ssh -T git@github.com
# Hi <用户名>! You've successfully authenticated, but GitHub does not
# provide shell access.
```

---

## 四、HTTPS + Token（备选路线）

如果不想用 SSH，就建 Personal Access Token：

| 类型 | 地址 | 权限 |
|---|---|---|
| Fine-grained（最小权限） | https://github.com/settings/personal-access-tokens/new | Repository access 选目标仓库；**Contents: Read and write** |
| Classic（更简单） | https://github.com/settings/tokens/new | 勾 `repo` |

存凭据：

```sh
git config --global credential.helper store
# 首次 push 输入用户名 + token（不是密码），会存到 ~/.git-credentials
chmod 600 ~/.git-credentials
```

---

## 五、推荐的全局配置

```sh
git config --global user.name  "你的用户名"
git config --global user.email "你的用户名@users.noreply.github.com"
git config --global init.defaultBranch main
git config --global safe.directory '*'
git config --global core.fileMode false
git config --global http.postBuffer 524288000   # 大仓库/慢网络
git config --global core.sshCommand "/绝对/路径/bin/ssh"
```

---

## 六、常见错误速查

| 报错 | 原因 | 解法 |
|---|---|---|
| `error adding trust anchors from file: /data/data/com.termux/...` | CA 路径硬编码 | 设 `GIT_SSL_CAINFO` |
| `warning: templates not found in /data/data/com.termux/...` | 模板路径硬编码 | 设 `GIT_TEMPLATE_DIR` |
| `detected dubious ownership` | FUSE 属主问题 | `safe.directory '*'` |
| `Host key verification failed` | ssh 读了错误的 home | 配置里用绝对路径 + 显式 `-F` |
| `cannot exec / unable to fork` | `core.sshCommand` 含空格 | 改成单一绝对路径 |
| `Permission denied (publickey)` | 公钥没上传 GitHub | 贴到 settings/keys |
| `Support for password authentication was removed` | 用了账号密码 | 改用 token |
