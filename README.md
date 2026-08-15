# @mediaio/cli

Media.io CLI 的 npm 安装与启动层。该包本身不实现 Media.io API，而是在
`postinstall` 阶段下载与当前操作系统、CPU 架构匹配的 `media-plugin-bin` Go
binary，并通过 JavaScript launcher 透传参数、标准输入输出、signal 和退出码。

整体技术方案参考：[MCP、CLI 与 Agent 插件技术方案 v2](../media-plugin-mcp/docs/architecture/MCP、CLI与Agent插件技术方案-v2.md)。

## 架构位置

```text
npm install -g @mediaio/cli
    ↓ postinstall
install.js 下载 vendor/mediaio（Windows 为 vendor/mediaio.exe）
    ↓
mediaio 命令 → bin/mediaio.js → bin/run.js → Go binary
    ↓
Media.io 公网 API
```

`media-plugin-main` 中的 Agent Skills 可以复用这套 CLI/binary 基座；本仓库不包含
Skills、MCP 服务或 Media.io API client 实现。

## 环境要求

- Node.js 14 或更高版本。
- npm、pnpm、Yarn 或 Bun；安装器会记录检测到的包管理器。
- 系统提供 `tar` 命令。当前安装器使用 `tar` 解压 binary，Windows 环境也必须可用。
- 能访问当前配置的 GitHub Release 下载地址。

## 安装

```bash
npm install -g @mediaio/cli
```

安装完成后：

```bash
mediaio --help
mediaio auth login
mediaio generate list
```

CLI 只提供 `mediaio` 命令，不提供缩写别名。命令、binary、Release asset 和安装目录
均使用完整的 `mediaio` 名称。

## postinstall 做了什么

`npm install` 会执行：

```text
node install.js
```

当前安装流程：

1. 将 Node 平台映射为 binary 平台名：`darwin`、`linux`、`windows`。
2. 将 Node 架构映射为 Go 架构名：`x64 → amd64`、`arm64 → arm64`。
3. 读取 npm 包版本作为 binary 版本。
4. 下载对应的 `.tar.gz` Release asset。
5. 从压缩包根目录提取 `mediaio` 或 `mediaio.exe` 到 `vendor/`。
6. Unix 平台为 binary 增加可执行权限。
7. 写入 `vendor/install.json`，记录安装方式、包管理器、包名和版本。

当前下载规则：

```text
https://github.com/media-io/cli/releases/download/v<version>/mediaio_<version>_<os>_<arch>.tar.gz
```

例如 npm 包版本为 `1.0.3`、运行环境为 Apple Silicon macOS 时，会下载：

```text
https://github.com/media-io/cli/releases/download/v1.0.3/mediaio_1.0.3_darwin_arm64.tar.gz
```

archive 根目录必须直接包含 `mediaio`；Windows archive 必须直接包含 `mediaio.exe`。

## launcher 行为

`bin/run.js` 启动 `vendor/mediaio` 或 `vendor/mediaio.exe`，并执行以下透传：

- 原样传递 CLI 参数。
- `stdin`、`stdout`、`stderr` 使用 `inherit`。
- 子进程被 signal 终止时，将 signal 传递给当前 Node 进程。
- 正常退出时返回 Go binary 的 exit code。
- 向 binary 注入 `mediaio_INSTALL_METHOD=npm`。
- 向 binary 注入 `mediaio_PACKAGE_MANAGER=<npm|pnpm|yarn|bun>`。

## 本地开发

只检查 JavaScript 语法，不触发 binary 下载：

```bash
node --check install.js
node --check bin/mediaio.js
node --check bin/run.js
npm pack --dry-run
```

使用相邻的 `media-plugin-bin` 本地构建产物联调：

```bash
# 先在 ../media-plugin-bin 中构建
cd ../media-plugin-bin
mkdir -p dist
go build -trimpath -o dist/mediaio .

# 回到本仓库，跳过 postinstall 并放入本地 binary
cd ../media-plugin-cli
npm install --ignore-scripts
mkdir -p vendor
cp ../media-plugin-bin/dist/mediaio vendor/mediaio
chmod +x vendor/mediaio

node bin/mediaio.js --help
node bin/mediaio.js generate list
```

Windows 请复制 `mediaio.exe`：

```powershell
New-Item -ItemType Directory -Force vendor
Copy-Item ..\media-plugin-bin\dist\mediaio.exe vendor\mediaio.exe
node bin\mediaio.js --help
```

## 发布

npm 包与 Go binary 当前使用同一个版本号，必须成套发布。

1. 在 `media-plugin-bin` 中完成测试和多平台构建。
2. 创建 `v<version>` Release，并上传对应的 binary archives。
3. 确认每个 archive 的名称和根目录文件符合安装器约定。
4. 将本仓库 `package.json.version` 设置为相同版本。
5. 检查 npm 包内容并发布。

```bash
npm pack --dry-run
npm pack
npm publish --access public
```

发布后应在干净环境验证：

```bash
npm install -g @mediaio/cli@<version>
mediaio --help
```

v2 方案首期 binary matrix 为：

```text
darwin/amd64
darwin/arm64
linux/amd64
linux/arm64
windows/amd64
```

注意：当前 `package.json` 的 `os` 与 `cpu` 字段、`install.js` 的映射逻辑也会允许
`windows/arm64` 进入安装流程。正式发布前必须二选一：提供
`mediaio_<version>_windows_arm64.tar.gz`，或收紧安装器/包元数据，避免用户安装后得到 404。

## 排障

### binary 不存在

如果看到 `binary not found at .../vendor/mediaio`，说明 `postinstall` 未执行或执行失败。

```bash
npm uninstall -g @mediaio/cli
npm install -g @mediaio/cli
```

使用 `npm install --ignore-scripts` 安装时不会下载 binary；当前版本尚未提供独立的
`mediaio install` 修复命令。

### 下载返回 404

检查以下三项是否完全一致：

- `package.json.version`；
- GitHub Release tag `v<version>`；
- asset 名称 `mediaio_<version>_<os>_<arch>.tar.gz`。

### 解压失败

确认系统存在 `tar`，并确认 archive 根目录直接包含 `mediaio` 或 `mediaio.exe`。

### 平台不支持

当前安装器只识别：

```text
darwin | linux | windows
amd64 | arm64
```

Node 报告的其他 `process.platform` 或 `process.arch` 会直接终止安装。

## 当前实现与 v2 目标的差异

| 领域 | 当前实现 | v2 目标 |
|---|---|---|
| npm 包名 | `@mediaio/cli` | `@mediaio/cli` |
| 命令入口 | 仅 `mediaio` | 仅 `mediaio`，不提供缩写别名 |
| 版本锁定 | npm version 直接拼接下载 URL | 独立 binary manifest 固定精确版本 |
| 完整性校验 | 尚无 checksum/signature 校验 | SHA-256、签名和 binary version 校验 |
| 下载安全 | 直接写目标 tarball，未配置 timeout | 随机临时文件、timeout、原子安装和统一清理 |
| 平台识别 | OS/CPU；未识别 libc | Linux 明确 glibc/musl 策略 |
| 安装修复 | 重新安装 npm 包 | 显式 install/repair/upgrade/offline 入口 |
| metadata | 写入 `install.json`，launcher 损坏时降级 | metadata 与 binary 原子安装，损坏时明确失败 |

这些目标完成前，README 和发布说明应明确当前能力边界，不能声称安装器已经验证
checksum、签名或 binary version。
