# @mediaio/cli

This repository provides the npm installation and launcher layer for the
Media.io CLI. It does not implement the Media.io API itself. Instead, during
`postinstall`, it downloads the `media-plugin-bin` Go binary that matches the
current operating system and CPU architecture, then invokes it through a
JavaScript launcher that forwards arguments, stdio, signals, and exit codes.

For the broader technical design, see
[MCP, CLI, and Agent Plugin Technical Plan v2](../media-plugin-mcp/docs/architecture/MCP、CLI与Agent插件技术方案-v2.md).

## Architecture

```text
npm install -g @mediaio/cli
    ↓ postinstall
install.js downloads vendor/mediaio (or vendor/mediaio.exe on Windows)
    ↓
mediaio / mi command → JavaScript launcher → Go binary
    ↓
Media.io public API
```

The agent skills in `media-plugin-main` can reuse this CLI/binary foundation.
This repository does not include skills, an MCP server, or a Media.io API
client implementation.

## Requirements

- Node.js 14 or later.
- npm, pnpm, Yarn, or Bun. The installer records the detected package manager.
- A system `tar` command. The current installer uses `tar` to extract the
  binary, including on Windows.
- Access to the configured GitHub Release download URL.

## Installation

```bash
npm install -g @mediaio/cli
```

After installation:

```bash
mediaio --help
mi --help
mediaio auth login
mediaio generate list
```

The CLI exposes both `mediaio` and `mi` as equivalent commands. They use the
same launcher, binary, configuration, and credentials. `mediaio` is the
canonical command: all documentation, automation, and troubleshooting guidance
should use it. `mi` is only a convenience alias for terminal input. If a user
machine already has another `mi` command in `PATH`, continue using `mediaio`.

## For Claude Code

The `Claude Code` plugin in `media-plugin-main` depends on an executable
`mediaio` command on the local machine. This npm package is one supported way to
install that local runtime.

Recommended verification flow:

```bash
npm install -g @mediaio/cli
mediaio auth login
mediaio version
mediaio model list
```

If these commands work, you can then install the `Claude Code` plugin from
`media-plugin-main`. The plugin itself does not silently install or repair the
`mediaio` CLI for you.

## What `postinstall` Does

`npm install` runs:

```text
node install.js
```

Current installation flow:

1. Map the Node platform to the binary platform name: `darwin`, `linux`,
   `windows`.
2. Map the Node architecture to the Go architecture name:
   `x64 → amd64`, `arm64 → arm64`.
3. Read the npm package version as the binary version.
4. Download the matching `.tar.gz` release asset.
5. Extract `mediaio` or `mediaio.exe` from the archive root into `vendor/`.
6. Add executable permissions on Unix platforms.
7. Write `vendor/install.json` with the install method, package manager,
   package name, and version.

Current download rule:

```text
https://github.com/media-io/cli/releases/download/v<version>/mediaio_<version>_<os>_<arch>.tar.gz
```

For example, if the npm package version is `1.0.3` and the runtime environment
is Apple Silicon macOS, the installer downloads:

```text
https://github.com/media-io/cli/releases/download/v1.0.3/mediaio_1.0.3_darwin_arm64.tar.gz
```

The archive root must directly contain `mediaio`. On Windows, it must directly
contain `mediaio.exe`.

## Launcher Behavior

`bin/run.js` starts `vendor/mediaio` or `vendor/mediaio.exe` and provides the
following pass-through behavior:

- Forward CLI arguments unchanged.
- Use `inherit` for `stdin`, `stdout`, and `stderr`.
- Forward termination signals from the child process back to the Node process.
- Return the Go binary exit code on normal exit.
- Inject `mediaio_INSTALL_METHOD=npm` into the binary environment.
- Inject `mediaio_PACKAGE_MANAGER=<npm|pnpm|yarn|bun>` into the binary
  environment.

## Local Development

Validate JavaScript syntax only, without triggering a binary download:

```bash
node --check install.js
node --check bin/mediaio.js
node --check bin/run.js
npm pack --dry-run
```

Use a locally built binary from the sibling `media-plugin-bin` repository for
integration testing:

```bash
# Build first in ../media-plugin-bin
cd ../media-plugin-bin
mkdir -p dist
go build -trimpath -o dist/mediaio .

# Return to this repository, skip postinstall, and place the local binary
cd ../media-plugin-cli
npm install --ignore-scripts
mkdir -p vendor
cp ../media-plugin-bin/dist/mediaio vendor/mediaio
chmod +x vendor/mediaio

node bin/mediaio.js --help
node bin/mi.js --help
node bin/mediaio.js generate list
```

On Windows, copy `mediaio.exe` instead:

```powershell
New-Item -ItemType Directory -Force vendor
Copy-Item ..\media-plugin-bin\dist\mediaio.exe vendor\mediaio.exe
node bin\mediaio.js --help
```

## Release

The npm package and Go binary currently use the same version number and must be
released together.

1. Finish testing and multi-platform builds in `media-plugin-bin`.
2. Create a `v<version>` release and upload the matching binary archives.
3. Verify that each archive name and root file match the installer contract.
4. Set this repository's `package.json.version` to the same version.
5. Inspect the npm package contents and publish.

```bash
npm pack --dry-run
npm pack
npm publish --access public
```

After release, validate in a clean environment:

```bash
npm install -g @mediaio/cli@<version>
mediaio --help
```

The initial v2 binary matrix is:

```text
darwin/amd64
darwin/arm64
linux/amd64
linux/arm64
windows/amd64
```

Note: the current `package.json` `os` and `cpu` fields, together with the
mapping logic in `install.js`, also allow `windows/arm64` to enter the install
flow. Before public release, you must do one of the following:

- provide `mediaio_<version>_windows_arm64.tar.gz`, or
- tighten the installer and package metadata so users do not hit a 404 after
  installation.

## Troubleshooting

### Binary Missing

If you see `binary not found at .../vendor/mediaio`, `postinstall` did not run
or failed.

```bash
npm uninstall -g @mediaio/cli
npm install -g @mediaio/cli
```

If you install with `npm install --ignore-scripts`, the binary will not be
downloaded. The current version does not yet provide a separate `mediaio install`
repair command.

### Download Returns 404

Check that all three of the following match exactly:

- `package.json.version`
- GitHub release tag `v<version>`
- asset name `mediaio_<version>_<os>_<arch>.tar.gz`

### Extraction Fails

Make sure the system provides `tar`, and make sure the archive root directly
contains `mediaio` or `mediaio.exe`.

### Unsupported Platform

The current installer recognizes only:

```text
darwin | linux | windows
amd64 | arm64
```

Any other `process.platform` or `process.arch` reported by Node causes the
installation to fail immediately.

## Current Implementation vs. v2 Target

| Area | Current Implementation | v2 Target |
|---|---|---|
| npm package name | `@mediaio/cli` | `@mediaio/cli` |
| command entry | `mediaio` only | `mediaio` only, with no shorthand alias |
| version locking | npm version is interpolated directly into the download URL | dedicated binary manifest pins the exact version |
| integrity validation | no checksum or signature validation yet | SHA-256, signature, and binary version validation |
| download safety | writes directly to the target tarball, no explicit timeout | random temp file, timeout, atomic install, and unified cleanup |
| platform detection | OS and CPU only; no libc detection | explicit Linux glibc vs musl strategy |
| install repair | reinstall the npm package | explicit install / repair / upgrade / offline entry points |
| metadata | writes `install.json`, degrades if launcher metadata is damaged | metadata and binary installed atomically, with explicit failure on corruption |

Until these targets are implemented, the README and release instructions must
state the current capability boundaries clearly and must not claim that the
installer already validates checksums, signatures, or binary versions.
