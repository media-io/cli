import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const cliRoot = resolve(new URL("..", import.meta.url).pathname);
const pluginRoot = join(cliRoot, "../media-plugin-main/plugin-cli-main");

function withFixture(run) {
  const directory = mkdtempSync(join(tmpdir(), "mediaio-install-test-"));
  try {
    const home = join(directory, "home");
    const checkout = join(directory, "media-plugin-cli");
    mkdirSync(home);
    mkdirSync(checkout);
    const source = join(directory, "media-plugin-main/plugin-cli-main");
    cpSync(pluginRoot, source, { recursive: true });
    run({ home, checkout, source });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function writeFile(filepath, content) {
  mkdirSync(resolve(filepath, ".."), { recursive: true });
  writeFileSync(filepath, content);
}

function runFunctions(filename, fixture, commands) {
  const source = readFileSync(join(cliRoot, filename), "utf8");
  const label = filename.startsWith("setup") ? "setup" : "uninstall";
  const boundary = source.indexOf(`printf '%s\\n' "Media.io ${label} script"`);
  assert.ok(boundary > 0, "Function-only boundary must exclude installation entrypoint");
  const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("MEDIAIO_")));
  const result = spawnSync("sh", ["-s"], {
    input: source.slice(0, boundary) + `\nSCRIPT_ROOT=${JSON.stringify(fixture.checkout)}\ncodex() { printf '%s\\n' "$*"; }\nclaude() { printf '%s\\n' "$*"; }\n` + commands,
    cwd: fixture.checkout,
    env: { ...environment, HOME: fixture.home, USERPROFILE: fixture.home },
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr + result.stdout);
  return result.stdout;
}

test("setup registers only CLI and preserves MCP in the personal marketplace", () => withFixture((fixture) => {
  const marketplace = join(fixture.home, ".agents/plugins/marketplace.json");
  const mcp = { name: "media-io", source: { source: "local", path: "./plugins/media-io" } };
  writeFile(marketplace, JSON.stringify({ name: "personal", plugins: [mcp] }));
  writeFile(join(fixture.home, "plugins/media-io/mcp-marker"), "keep");
  runFunctions("setup-mediaio.sh", fixture, "initialize_personal_marketplace_fallback\ninitialize_personal_marketplace_fallback\n");
  const entries = JSON.parse(readFileSync(marketplace, "utf8")).plugins;
  assert.deepEqual(entries[0], mcp);
  assert.equal(entries.length, 2);
  assert.equal(entries[1].name, "media-io-cli");
  assert.equal(entries[1].source.path, "./plugins/media-io-cli");
  assert.equal(JSON.parse(readFileSync(join(fixture.home, "plugins/media-io-cli/.codex-plugin/plugin.json"))).name, "media-io-cli");
  assert.ok(existsSync(join(fixture.home, "plugins/media-io/mcp-marker")));
}));

test("setup and uninstall resolve the migrated CLI source and skills", () => withFixture((fixture) => {
  for (const filename of ["setup-mediaio.sh", "uninstall-mediaio.sh"]) {
    const output = runFunctions(filename, fixture, "get_mediaio_plugin_source_root\nget_mediaio_skill_source_root\n");
    assert.deepEqual(output.trim().split("\n").map((filepath) => resolve(filepath)), [fixture.source, join(fixture.source, "skills")]);
  }
}));

test("uninstall removes CLI caches and leaves MCP files and market registration untouched", () => withFixture((fixture) => {
  const marketplace = join(fixture.home, ".agents/plugins/marketplace.json");
  const mcp = { name: "media-io", source: { source: "local", path: "./plugins/media-io" } };
  writeFile(marketplace, JSON.stringify({ name: "personal", plugins: [mcp, { name: "media-io-cli" }] }));
  const mcpPaths = [
    "plugins/media-io",
    ".codex/plugins/cache/wondershare-media-io/media-io",
    ".codex/plugins/cache/media-io/media-io",
    ".claude/plugins/cache/wondershare-media-io/media-io",
    ".codex/.tmp/marketplaces/wondershare-media-io",
    ".codex/.tmp/marketplaces/media-io",
  ];
  const cliPaths = [
    "plugins/media-io-cli",
    ".codex/plugins/cache/wondershare-media-io-cli/media-io-cli",
    ".codex/plugins/cache/personal/media-io-cli",
    ".claude/plugins/cache/wondershare-media-io-cli/media-io-cli",
    ".codex/.tmp/marketplaces/wondershare-media-io-cli",
  ];
  for (const filepath of [...mcpPaths, ...cliPaths]) writeFile(join(fixture.home, filepath, "marker"), "keep");
  const output = runFunctions("uninstall-mediaio.sh", fixture, "remove_codex_plugin\nremove_claude_plugin\n");
  for (const filepath of mcpPaths) assert.ok(existsSync(join(fixture.home, filepath, "marker")), filepath);
  for (const filepath of cliPaths) assert.equal(existsSync(join(fixture.home, filepath)), false, filepath);
  assert.deepEqual(JSON.parse(readFileSync(marketplace, "utf8")).plugins, [mcp]);
  assert.ok(output.includes("marketplace remove wondershare-media-io-cli"));
  assert.ok(!/marketplace remove (?:media-io|wondershare-media-io)(?:\n|$)/.test(output));
}));

test("Windows and Shell installers share CLI identity without changing binary release sources", () => {
  for (const filename of ["setup-mediaio.sh", "setup-mediaio.ps1", "uninstall-mediaio.sh", "uninstall-mediaio.ps1"]) {
    const source = readFileSync(join(cliRoot, filename), "utf8");
    assert.ok(source.includes("media-io-cli@wondershare-media-io-cli"), filename);
    assert.ok(source.includes("wondershare-media-io-cli"), filename);
    assert.ok(!/media-io\/plugin(?:[\/"}\s]|$)/.test(source), filename);
    if (filename.startsWith("setup")) {
      assert.ok(source.includes("media-io/plugin-cli/archive/refs/heads/main.zip"), filename);
      assert.ok(source.includes("media-io/cli"), filename);
      assert.ok(source.includes("media-io/skills"), filename);
      assert.ok(source.includes("plugin-cli-main"), filename);
    }
  }
});