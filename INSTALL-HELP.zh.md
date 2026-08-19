# Media.io CLI 安装与更新排障指南（INSTALL-HELP.zh.md）

> 中文版，供团队内部阅读。面向 AI 助手的对外版本为英文 [INSTALL-HELP.md](INSTALL-HELP.md)
> （精简提示词里引用的就是英文版）。两份内容保持同步。
>
> 本文档面向 **AI 助手（Codex / VS Code / Claude 桌面端等）**：当用户按精简提示词安装或更新
> `@mediaio/cli` 及插件失败时，按下面的「自检 → 按症状定位 → 执行修复」流程 **自动帮用户解决
> 问题**，只有确实无法自动完成的步骤（如浏览器登录、授予权限）才提示用户操作。

---

## 0. 先跑一遍自检

无论安装还是更新出问题，先收集事实，再决定修什么。逐条执行并记录输出：

```bash
node -v            # Node.js 版本，需 >= 14，推荐 LTS 20/22
npm -v             # npm 是否可用
git --version      # 安装 skills / 插件时需要
mediaio --version  # CLI 是否已装好（未装会报 command not found）
mediaio whoami     # 是否已登录（未登录会提示 not signed in）
mediaio config get # 当前环境（test/beta/prod），别装错环境
```

Windows PowerShell 同样可直接运行以上命令。

判断顺序：
1. `node -v` / `npm -v` 失败 → 先解决 [Node.js 环境](#1-nodejs--npm-环境)。
2. `mediaio --version` 失败 → CLI 没装好，看 [CLI 安装/下载失败](#2-cli-安装或-postinstall-下载失败)。
3. `mediaio --version` 正常但 `mediaio whoami` 未登录 → 看 [登录授权失败](#4-登录授权失败)。
4. 都正常但生成/上传报错 → 看 [运行期权限与环境](#5-运行期权限沙箱与环境)。

---

## 1. Node.js / npm 环境

`@mediaio/cli` 通过 npm 全局安装，要求 **Node.js ≥ 14**，推荐安装 **LTS 版本（20 或 22）**。

检查：

```bash
node -v
npm -v
```

若 `node` 不存在或版本过低，指导用户安装（不要在没有确认的情况下静默改动系统）：

- **macOS**：推荐 `brew install node`（Homebrew）或从 <https://nodejs.org> 下载 LTS 安装包。
- **Windows**：从 <https://nodejs.org> 下载 LTS 安装包安装；或 `winget install OpenJS.NodeJS.LTS`。
- **通用（多版本管理）**：`nvm`（macOS/Linux）或 `nvm-windows`，安装后 `nvm install 22 && nvm use 22`。

安装后重开终端，重新执行 `node -v` 确认。注意：新装 Node.js 后，已打开的 Codex/终端会话可能仍
用旧 PATH，**需要重启客户端或新开终端** 才能识别到 `node`/`npm`/`mediaio`。

---

## 2. CLI 安装或 postinstall 下载失败

安装命令：

```bash
npm install -g @mediaio/cli
```

安装时 `postinstall` 会自动下载与当前系统匹配的 binary 到包内 `vendor/` 目录。常见失败与修复：

### 2.1 解压失败 / `tar` 报错（Windows 常见）

典型报错：

```
tar: Error opening archive: Failed to open '\\.\tape0'
@mediaio/cli: install failed — spawnSync tar EOF
```

原因：旧版本安装器在 Windows 上调用 `tar` 解压 binary 时参数被误解析。**新版本已修复**（改为通过标准
输入喂给 `tar`）。修复步骤：

```bash
npm cache clean --force
npm uninstall -g @mediaio/cli
npm install -g @mediaio/cli@latest
```

确认拿到的是最新版：`mediaio --version`。若仍失败，确认系统自带 `tar`（Windows 10 1803+ 内置
`bsdtar`）：命令行执行 `tar --version` 应有输出。

### 2.2 `binary not found at .../vendor/mediaio`

说明 `postinstall` 没执行或被跳过（例如用 `--ignore-scripts` 装过）。重新安装以触发 postinstall：

```bash
npm uninstall -g @mediaio/cli
npm install -g @mediaio/cli
```

### 2.3 下载 404

安装器按 `mediaio_<version>_<os>_<arch>.tar.gz` 从 GitHub Release 下载。若报 `HTTP 404`，多为版本与
Release 资产不匹配。修复：安装 `@latest`（对齐到已发布版本）：

```bash
npm install -g @mediaio/cli@latest
```

若仍 404，可能是网络无法访问 `github.com`，让用户检查代理 / 公司网络后重试。

### 2.4 平台不支持

安装器只支持 `darwin | linux | windows` × `amd64 | arm64`。报 `unsupported platform` 时确认用户系统在
支持范围内；`win32` 会映射为 `windows`。

### 2.5 命令冲突：`mi` 用不了

CLI 同时提供 `mediaio` 与 `mi` 两个等价命令。若用户机器已有别的 `mi` 命令导致 PATH 冲突，**统一改用
`mediaio`** 即可，功能完全一致。

---

## 3. 插件 / Skills 安装失败

安装方式二选一（**不要同时装插件和 skills**，插件已包含 skills）：

- 插件（推荐）：从 <https://github.com/media-io/plugin> 安装 Mediaio 插件。
- Skills：`npx skills add media-io/plugin -g`（Codex 可加 `--agent codex`）。

常见问题：

- **`npx skills add ...` 失败**：多为缺 `git`。先 `git --version` 确认，Windows 用 <https://git-scm.com>
  安装，macOS 用 `xcode-select --install` 或 `brew install git`，然后重试。
- **解包错误 / 网络超时**：清理后重试 `npx --yes skills add media-io/plugin -g`；确认能访问 `github.com`。
- **装完技能不生效**：Skills 会装到客户端技能目录（如 `~/.codex/skills/`）。**新建一个任务或重启
  Codex / 客户端** 让它重新加载技能。

---

## 4. 登录授权失败

登录采用浏览器 OAuth2（Authorization Code + PKCE）。相关命令：

```bash
mediaio auth login   # 打开浏览器完成登录，凭据存本地
mediaio whoami       # 本地查看当前身份（不联网）
mediaio auth logout  # 清除本地凭据
```

按症状处理：

### 4.1 `whoami` 显示未登录

直接引导用户执行 `mediaio auth login`，并在弹出的浏览器里完成登录，回到终端后再 `mediaio whoami`
确认。**AI 不要替用户点浏览器**，只提示「已为你打开登录页，请在浏览器完成登录后告诉我」。

### 4.2 弹出两次授权页 / 页面无授权按钮 / 无法回调

先彻底清一次再重登，避免多个授权流并存：

```bash
mediaio auth logout
mediaio auth login
```

**只完成其中一个浏览器登录**，不要重复打开多个授权页。桌面客户端若始终无法完成回调，改到系统默认
浏览器里完成登录。

### 4.3 报错 `The requested client must be the same as the client that obtained the code`

这是授权过程中「取 code 的客户端」与「换 token 的客户端」不一致（常因重复打开授权页触发）。修复：

```bash
mediaio auth logout   # 清掉半截凭据
mediaio auth login    # 重新在单一浏览器流程里完成登录
```

若清理后重登仍复现，属于服务端 OAuth 配置问题，**收集报错原文反馈给 Media.io**（见文末反馈通道），
不要让用户反复重试。

### 4.4 登录一段时间后自动退出

凭据过期或被清理。重新 `mediaio auth login` 即可。若频繁发生，记录复现频率与 `mediaio config get`
输出一起反馈。

### 4.5 环境搞错导致「登录了却无权限」

不同环境（test/beta/prod）凭据隔离。先确认环境：

```bash
mediaio config get     # 查看当前环境
mediaio config clear   # 清理当前环境已存的配置/凭据
```

**不要由 AI 主动用 `mediaio config set` 切换环境。** 切换当前环境会影响用户的所有操作，是否切换交给
用户决定。若 `mediaio config get` 显示环境不对，告知用户当前处于哪个环境，由用户决定是否切换。可以
运行 `mediaio config clear` 清理当前环境的失效凭据，再让用户执行 `mediaio auth login` 重新登录。
**登录环境必须与使用环境一致。**

---

## 5. 运行期权限、沙箱与环境

登录、安装都正常，但生成图片/视频、上传文件时被中断或读不到文件，多为 **客户端沙箱 / 权限** 问题。

### 5.1 生成/执行被中断，提示需要「完全访问权限」

Codex 等客户端默认在受限沙箱运行，会拦截 CLI 的网络或文件访问。让用户 **给该 Agent 授予完全访问 /
文件访问权限**（Codex：在客户端权限设置里对该项目开启完全访问 / “full access”），然后重跑任务。
AI 无法自行提权，需明确提示用户去客户端设置里授权。

### 5.2 对话框里上传的图片 CLI 读不到

CLI 只能读本地磁盘上的真实文件路径。若用户是把图片贴进对话框，先把图片 **另存到本地磁盘**，再把
本地路径交给 CLI（`mediaio upload create <本地文件路径>`）。

### 5.3 上传/生成偶发中断退出

先重试一次；持续失败则收集：失败命令、完整报错、`mediaio config get`、`mediaio whoami` 状态，
一并反馈。

---

## 6. 干净重装（终极兜底）

以上都无效时，彻底重来：

```bash
npm uninstall -g @mediaio/cli
npm cache clean --force
npm install -g @mediaio/cli@latest
mediaio --version
mediaio auth login
```

插件/Skills 同理：先卸载再按 [第 3 节](#3-插件--skills-安装失败) 重装，然后重启客户端。

---

## 7. 常用命令速查

```bash
mediaio auth login          # 登录
mediaio whoami              # 查询本地身份
mediaio account status      # 查询账号与积分
mediaio config get          # 查看当前环境与配置
mediaio config clear        # 清理当前环境已存的配置/凭据
mediaio --version           # 查看 CLI 版本
mediaio <command> --help    # 查看任意子命令用法
```

> `mediaio config set <test|beta|prod>` 用于切换环境 — 交给用户操作，AI 不要主动用它切换环境。

---

## 8. 仍无法解决：收集诊断信息并反馈

若自动修复失败，请把下列信息整理给用户，用于人工反馈：

- 操作系统与版本、客户端（Codex / VS / Claude）与版本；
- `node -v`、`npm -v`、`git --version`、`mediaio --version` 输出；
- 失败的完整命令与完整报错文本；
- `mediaio config get`、`mediaio whoami` 的输出（不要泄露 token）。

反馈通道：MI Codex 插件内测体验问题反馈文档。
