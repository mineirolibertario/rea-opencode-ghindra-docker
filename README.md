# REA MCP in Docker

Run [REA (Reverse Engineer Anything)](https://github.com/morluto/rea) as a
containerized MCP server for OpenCode, with the external analysis engines REA
drives already installed.

The second link in the request (`github.com/nationalsecurityagency/`) is
interpreted as [NSA's Ghidra](https://github.com/NationalSecurityAgency/ghidra),
which REA uses as its native-binary/decompiler provider. Ghidra 12.1.4 (the
release REA 6.8.0 is verified against) is built into the image.

## What is in the image

| Component | Version | Used by REA for |
| --- | --- | --- |
| `rea-agents` (REA MCP/CLI) | 6.8.0 (pinned, `REA_VERSION`) | the MCP server and analysis orchestration |
| Node.js | 24.22.1 | REA runtime |
| OpenJDK | 21 (Debian) | Ghidra, JADX, Apktool (Ghidra 12.1.4's declared JDK range) |
| [Ghidra](https://github.com/NationalSecurityAgency/ghidra) | 12.1.4 (verified by REA 6.8.0) | native binaries, decompilation, headless analysis |
| `jadx-headless-mcp` | 0.7.1 (pinned SHA-256) | Android APK/DEX decompilation |
| [Apktool](https://github.com/iBotPeaches/Apktool) | 3.0.3 | Android resource/manifest decoding |
| Android platform-tools (`adb`) | latest (amd64 only) | devices, emulators, logcat, APK pull/push |
| Chromium | Debian trixie | website/browser analysis and screenshots |
| TShark / capinfos | Debian trixie (4.4.x) | packet captures and pcap summaries |
| pwntools | Debian 4.14.1 | ELF diagnostics and recorded crash analysis |
| GNU binutils (`objdump`) | Debian | offline native inspection |
| procps, `prlimit`, `tini`, `jq`, `git`, `python3` | Debian | REA's Linux process checks and tooling |

REA does **not** install or license Hopper, IDA Pro/Hex-Rays, JEB or Kuna. Those
remain caller-supplied commercial tools; a Linux container cannot drive their
GUI-only workflows. Everything above runs headless.

Not included by default (see [Extending the image](#extending-the-image)):
Binwalk 3.1/Unblob (firmware), WABT 1.0.42 (WASM), Rizin, Frida host-process
instrumentation, and USB passthrough.

## Requirements

- Docker Engine 24+ with Compose v2 (`docker compose`)
- `jq` on the host for the assertions in `scripts/test-mcp.sh`
- ~10 GB free disk while building (Ghidra alone is ~570 MB compressed)
- 4 GB RAM for the container (8 GB+ for large Ghidra targets)
- Linux x86_64 or arm64 host. ADB platform-tools are amd64-only.

## Quick start (HTTP server)

```bash
cd /home/sistema/develop/REA
cp .env.example .env          # adjust REA_UID/REA_GID to `id -u` / `id -g`
docker compose build
docker compose up -d
docker compose logs -f rea
```

The MCP endpoint is `http://127.0.0.1:8765/mcp`. If you change `REA_PORT` in
`.env`, that only changes the published host port; the container always listens
on 8765, so use the new host port in client URLs. The endpoint is published on
loopback only because the REA HTTP transport has **no authentication**. Do not
expose it on a public interface.

REA's HTTP transport is stateful and serves one client at a time: a new
`initialize` replaces the previous session. Run one OpenCode instance per HTTP
server; use the stdio option (below) when you need independent servers for
several workspaces.

Health and provider checks:

```bash
docker compose ps
timeout 1 bash -c '</dev/tcp/127.0.0.1/8765' && echo listening
docker compose exec -T rea rea doctor
docker compose exec -T rea rea providers
```

`rea doctor` should report Ghidra, its JDK, JADX and the bundled skill as
healthy. It also lists optional Hopper/IDA/Kuna engines as missing, which is
expected and does not affect the required checks. `scripts/test-mcp.sh` asserts
the required checks and prints the inventory of native providers and tool
capabilities; the toolchain section verifies Apktool, adb, Chromium, TShark and
pwntools directly.

## Configure OpenCode

OpenCode V2 reads MCP servers from `mcp.servers` in `opencode.jsonc`
(project-local) or `~/.config/opencode/opencode.jsonc` (global). The project
config takes precedence for the same server name.

### Option A — remote HTTP server (recommended with compose)

Add this to `opencode.jsonc` in the project you want to analyze:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "rea": {
        "type": "remote",
        "url": "http://127.0.0.1:8765/mcp",
        "oauth": false,
        "timeout": {
          "startup": 60000,
          "catalog": 60000,
          "execution": 43200000
        }
      }
    }
  }
}
```

`oauth: false` is required: REA speaks plain streamable HTTP and has no OAuth
discovery. The long `execution` timeout accommodates Ghidra cold starts and
large analyses. For a global registration, copy the same `mcp` object into
`~/.config/opencode/opencode.jsonc`.

Then:

```bash
opencode mcp list          # should show: ✓ rea connected
```

The first invocation in a new project can briefly print `No MCP servers
configured` or `pending` while OpenCode starts its per-project background
server. Wait a few seconds and run the command again.

Configuration reloads automatically; no restart is needed. In OpenCode, MCP
tools are namespaced as `rea_<tool>` and, under the default Code Mode, grouped
as `tools.rea.<tool>`. MCP prompts appear as commands such as `/rea:<prompt>`.

### Option B — stdio container launched per workspace

This is the best option when the target files live in a project directory.
OpenCode starts the container itself and stops it when the connection closes.

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

`bin/rea-mcp-stdio`:

- uses the `rea-mcp:local` image (build it first with `docker compose build`),
- bind-mounts the current workspace at the **same absolute path** inside the
  container, so paths returned to the agent remain valid,
- runs with your host UID/GID so analysis outputs are not root-owned,
- sets `REA_BROWSER_NO_SANDBOX=true` for containerized Chromium.

Files outside the workspace are not visible by default. Add read-only mounts:

```bash
export REA_EXTRA_MOUNTS="/opt/apps:/opt/apps:ro /tmp:/tmp"
```

OpenCode passes its inherited environment to local servers, so exporting
`REA_EXTRA_MOUNTS` before starting OpenCode is enough.

### Verify the OpenCode connection

```bash
opencode mcp list
```

Expected:

```text
✓ rea  connected
```

Inside an OpenCode session, ask something harmless first:

```text
Use the rea server. Call binary_session with no arguments and tell me whether
a target is open, then list two tools for native and Android analysis.
```

A real investigation then looks like:

```text
Use rea to open /work/samples/app.apk and explain its manifest permissions and
the code paths behind the exported services. Show the evidence.
```

For the stdio option, use a path inside your OpenCode workspace instead of
`/work`.

## How files and paths work

The HTTP container only sees `/work`:

| Host | Container | Access |
| --- | --- | --- |
| `./workspace` (or `REA_WORKSPACE`) | `/work` | read/write |
| everything else | not mounted | invisible |

Put targets under `./workspace`, or change `REA_WORKSPACE` in `.env`:

```bash
REA_WORKSPACE=/home/sistema/develop/targets
docker compose up -d
```

When asking the agent about a file, give it the container path
(`/work/samples/foo.bin`, or `/work/foo.apk`). If you want host absolute paths
to work, add a bind mount with the same path on both sides in
`docker-compose.yml`:

```yaml
    volumes:
      - ${REA_WORKSPACE:-./workspace}:/work
      - /home/sistema/develop/targets:/home/sistema/develop/targets:ro
```

With the stdio wrapper this is automatic: the workspace is mounted at its host
path, so `cwd`-relative and absolute workspace paths both work.

Local web targets: `127.0.0.1` inside the container is the container, not your
host. The compose service has `host.docker.internal` mapped to the host
gateway, so pass `http://host.docker.internal:3000` to browser/website tools.
For native apps that call `localhost`, either run the target in the container or
use `network_mode: host` (Linux).

Chromium is available as `/usr/bin/chromium` and as the alias
`/opt/chromium/chrome` (the path used in REA's browser-scenario examples). Set
`browser.executable_path` to either one when a browser scenario requires it.

## Test without OpenCode

The included script builds, runs `rea doctor` (asserting Ghidra, its JDK, JADX
and the bundled skill), prints the toolchain versions and provider inventory,
starts the HTTP server, performs an MCP handshake (`initialize` →
`tools/list` → `tools/call binary_session`), and finally prints
`opencode mcp list`:

```bash
scripts/test-mcp.sh
```

Useful variants:

```bash
scripts/test-mcp.sh --no-build   # reuse the current image
scripts/test-mcp.sh --stop       # stop compose when the test finishes
```

Manual HTTP handshake:

```bash
curl -sS -D /tmp/rea-headers.txt -X POST http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-06-18",
      "capabilities": {},
      "clientInfo": { "name": "curl", "version": "0" }
    }
  }'
grep -i mcp-session-id /tmp/rea-headers.txt
```

The response is JSON or an SSE `data:` frame containing `serverInfo`; the
`Mcp-Session-Id` response header is required for later requests. The full smoke
test in `docker/mcp-smoke.mjs` shows the exact sequence.

Test stdio directly (this is what OpenCode launches):

```bash
docker compose run --rm --no-deps -T rea rea mcp doctor
```

Exercise Ghidra itself with a real headless analysis (takes ~25 seconds for
`/bin/ls` on a warm machine):

```bash
docker compose exec -T rea rea analyze /bin/ls --provider ghidra --format json |
  jq -r '.analysis_profile.parameters.upstream_analysis_profile.provider.version'
# 12.1.4
```

The compose service exports the installed tool paths, so `docker compose exec`
one-off commands see the same Ghidra/JADX/Apktool/browser/TShark configuration
as the long-running MCP server.

## Common analysis examples (CLI inside the container)

The image also contains REA's CLI, so you can validate behavior without an
agent:

```bash
# Inventory an APK
docker compose exec -T rea rea inspect-artifact /work/samples/app.apk --json

# Static JavaScript / Electron app
docker compose exec -T rea rea analyze-javascript-application /work/app --json

# Native binary through Ghidra
docker compose exec -T rea rea analyze /work/samples/crackme --provider ghidra --json

# pcap inspection through TShark
docker compose exec -T rea rea inspect-pcap-capture /work/samples/http.pcap --json

# Full readiness report
docker compose exec -T rea rea doctor --format json
```

## Extending the image

The build args disable optional tool groups when you need a smaller image:

```bash
INSTALL_GHIDRA=0 INSTALL_ANDROID=0 INSTALL_BROWSER=0 \
INSTALL_TSHARK=0 INSTALL_PWNTOOLS=0 docker compose build
```

Add missing providers by extending the Dockerfile:

**Firmware (Binwalk 3.1 + Unblob 26.6).** REA requires Binwalk 3.1.x (not the
2.x package in Debian) and Unblob 26.6.x, plus their external extractors:

```dockerfile
# Binwalk 3 is a Rust crate; compile it in a builder stage.
FROM rust:1-slim AS binwalk
RUN cargo install --locked binwalk@3.1.0

FROM node:24.22.1-trixie-slim
COPY --from=binwalk /usr/local/cargo/bin/binwalk /usr/local/bin/binwalk
RUN pip3 install --break-system-packages --no-cache-dir unblob==26.6.4 \
 && apt-get update && apt-get install -y --no-install-recommends \
      p7zip-full cabextract cpio lz4 lzip lzop rpm2cpio sleuthkit squashfs-tools \
      unar zstd && rm -rf /var/lib/apt/lists/*
ENV REA_BINWALK_COMMAND=/usr/local/bin/binwalk \
    REA_UNBLOB_COMMAND=/usr/local/bin/unblob
```

**WASM.** REA expects WABT 1.0.42; install the release matching your
architecture and expose `wasm2wat`/`wasm-objdump` on `PATH`.

**Rizin.** Install a Rizin release and put `rizin` on `PATH`.

**Frida / process instrumentation.** Frida is already an optional npm dependency
of REA, but attaching to processes needs extra privileges. For host processes:

```bash
REA_DOCKER_ARGS="--pid=host --cap-add SYS_PTRACE --security-opt seccomp=unconfined" \
  bin/rea-mcp-stdio
```

or uncomment the equivalent block in `docker-compose.yml`.

**Android devices.** Uncomment the `/dev/bus/usb` mapping in
`docker-compose.yml` and make sure the host udev rules allow the device. Network
emulators are reachable via `host.docker.internal`/the host IP without USB
passthrough. ADB is only installed on amd64 images.

**Commercial providers.** Hopper's headless mode is macOS-only; IDA and JEB can
serve MCP endpoints on the host. Point REA at them with the environment
variables documented in REA's `docs/ida-provider.md`, `docs/jeb-analysis.md`
and `docs/kuna-provider.md`, and make the endpoint reachable from the container
(`host.docker.internal`). Licensing remains your responsibility.

## Troubleshooting

**`rea doctor` says Ghidra/Java is unavailable.** REA 6.8.0 expects the Ghidra
12.1.x line and a JDK within that installation's declared range. Confirm Java 21
and Ghidra inside the container:

```bash
docker compose exec -T rea sh -c 'java -version; echo $JAVA_HOME; ls $GHIDRA_INSTALL_DIR/support/analyzeHeadless'
```

If you override `JAVA_HOME` or `GHIDRA_INSTALL_DIR`, they must point at paths
inside the container.

**Ghidra is killed during a large analysis.** Raise the JVM heap in `.env`
(`GHIDRA_HEADLESS_MAXMEM=8G`) and give Docker more memory. A container OOM kill
leaves no Ghidra error in the logs.

**Chromium fails to launch.** The image sets `REA_BROWSER_NO_SANDBOX=true`
because containers normally cannot provide Chromium's sandbox. Also give the
container at least 2 GB of shared memory:

```yaml
    shm_size: 1gb
```

**`opencode mcp list` shows the server as disconnected.** Check the container
is listening on the same port and that the Host header is allowed:

```bash
docker compose logs --tail=100 rea
timeout 1 bash -c '</dev/tcp/127.0.0.1/8765' && echo listening
```

`MCP_ALLOWED_HOSTS` must contain every client host name/IP (without protocol or
port). The default is `127.0.0.1,localhost,rea,host.docker.internal`. If you add
a hostname or use a reverse proxy, add it there and restart the service.

**Files created in `/work` are owned by another UID.** Set `REA_UID` and
`REA_GID` in `.env` to your `id -u` / `id -g` and recreate the container:

```bash
docker compose down && docker compose up -d
```

**Ghidra project/cache reuse between calls.** The HTTP server keeps the active
session in memory while it runs. Restarting the container clears it; use REA's
`REA_GHIDRA_PROJECT_PATH` / snapshot tools when you need persistence.

## Security notes

- The MCP HTTP transport is unauthenticated plain HTTP. It is bound to
  `127.0.0.1` by default for that reason.
- Analysis targets are untrusted input. Run the container with only the mounts
  you need, and prefer read-only mounts for targets you do not want modified.
- Do not mount the Docker socket or your whole home directory unless you accept
  that the MCP server can read those paths.
- REA's process/Frida tools execute or attach to targets with your user's
  permissions. They are not a sandbox.
- Commercial tools (IDA, Hopper, JEB) are not included and grant no license.

## Files in this repository

| Path | Purpose |
| --- | --- |
| `Dockerfile` | REA + Ghidra/JADX/Apktool/adb/Chromium/TShark image |
| `docker-compose.yml` | Persistent HTTP MCP service on loopback |
| `.env.example` | Build/runtime settings |
| `bin/rea-mcp-stdio` | stdio container launcher for OpenCode local MCP |
| `opencode.example.jsonc` | OpenCode V2 MCP configuration examples |
| `docker/entrypoint.sh` | Resolves JDK/tool paths for arbitrary UIDs |
| `docker/mcp-smoke.mjs` | SDK-free MCP HTTP handshake test |
| `scripts/test-mcp.sh` | End-to-end build/doctor/serve/test script |
| `workspace/` | Default host directory mounted at `/work` |

## Updating

```bash
# New REA npm release
REA_VERSION=6.9.0 docker compose build --pull

# New Ghidra release (check the release asset date first). REA accepts newer
# 12.x builds, but they may require a newer JDK than the image ships.
GHIDRA_VERSION=12.1.4 GHIDRA_BUILD=20260921 docker compose build --no-cache
```

Pin versions in `.env` for reproducible images.
