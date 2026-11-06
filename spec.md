# REA MCP Docker — rebuild specification

Notes needed to recreate, resize, and re-validate this stack from scratch.
Companion files: `compact.md` (summary) and `review.md` (self-review).

---

## 1. Goal and constraints

Reproduce a container that:

1. runs REA (`rea mcp`) as an MCP server over **HTTP** (persistent) and can
   also be launched over **stdio** (one container per OpenCode workspace);
2. ships the native analysis tooling REA drives: **Ghidra**, **JADX**,
   **Apktool**, **adb**, **Chromium**, **TShark**, **pwntools**;
3. is usable by an arbitrary host UID/GID so files in the mounted workspace
   stay owned by the caller;
4. is validated without an agent (`scripts/test-mcp.sh`) and with OpenCode.

Non-goals: commercial engines (Hopper/IDA/JEB/Kuna), firmware extractors
(Binwalk/Unblob), WASM (WABT), Rizin, Frida host instrumentation, USB
passthrough. They are documented as extensions, not baked in.

**Hard constraints discovered while building**

- REA 6.8.0 is verified against **Ghidra 12.1.4 + JDK 21**. Ghidra 12.2
  declares JDK 25 and fails REA's readiness checks on this image.
- REA's HTTP transport has **no authentication**, so publish it on
  `127.0.0.1` only.
- REA's HTTP transport is **stateful and single-client**: a new `initialize`
  replaces the previous session. Use stdio for multiple workspaces.
- `rea doctor` reports commercial providers as missing and can exit non-zero;
  assert only the checks this image owns.

---

## 2. Pinned versions

| Component | Version | Source / identifier |
| --- | --- | --- |
| Node base | `node:24.22.1-trixie-slim` | Docker Hub |
| REA | `rea-agents@6.8.0` | npm global |
| OpenJDK | `openjdk-21-jdk-headless` | Debian trixie |
| Ghidra | `12.1.4`, build `20260921` | GitHub release |
| JADX headless MCP | `0.7.1` | GitHub release, SHA-256 pinned |
| Apktool | `3.0.3` | GitHub release |
| Android platform-tools | "latest" (not pinned) | `dl.google.com` |
| Chromium | Debian trixie package | apt |
| TShark / capinfos | Debian trixie (4.4.19 at validation) | apt |
| pwntools | Debian `python3-pwntools` (4.14.1) | apt |
| binutils, procps, `prlimit`, tini, jq, git, python3 | Debian trixie | apt |

Exact artifact URLs:

```text
https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip
https://github.com/1013503897/jadx-headless-mcp/releases/download/v0.7.1/jadx-headless-mcp-0.7.1-all.jar
https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar
https://dl.google.com/android/repository/platform-tools-latest-linux.zip
```

JADX JAR checksum used by the build:

```text
6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75
```

---

## 3. Layered design

```text
Dockerfile layers (bottom → top)
  1. node:24.22.1-trixie-slim
  2. apt: ca-certificates curl git jq file unzip zip xz-utils procps tini
          python3 python3-pip openjdk-21-jdk-headless binutils
          [+ chromium fonts-*] [+ tshark] [+ python3-pwntools]
  3. writable dirs: /tmp/rea-home /tmp/rea-cache /opt/rea-tools /work
  4. npm -g rea-agents@6.8.0; rea --version
  5. /opt/rea-skill: HOME=/opt/rea-skill rea setup --yes --skill
  6. /opt/ghidra: download + unzip Ghidra zip
  7. /opt/rea-tools: jadx-headless-mcp.jar (sha256 -c), apktool.jar,
     /usr/local/bin/apktool wrapper; adb on amd64 only
  8. /opt/chromium/chrome -> /usr/bin/chromium (only if present)
  9. entrypoint + mcp-smoke.mjs
 10. USER node, WORKDIR /work, EXPOSE 8765
     ENTRYPOINT docker-entrypoint.sh
     CMD ["rea","mcp","--http"]
```

Runtime configuration is resolved twice, intentionally:

- `docker/entrypoint.sh` exports the paths for the long-running server.
- `docker-compose.yml` sets the same paths in `environment:` so
  `docker compose exec ... rea ...` sees the same configuration.

`docker/entrypoint.sh` also:

- derives `JAVA_HOME` from `javac` if unset;
- falls back to `HOME=/tmp/rea-home` when the image home is not writable;
- copies `/opt/rea-skill/.agents/skills/reverse-engineer-anything` into
  `$HOME/.agents/skills/` so `rea doctor`'s skill identity check reports
  `aligned` for arbitrary UIDs.

---

## 4. Repository layout

```text
REA/
├── Dockerfile              # image definition and version args
├── docker-compose.yml      # persistent HTTP service
├── .env.example            # copy to .env; build/runtime knobs
├── .dockerignore           # excludes .git, .env, workspace, logs
├── bin/rea-mcp-stdio       # stdio launcher (docker run -i --rm)
├── docker/entrypoint.sh    # PATH/JAVA_HOME/skill/HOME bootstrap
├── docker/mcp-smoke.mjs    # raw HTTP MCP handshake, no SDK
├── scripts/test-mcp.sh     # build + doctor + toolchain + serve + smoke
├── opencode.example.jsonc  # remote and local MCP examples
├── workspace/              # mounted at /work
├── README.md               # user-facing docs
├── compact.md              # summary
├── spec.md                 # this file
└── review.md               # self-review
```

Build args (`Dockerfile` + `docker-compose.yml`):

| Arg | Default | Effect |
| --- | --- | --- |
| `NODE_VERSION` | `24.22.1` | base tag |
| `REA_VERSION` | `6.8.0` | npm package |
| `GHIDRA_VERSION` | `12.1.4` | release |
| `GHIDRA_BUILD` | `20260921` | release asset date |
| `JADX_MCP_VERSION` | `0.7.1` | JADX release |
| `APKTOOL_VERSION` | `3.0.3` | Apktool release |
| `INSTALL_GHIDRA` | `1` | Ghidra + JDK-checked analysis |
| `INSTALL_ANDROID` | `1` | JADX, Apktool, adb |
| `INSTALL_BROWSER` | `1` | Chromium + fonts |
| `INSTALL_TSHARK` | `1` | TShark/capinfos |
| `INSTALL_PWNTOOLS` | `1` | pwntools |

---

## 5. Prerequisites

- Docker Engine 24+ / Compose v2 (`docker compose version`)
- `jq` on the host (used by `scripts/test-mcp.sh`)
- Linux x86_64 or arm64; **adb platform-tools are amd64-only**
- Disk: ~5 GB final image + ~10 GB build cache/scratch for the full build
- RAM: 4 GB minimum; 8 GB+ for large Ghidra targets
- Optional: `opencode` CLI (v2) for the integration check

---

## 6. Build: full image, with Chromium

```bash
cd /home/sistema/develop/REA
cp .env.example .env
sed -i "s/^REA_UID=.*/REA_UID=$(id -u)/; s/^REA_GID=.*/REA_GID=$(id -g)/" .env
docker compose build
docker image ls rea-mcp:local
```

Expected: **4.59 GB** (measured, amd64). Approximate installed footprint of the
largest pieces inside the image:

| Path / package | Size |
| --- | --- |
| `/opt/ghidra` | 876 MB |
| `/usr/lib/chromium` (+ `chromium`/`chromium-common` packages ≈ 391 MB) | 381 MB |
| `/usr/local/lib/node_modules` (REA) | 288 MB |
| `/usr/lib/jvm` (JDK 21) | 287 MB |
| `/opt/rea-tools` (JADX + Apktool) | 56 MB |
| pwntools | 46 MB |
| `/opt/android-platform-tools` | 22 MB |

Run it:

```bash
docker compose up -d --wait
# endpoint: http://127.0.0.1:8765/mcp
```

Compose behavior to preserve when rebuilding:

- `ports: 127.0.0.1:${REA_PORT:-8765}:8765` — never bind `0.0.0.0`.
- `user: ${REA_UID:-1000}:${REA_GID:-1000}` and `init: true`.
- `shm_size: 1gb` for Chromium; `stop_grace_period: 30s`.
- `REA_BROWSER_NO_SANDBOX=true` (no user namespaces in most containers).
- `extra_hosts: host.docker.internal:host-gateway`.
- healthcheck: `timeout 2 bash -c '</dev/tcp/127.0.0.1/8765'`, 12 retries.
- volume `${REA_WORKSPACE:-./workspace}:/work`, `working_dir: /work`.

---

## 7. Build: lean image, without Chromium

Chromium is the largest removable slice (~0.97 GB image delta measured) and
is only needed for `capture-browser-scenario`,
`analyze-web-bundle`, `capture-electron-scenario`, and website/JS-bundle work.

```bash
docker build --build-arg INSTALL_BROWSER=0 -t rea-mcp:nobrowser .
# or, to keep the compose workflow:
REA_IMAGE=rea-mcp:nobrowser INSTALL_BROWSER=0 docker compose build
```

Measured result: **3.62 GB** (delta **~0.97 GB** vs the 4.59 GB full image).
Verified in the lean image: `rea doctor` passes all Ghidra/JADX checks and the
skill is aligned; `rea analyze /bin/ls --provider ghidra` returns 12.1.4;
Chromium is absent.

What changes:

- `chromium`, `fonts-dejavu-core`, `fonts-liberation` are not installed.
- `/opt/chromium/chrome` is not created (the Dockerfile guards the symlink).
- `REA_BROWSER_EXECUTABLE` still points at `/usr/bin/chromium` in
  `docker-compose.yml`; the path simply does not exist and browser tools
  report the executable as unavailable. This is harmless for non-browser work.
  Note that `REA_BROWSER_EXECUTABLE=` in `.env` does **not** remove it: Compose
  uses `${REA_BROWSER_EXECUTABLE:-/usr/bin/chromium}`, and `:-` falls back to
  the default for both unset and empty values. Remove the line in a Compose
  override (or replace the value with an explicit unused path) if you want the
  variable absent.
- `REA_BROWSER_NO_SANDBOX` and `shm_size` remain harmless; drop `shm_size` if
  you never add a browser.
- Browser/Electron/website scenarios are **not available**. Everything else
  (Ghidra, JADX/Apktool/adb, TShark, pwntools, native/ELF/APK/pcap work) works
  unchanged.

Smaller still (drop browser + packet + exploit helpers):

```bash
docker build \
  --build-arg INSTALL_BROWSER=0 \
  --build-arg INSTALL_TSHARK=0 \
  --build-arg INSTALL_PWNTOOLS=0 \
  -t rea-mcp:minimal .
```

A minimal build keeps Ghidra + Android. To go below that, also pass
`INSTALL_ANDROID=0`, or `INSTALL_GHIDRA=0` for an MCP-shell-only image
(REA then has no native decompiler).

If browser work is occasional, keep the full image as a separate tag or a
Compose `profiles:` service instead of paying the size in the default image:

```yaml
services:
  rea:
    image: rea-mcp:nobrowser
  rea-browser:
    profiles: [browser]
    image: rea-mcp:local
    # same volumes/ports, different REA_PORT
```

Note: REA's browser tools take an executable path, not a remote CDP URL, so
"split browser into another container" requires adding a browser to that
container or running scenarios there; it is not a drop-in remote browser.

---

## 8. Runtime model and paths

### HTTP (Compose)

- Container listens on `0.0.0.0:8765`; host publishes `127.0.0.1:8765`.
- `MCP_ALLOWED_HOSTS=127.0.0.1,localhost,rea,host.docker.internal` — add any
  new client Host header (bare host/IP, no scheme or port).
- Only `${REA_WORKSPACE}` is visible, at `/work`.
- Container `127.0.0.1` is the container. Reach host services via
  `host.docker.internal`.

### stdio (`bin/rea-mcp-stdio`)

- Runs `docker run --rm -i --init --user UID:GID`.
- Bind-mounts the workspace **at the same absolute path**, so agent-visible
  paths are valid inside the container.
- `HOME=/tmp/rea-home`, `REA_BROWSER_NO_SANDBOX=true`.
- `REA_EXTRA_MOUNTS` (space-separated `src:dst[:ro]`) and `REA_DOCKER_ARGS`
  (raw extra docker flags) extend it.
- The image must already exist (`docker compose build` first).

---

## 9. OpenCode configuration

OpenCode V2 key: `mcp.servers`.

Remote (recommended with Compose):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "rea": {
        "type": "remote",
        "url": "http://127.0.0.1:8765/mcp",
        "oauth": false,
        "timeout": { "startup": 60000, "catalog": 60000, "execution": 43200000 }
      }
    }
  }
}
```

- `oauth: false` is required (plain streamable HTTP, no OAuth discovery).
- Long `execution` timeout covers Ghidra cold starts and large analyses.

Local stdio:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "rea": {
        "type": "local",
        "command": ["/home/sistema/develop/REA/bin/rea-mcp-stdio"],
        "cwd": "."
      }
    }
  }
}
```

Verify:

```bash
opencode mcp list        # ✓ rea connected
```

MCP tools surface as `rea_<tool>` (and `tools.rea.<tool>` in Code Mode).
Prompts surface as `/rea:<prompt>`. First invocation in a new project may
briefly show `No MCP servers configured`/`pending`; retry after the per-project
server starts.

---

## 10. Validation gates

```bash
scripts/test-mcp.sh              # full build + all checks
scripts/test-mcp.sh --no-build   # reuse rea-mcp:local
scripts/test-mcp.sh --stop       # stop compose at the end
```

The script must assert:

1. `rea --version` = `6.8.0`.
2. `rea doctor --format json` has `.scope_checks[]` with `ok: true` for
   `ghidra`, `ghidra-version`, `ghidra-headless`,
   `ghidra-native_decompiler`, `ghidra-java`, `jadx`.
3. `.identity.skill.state == "aligned"`.
4. Toolchain executes: `apktool --version`, `adb version`, `chromium --version`,
   `tshark --version`, `capinfos --version`, `import pwnlib`.
5. `docker compose up -d --wait` reaches the healthcheck; TCP 8765 is open.
6. `node /opt/rea-tools/mcp-smoke.mjs` completes
   `initialize` → `tools/list` → `tools/call binary_session`
   (229 tools at REA 6.8.0; `binary_session` reports OK).
7. `opencode mcp list` shows connected when a config exists.

Manual checks:

```bash
docker compose exec -T rea rea mcp doctor
docker compose exec -T rea rea analyze /bin/ls --provider ghidra --format json \
  | jq -r '.analysis_profile.parameters.upstream_analysis_profile.provider.version'
# 12.1.4
```

---

## 11. Rebuild checklist (clean machine)

1. `cp .env.example .env`; set `REA_UID`/`REA_GID` (`id -u`, `id -g`).
2. `docker compose build` (full) or the no-browser build command.
3. `docker compose up -d --wait`.
4. `scripts/test-mcp.sh --no-build`.
5. `opencode mcp list` with `opencode.example.jsonc` copied to
   `opencode.jsonc` (remote), or the local entry.
6. Put targets in `workspace/`; address them as `/work/<name>`.

Version bumps:

```bash
REA_VERSION=6.9.0 docker compose build --pull
GHIDRA_VERSION=12.1.4 GHIDRA_BUILD=20260921 docker compose build --no-cache
```

After changing Ghidra, re-run `rea doctor` and a real `rea analyze`.
Check the Ghidra release notes for its **minimum JDK** before bumping the
`openjdk-21` package.

---

## 12. Known gotchas

| Symptom | Cause / fix |
| --- | --- |
| `doctor` fails on Ghidra/Java | Ghidra line vs JDK mismatch (12.2 needs JDK 25). Keep 12.1.4 + JDK 21. |
| `doctor` exits non-zero but required checks pass | Missing commercial providers are expected; assert only owned checks. |
| `rea analyze` OOM-killed | Raise `GHIDRA_HEADLESS_MAXMEM` and Docker memory. |
| Chromium won't start | Keep `REA_BROWSER_NO_SANDBOX=true` and `shm_size: 1gb`. |
| OpenCode disconnected | Port not published, or Host header not in `MCP_ALLOWED_HOSTS`. |
| Second OpenCode client displaces the first | HTTP transport is single-session; use stdio per workspace. |
| Files owned by wrong UID | Set `REA_UID`/`REA_GID`, recreate container. |
| Browser tools unavailable in lean image | Expected with `INSTALL_BROWSER=0`. |
| adb missing on arm64 | platform-tools are amd64-only by design. |
| Skill check `misaligned` | Ensure the entrypoint seeded `$HOME/.agents/skills/...`; don't override `HOME` with a read-only dir. |

---

## 13. Security requirements

- Bind HTTP to loopback only; it is unauthenticated.
- Mount only the workspace; prefer `:ro` for untrusted targets.
- Do not mount the Docker socket or the whole home directory.
- Analysis targets are hostile input: Ghidra/JADX/parsers can be exploited.
  Run with resource limits and no unnecessary capabilities.
- Frida/USB/`pid: host` are opt-in and enlarge the attack surface.
- Commercial engines are not licensed or included.
