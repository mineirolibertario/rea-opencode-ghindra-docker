# REA MCP in Docker — compact summary

## What was delivered

A self-contained Docker image that runs **REA 6.8.0** as an MCP server with the
analysis engines it drives already installed, plus Compose/OpenCode integration
and a validation script.

| Path | Purpose |
| --- | --- |
| `Dockerfile` | REA + Ghidra 12.1.4 + JDK 21 + JADX + Apktool + adb + Chromium + TShark + pwntools |
| `docker-compose.yml` | Persistent HTTP MCP service, loopback-only, UID/GID mapped, `/work` volume |
| `.env.example` | Pinned versions and runtime settings |
| `docker/entrypoint.sh` | Resolves JDK/tool paths, seeds REA's skill for arbitrary UIDs |
| `docker/mcp-smoke.mjs` | Dependency-free MCP handshake (`initialize` → `tools/list` → `binary_session`) |
| `scripts/test-mcp.sh` | Build → doctor → toolchain → HTTP serve → MCP smoke test |
| `bin/rea-mcp-stdio` | One-shot stdio container for OpenCode local MCP |
| `opencode.example.jsonc` | OpenCode V2 remote and local configuration |
| `README.md` | Setup, OpenCode config, path model, troubleshooting, security |
| `spec.md` | Rebuild notes (full and no-Chromium variants) |
| `review.md` | Self-review, risks, and recommended follow-ups |

## Pinned stack

- Base: `node:24.22.1-trixie-slim` (Debian trixie, amd64/arm64)
- REA: `rea-agents@6.8.0` from npm, global install
- Java: Debian `openjdk-21-jdk-headless`
- Ghidra: `12.1.4`, build `20260921` (the release REA 6.8.0 verifies)
- JADX MCP: `0.7.1`, SHA-256 checked
- Apktool: `3.0.3`; adb: platform-tools latest (amd64 only)
- Chromium: Debian trixie; TShark 4.4.x; pwntools 4.14.1

REA's HTTP MCP endpoint is `http://127.0.0.1:8765/mcp`, published on loopback
only because it has no authentication. The transport is stateful and serves one
client at a time. For per-workspace isolation use `bin/rea-mcp-stdio`.

## Validation performed

- `scripts/test-mcp.sh --no-build --stop` → exit 0.
- `rea doctor` healthy; Ghidra 12.1.4, JDK 21, JADX, bundled skill all aligned.
  Missing Hopper/IDA/Kuna are expected and do not fail the required checks.
- Toolchain: Apktool 3.0.3, adb 1.0.41, Chromium 156.0.8078.79, TShark/capinfos
  4.4.19, pwntools 4.14.1.
- Real Ghidra analysis: `rea analyze /bin/ls --provider ghidra` returned Ghidra
  12.1.4 in ~24.5 s.
- MCP handshake: server `rea 6.8.0`, **229 tools**, `binary_session` OK;
  `rea mcp doctor` reported 229/229 tools and 6/6 prompts.
- OpenCode V2 connected over both transports: `✓ rea connected` (remote HTTP)
  and `✓ rea-local connected` (local Docker stdio).
- Image size: **4.59 GB** as built with all optional groups; **3.62 GB** with
  `INSTALL_BROWSER=0` (verified: Ghidra/JADX/skill checks still pass).

## Reverse-engineering demonstration

`workspace/test.c` was compiled to `workspace/test` (ELF x86-64 PIE, not
stripped). REA + Ghidra recovered `main` at `0x101139`–`0x1011a3`:

```c
undefined8 main(void)
{
  printf("magic number: %g\n",0x401d4bc6c0000000);
  return 0;
}
```

GCC had constant-folded the whole expression. `0x401d4bc6c0000000` is the
IEEE-754 double for `7.324000358581543` (`1 + (-6) + 12.324f`), and running the
binary prints `magic number: 7.324`. The decompiled logic therefore matches
`test.c`, but Ghidra cannot recover the original declarations, comments, or
formatting.

`workspace/test.c` and `workspace/test` were **not modified or deleted**.

## State / next steps

- Stack is built (`rea-mcp:local`), documented, and validated.
- Optional: build `rea-mcp:nobrowser` for a smaller image (recipe in `spec.md`).
- Optional: remove `workspace/test.c` and `workspace/test` if they were only
  test artifacts.
- Optional: wire `scripts/test-mcp.sh` into CI and add image digest pinning.
