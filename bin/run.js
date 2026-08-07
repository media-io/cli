const { spawn } = require("child_process");
const path = require("path");
const fs = require("fs");

function detectPackageManager() {
  const ua = process.env.npm_config_user_agent || "";
  if (ua.startsWith("pnpm/")) return "pnpm";
  if (ua.startsWith("yarn/")) return "yarn";
  if (ua.startsWith("bun/")) return "bun";
  return "";
}

function readInstallMetadata(vendorDir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(vendorDir, "install.json"), "utf8"));
  } catch (_) {
    return {};
  }
}

module.exports = function run() {
  const binName = process.platform === "win32" ? "mi.exe" : "mi";
  const vendorDir = path.join(__dirname, "..", "vendor");
  const bin = path.join(vendorDir, binName);
  if (!fs.existsSync(bin)) {
    console.error(
      "@mediaio/cli: binary not found at " +
        bin +
        ". Reinstall: npm i -g @mediaio/cli"
    );
    process.exit(1);
  }
  const metadata = readInstallMetadata(vendorDir);
  const child = spawn(bin, process.argv.slice(2), {
    stdio: "inherit",
    env: {
      ...process.env,
      mediaio_INSTALL_METHOD: "npm",
      mediaio_PACKAGE_MANAGER:
        metadata.package_manager || detectPackageManager() || "npm",
    },
  });
  child.on("exit", (code, signal) => {
    if (signal) process.kill(process.pid, signal);
    else process.exit(code ?? 0);
  });
  child.on("error", (err) => {
    console.error("@mediaio/cli: failed to exec —", err.message);
    process.exit(1);
  });
};
