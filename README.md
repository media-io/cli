# @mediaio/cli

Media.io AI CLI — generate images and videos from the terminal.

## Install

```bash
npm install -g @mediaio/cli
```

Postinstall fetches the prebuilt `mediaio` binary for your platform from the
[GitHub release](https://github.com/media-io/cli/releases).

Supported platforms: macOS, Linux, Windows (x64, arm64). Requires Node.js 14+.

## Usage

```bash
mediaio auth login
mediaio model list
mediaio generate create text2image_gpt_image_2 --prompt "a cat in a spaceship"
mediaio --help
```

The package registers a single command: `mediaio`.

## Agent plugins

The Codex and Claude Code plugins in
[media-io/plugin](https://github.com/media-io/plugin) drive this CLI. Install
and sign in to the CLI first; the plugin never installs or repairs it for you.

## Troubleshooting

`binary not found at .../vendor/mediaio` means postinstall did not run:

```bash
npm uninstall -g @mediaio/cli
npm install -g @mediaio/cli
```

Note that `npm install --ignore-scripts` skips the binary download.

## Links

- Product: <https://www.media.io/ai/home>
- Releases: <https://github.com/media-io/cli/releases>
- Terms of Service: <https://www.media.io/terms-of-service.html>
- Privacy Policy: <https://www.media.io/privacy.html>

## License

MIT — see [LICENSE](LICENSE).
