# Media.io CLI & Plugin Setup

Set up or update Media.io so I can generate images and videos from here.

1. Install or update the CLI: run `npm i -g @mediaio/cli`.
2. Check `mediaio whoami`. If it shows I'm signed in, skip login. If not, run `mediaio auth login` and let me complete the sign-in in the browser it opens.
3. Install or update the companion plugin: run `codex plugin marketplace add media-io/plugin`.

If any install, update, or sign-in step fails, read the Troubleshooting section below and follow it to diagnose and fix the problem automatically. Only ask me for the steps you can't do yourself, like browser sign-in or granting permissions.

Once that's done, let me know when it's ready.






# Media.io CLI — Install & Update Troubleshooting (INSTALL-HELP.md)

> This document is written for **AI assistants (Codex / VS Code / Claude desktop, etc.)**. When a user
> follows the short setup prompt and installing or updating `@mediaio/cli` and the plugin fails, read
> this guide and follow the **Self-check → Locate by symptom → Apply fix** flow to **resolve the issue
> automatically for the user**. Only ask the user to act for steps you cannot do yourself (completing the
> browser sign-in, granting permissions).
>
> A Chinese copy for the team is available at [INSTALL-HELP.zh.md](INSTALL-HELP.zh.md); keep both in sync.
>
> Public URL: <https://github.com/media-io/cli/blob/main/INSTALL-HELP.md>

---

## 0. Run the self-check first

Whether it's an install or an update problem, collect facts before deciding what to fix. Run each command
and note its output:

```bash
node -v            # Node.js version, must be >= 14, LTS 20/22 recommended
npm -v             # is npm available
git --version      # required when installing skills / the plugin
mediaio --version  # is the CLI installed (reports "command not found" if not)
mediaio whoami     # are you signed in (reports "not signed in" if not)
mediaio config get # current environment (test/beta/prod); don't install into the wrong one
```

The same commands work in Windows PowerShell.

Decision order:
1. `node -v` / `npm -v` fails → fix the [Node.js environment](#1-nodejs--npm-environment) first.
2. `mediaio --version` fails → the CLI is not installed; see [CLI install / download failures](#2-cli-install-or-postinstall-download-failures).
3. `mediaio --version` works but `mediaio whoami` shows not signed in → see [Sign-in / authorization failures](#4-sign-in--authorization-failures).
4. Everything works but generate/upload errors → see [Runtime permissions & environment](#5-runtime-permissions-sandbox--environment).

---

## 1. Node.js / npm environment

`@mediaio/cli` is installed globally via npm and requires **Node.js ≥ 14**; install an **LTS release (20 or 22)**.

Check:

```bash
node -v
npm -v
```

If `node` is missing or too old, guide the user to install it (do not silently change the system without
confirmation):

- **macOS**: prefer `brew install node` (Homebrew), or download the LTS installer from <https://nodejs.org>.
- **Windows**: download and run the LTS installer from <https://nodejs.org>, or `winget install OpenJS.NodeJS.LTS`.
- **Cross-platform (version manager)**: `nvm` (macOS/Linux) or `nvm-windows`, then `nvm install 22 && nvm use 22`.

After installing, open a new terminal and run `node -v` again. Note: right after installing Node.js, an
already-open Codex/terminal session may still use the old PATH — **restart the client or open a new
terminal** so it can find `node`/`npm`/`mediaio`.

---

## 2. CLI install or postinstall download failures

Install command:

```bash
npm install -g @mediaio/cli
```

During install, `postinstall` downloads the binary matching the current OS into the package's `vendor/`
directory. Common failures and fixes:

### 2.1 Extraction / `tar` error (common on Windows)

Typical error:

```
tar: Error opening archive: Failed to open '\\.\tape0'
@mediaio/cli: install failed — spawnSync tar EOF
```

Cause: an older installer mis-parsed the `tar` arguments when extracting the binary on Windows. **This is
fixed in newer versions** (the archive is now piped to `tar` via stdin). Fix:

```bash
npm cache clean --force
npm uninstall -g @mediaio/cli
npm install -g @mediaio/cli@latest
```

Confirm you got the latest version: `mediaio --version`. If it still fails, confirm `tar` is available
(Windows 10 1803+ ships `bsdtar`): running `tar --version` should print output.

### 2.2 `binary not found at .../vendor/mediaio`

Means `postinstall` did not run or was skipped (e.g. installed with `--ignore-scripts`). Reinstall to
trigger postinstall:

```bash
npm uninstall -g @mediaio/cli
npm install -g @mediaio/cli
```

### 2.3 Download returns 404

The installer downloads `mediaio_<version>_<os>_<arch>.tar.gz` from GitHub Releases. An `HTTP 404` usually
means the version does not match a released asset. Fix by installing `@latest` (aligns to a published
version):

```bash
npm install -g @mediaio/cli@latest
```

If it still 404s, the network may not be able to reach `github.com` — ask the user to check their proxy /
corporate network and retry.

### 2.4 Unsupported platform

The installer only supports `darwin | linux | windows` × `amd64 | arm64`. On `unsupported platform`,
confirm the user's system is in range; `win32` maps to `windows`.

### 2.5 Command conflict: `mi` doesn't work

The CLI provides two equivalent commands, `mediaio` and `mi`. If the user's machine already has another
`mi` command causing a PATH conflict, **just use `mediaio`** — it is functionally identical.

---

## 3. Plugin / Skills install failures

Choose one install method (**do not install both the plugin and skills** — the plugin already bundles the
skills):

- Plugin (recommended): install the Mediaio plugin from <https://github.com/media-io/plugin>.
- Skills: `npx skills add media-io/plugin -g` (on Codex you can add `--agent codex`).

Common problems:

- **`npx skills add ...` fails**: usually missing `git`. Confirm with `git --version`; on Windows install
  from <https://git-scm.com>, on macOS use `xcode-select --install` or `brew install git`, then retry.
- **Unpack error / network timeout**: clean and retry `npx --yes skills add media-io/plugin -g`; confirm
  access to `github.com`.
- **Skills don't take effect after install**: skills are installed into the client's skills directory
  (e.g. `~/.codex/skills/`). **Start a new task or restart Codex / the client** so it reloads the skills.

---

## 4. Sign-in / authorization failures

Sign-in uses a browser OAuth2 flow (Authorization Code + PKCE). Relevant commands:

```bash
mediaio auth login   # open the browser to sign in; credentials stored locally
mediaio whoami       # show current identity locally (no network call)
mediaio auth logout  # clear locally stored credentials
```

By symptom:

### 4.1 `whoami` shows not signed in

Guide the user to run `mediaio auth login` and complete sign-in in the browser that opens, then confirm
with `mediaio whoami`. **The AI must not click through the browser for the user** — just say "I've opened
the sign-in page; please complete sign-in in the browser and let me know."

### 4.2 Two authorization pages / no authorize button / callback never completes

Clear everything and sign in again to avoid multiple concurrent auth flows:

```bash
mediaio auth logout
mediaio auth login
```

**Complete only one browser sign-in** — do not open multiple authorization pages. If a desktop client can
never complete the callback, complete sign-in in the system default browser instead.

### 4.3 Error `The requested client must be the same as the client that obtained the code`

The client that obtained the auth code differs from the client exchanging it for a token (often triggered
by opening the authorization page more than once). Fix:

```bash
mediaio auth logout   # clear the half-finished credentials
mediaio auth login    # sign in again within a single browser flow
```

If it still reproduces after clearing and retrying, it is a server-side OAuth configuration issue —
**collect the exact error text and report it to Media.io** (see the feedback channel at the end); do not
have the user retry endlessly.

### 4.4 Signed out automatically after a while

Credentials expired or were cleared. Run `mediaio auth login` again. If it happens often, record how often
it reproduces along with `mediaio config get` output for the report.

### 4.5 Wrong environment causing "signed in but no access"

Credentials are isolated per environment (test/beta/prod). Confirm the environment first:

```bash
mediaio config get     # check the active environment
mediaio config clear   # clear the current environment's stored config/credentials
```

**Do not switch environments on your own with `mediaio config set`.** Changing the active environment
affects everything the user does, so leave that decision to the user. If `mediaio config get` shows the
wrong environment, tell the user which one is active and let them decide whether to switch. You may run
`mediaio config clear` to clear stale credentials for the current environment, then have the user run
`mediaio auth login` again. The sign-in environment must match the environment the user actually uses.

---

## 5. Runtime permissions, sandbox & environment

Sign-in and install both succeed, but generating images/videos or uploading files gets interrupted or the
file can't be read — usually a **client sandbox / permission** issue.

### 5.1 Generation/execution interrupted, asking for "full access"

Clients like Codex run in a restricted sandbox by default and block the CLI's network or file access. Ask
the user to **grant the agent full / file access** (Codex: enable full access / "full access" for the
project in the client's permission settings), then re-run the task. The AI cannot elevate its own
permissions and must explicitly tell the user to authorize it in the client settings.

### 5.2 Image pasted into the chat box can't be read by the CLI

The CLI can only read real file paths on the local disk. If the user pasted an image into the chat box,
first **save it to local disk**, then pass the local path to the CLI (`mediaio upload create <local file path>`).

### 5.3 Uploads/generation occasionally interrupt and exit

Retry once first; if it persists, collect the failing command, the full error, `mediaio config get`, and
`mediaio whoami` status, and report them together.

---

## 6. Clean reinstall (last resort)

If nothing above works, start over from scratch:

```bash
npm uninstall -g @mediaio/cli
npm cache clean --force
npm install -g @mediaio/cli@latest
mediaio --version
mediaio auth login
```

For the plugin/skills, do the same: uninstall first, then reinstall per [Section 3](#3-plugin--skills-install-failures)
and restart the client.

---

## 7. Command cheat sheet

```bash
mediaio auth login          # sign in
mediaio whoami              # show local identity
mediaio account status      # show account & credits
mediaio config get          # show current environment & config
mediaio config clear        # clear the current environment's stored config/credentials
mediaio --version           # show CLI version
mediaio <command> --help    # show usage for any subcommand
```

> `mediaio config set <test|beta|prod>` switches environments — leave it to the user; the AI must not run
> it automatically to change environments.

---

## 8. Still stuck: collect diagnostics and report

If auto-fixing fails, compile the following for the user to file a report:

- OS and version, client (Codex / VS / Claude) and version;
- output of `node -v`, `npm -v`, `git --version`, `mediaio --version`;
- the full failing command and the full error text;
- output of `mediaio config get` and `mediaio whoami` (do not leak the token).

Feedback channel: the MI Codex plugin private-beta experience feedback document.
