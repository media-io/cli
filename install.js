#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const https = require("https");
const { execFileSync } = require("child_process");

const pkg = require("./package.json");
const VERSION = pkg.version;

const PLATFORM_MAP = { darwin: "darwin", linux: "linux", win32: "windows" };
const ARCH_MAP = { x64: "amd64", arm64: "arm64" };

const platform = PLATFORM_MAP[process.platform];
const arch = ARCH_MAP[process.arch];

if (!platform || !arch) {
  console.error(
    `@mediaio/cli: unsupported platform ${process.platform}/${process.arch}`
  );
  console.error("Supported: darwin|linux|windows × x64|arm64");
  process.exit(1);
}

const binName = platform === "windows" ? "mediaio.exe" : "mediaio";
const tarball = `mediaio_${VERSION}_${platform}_${arch}.tar.gz`;
const url = `https://github.com/media-io/cli/releases/download/v${VERSION}/${tarball}`;

const vendorDir = path.join(__dirname, "vendor");
fs.mkdirSync(vendorDir, { recursive: true });
const tarballPath = path.join(vendorDir, tarball);
const metadataPath = path.join(vendorDir, "install.json");

function detectPackageManager() {
  const ua = process.env.npm_config_user_agent || "";
  if (ua.startsWith("pnpm/")) return "pnpm";
  if (ua.startsWith("yarn/")) return "yarn";
  if (ua.startsWith("bun/")) return "bun";
  return "npm";
}

function download(targetUrl, dest, redirects = 0) {
  return new Promise((resolve, reject) => {
    if (redirects > 5) return reject(new Error("too many redirects"));
    const file = fs.createWriteStream(dest);
    https
      .get(targetUrl, (res) => {
        if (
          res.statusCode >= 300 &&
          res.statusCode < 400 &&
          res.headers.location
        ) {
          file.close();
          fs.unlinkSync(dest);
          return resolve(download(res.headers.location, dest, redirects + 1));
        }
        if (res.statusCode !== 200) {
          file.close();
          try {
            fs.unlinkSync(dest);
          } catch (_) {}
          return reject(new Error(`HTTP ${res.statusCode} for ${targetUrl}`));
        }
        res.pipe(file);
        file.on("finish", () => file.close(() => resolve()));
      })
      .on("error", (err) => {
        try {
          fs.unlinkSync(dest);
        } catch (_) {}
        reject(err);
      });
  });
}

(async () => {
  console.log(`@mediaio/cli: downloading ${url}`);
  await download(url, tarballPath);
  console.log(`downloaded ${url}`);
  // 通过 stdin 传入压缩包：Windows 下 bsdtar 会把含 "C:" 或 "@scope" 的 "-f <路径>" 误判为 user@host 远程语法；
  // 必须显式指定 "-f -" 从标准输入读取，否则 bsdtar 会回退到默认磁带设备 \\.\tape0 并报错
  execFileSync("tar", ["-xzf", "-", "-C", vendorDir, binName], {
    input: fs.readFileSync(tarballPath),
  });
  if (platform !== "windows") {
    fs.chmodSync(path.join(vendorDir, binName), 0o755);
  }
  fs.writeFileSync(
    metadataPath,
    JSON.stringify(
      {
        install_method: "npm",
        package_manager: detectPackageManager(),
        package_name: pkg.name,
        version: VERSION,
      },
      null,
      2
    ) + "\n"
  );
  fs.unlinkSync(tarballPath);
  console.log("@mediaio/cli: installed");
})().catch((err) => {
  console.error("@mediaio/cli: install failed —", err.message);
  process.exit(1);
});
