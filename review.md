# Self-review

Scope: the Docker/OpenCode delivery and the reverse-engineering demonstration.
This is a critical review, not a changelog.

## Verdict

The stated goal is met and validated end to end: REA 6.8.0 runs as an MCP
server in a container, the required analysis engines are present, OpenCode
connects over both transports, and a real binary was decompiled with Ghidra.
The main weaknesses are **image size**, **supply-chain pinning**, and **test
coverage of the OpenCode path**, not functional correctness.

## What was actually verified

| Claim | Evidence |
| --- | --- |
| Full stack builds | `rea-mcp:local`, amd64, 4.59 GB |
| Required providers ready | `rea doctor`: Ghidra 12.1.4, JDK 21, JADX, skill `aligned` |
| Ghidra really works | `rea analyze /bin/ls --provider ghidra` → 12.1.4, ~24.5 s |
| MCP server works | `initialize` → `tools/list` → `tools/call binary_session`, 229 tools |
| Prompts work | `rea mcp doctor`: 229/229 tools, 6/6 prompts |
| OpenCode remote works | `opencode mcp list`: `✓ rea connected` |
| OpenCode stdio works | `opencode mcp list`: `✓ rea-local connected` |
| Auxiliary tools work | Apktool 3.0.3, adb 1.0.41, Chromium 156, TShark 4.4.19, pwntools 4.14.1 |
| Regression script passes | `scripts/test-mcp.sh --no-build --stop` → exit 0 |
| Lean variant builds | `rea-mcp:nobrowser` 3.62 GB (−0.97 GB); Ghidra 12.1.4, JADX and skill checks pass; Chromium absent |

Not verified: long-running sessions under memory pressure, Windows/macOS hosts,
arm64 end to end (`adb` is amd64-only), commercial providers, real USB
Android devices, Frida attach, firmware/WASM providers.

## Requirement coverage

| Requirement | Status | Notes |
| --- | --- | --- |
| REA as an MCP server in Docker | Done | HTTP + stdio |
| Ghidra and required tooling | Done | 12.1.4 + JDK 21, verified by REA |
| OpenCode configuration + test | Done | Both transports connected |
| Dockerfile / Compose / tooling in repo | Done | See `compact.md` |
| Test the finished stack | Done | Script + manual checks |
| "Revert" `workspace/test` | Done as decompilation | Files left intact |

## Reverse-engineering result

Recovered `main` at `0x101139`:

```c
undefined8 main(void)
{
  printf("magic number: %g\n",0x401d4bc6c0000000);
  return 0;
}
```

- The constant is `7.324000358581543`, i.e. `1 + (-6) + 12.324f`, and the
  binary prints `magic number: 7.324`.
- This is **decompiler output**, not the original source. Declarations,
  comments, and types (`int i`, `char c`, `float f`) are unrecoverable because
  GCC constant-folded the expression.
- Confidence: high for behavior, low for source form. The report said this
  explicitly rather than presenting the pseudocode as original code.

## Things done well

- Version choice was driven by REA's own compatibility checks, not guesswork:
  12.1.4 + JDK 21; 12.2/JDK 25 was rejected after a real failure.
- The image is built on REA's official npm distribution instead of compiling
  from source, which keeps the build reproducible and fast.
- Tool paths are exported in **both** the entrypoint and Compose, so one-off
  `docker compose exec` commands behave like the server.
- The skill is seeded into `$HOME` so `rea doctor` stays healthy for arbitrary
  host UIDs — a subtle failure that would otherwise appear only in production.
- HTTP is loopback-only; the no-auth limitation is stated in README and spec.
- `mcp-smoke.mjs` has no dependencies and exercises a real tool call, not just
  a port check.
- The no-browser build path is a first-class option, with the tradeoff
  documented instead of hidden.

## Defects and risks

Ordered by what I would fix first.

### 1. Supply-chain reproducibility is incomplete — medium

- `node:24.22.1-trixie-slim` is a tag, not a digest.
- Android `platform-tools-latest-linux.zip` is unpinned and unverified.
- The Ghidra ZIP has no checksum verification (GitHub HTTPS only).
- `npm install -g rea-agents@6.8.0` is version-pinned but has no lockfile or
  integrity check.
- Only the JADX JAR is SHA-256 pinned.

Impact: two builds at different times can differ, and a compromised upstream
asset would be trusted. Fix: pin base image by digest, pin platform-tools to a
build number + checksum, add a Ghidra SHA-256, and optionally vendor an npm
lockfile.

### 2. Full image is large (4.59 GB) — medium

Chromium accounts for roughly 0.97 GB of image delta and Ghidra ~0.9 GB. This
is expected for the feature set, but it is the main cost. Mitigation exists
(`INSTALL_BROWSER=0` → 3.62 GB, measured below), yet the **default** remains
the full image.

Recommendation: make the lean image the default and put Chromium behind a
Compose `profiles:` service or a separate `rea-mcp:browser` tag. Most native
and Android work does not need a browser.

### 3. HTTP transport is single-client and unauthenticated — medium (accepted)

Documented and bound to loopback, but it is still a sharp edge: a second
OpenCode window silently takes over the session. There is no warning in the
UI. The stdio launcher is the correct answer for multi-workspace use; the
README says so, but the remote option is listed first as "recommended".

Recommendation: recommend stdio by default for project work, and HTTP only for
a single shared agent.

### 4. Test coverage stops short of the agent path — medium

`scripts/test-mcp.sh`:

- treats a non-zero `rea doctor` as acceptable (correct, but means a new
  provider failure could hide behind the required-check filter);
- does not assert the tool count (229) or prompt count (6/6);
- only prints `opencode mcp list`; it does not fail if OpenCode is
  disconnected;
- leaves the server running unless `--stop` is passed;
- has no CI workflow, shellcheck, or linting.

The OpenCode connection was verified manually, so the claim is true, but it is
not regression-protected.

### 5. Compose environment duplicates entrypoint logic — low

The same tool paths are maintained in two places. They can drift after a
Dockerfile change. It works today, but a generated env file or a single
`/etc/rea/env` sourced by both would be safer.

### 6. Lean image leaves a dangling browser path — low

With `INSTALL_BROWSER=0`, `REA_BROWSER_EXECUTABLE` still points at
`/usr/bin/chromium`. REA should report it unavailable, but the configuration
is misleading. Remove the entry in a lean Compose override; setting it empty in
`.env` does not work because `${VAR:-default}` falls back for empty values.

### 7. arm64 is only partly supported — low

`adb` is skipped on arm64, yet Compose always sets `REA_ADB_PATH` to the
amd64 path. On arm64 the variable points at a missing file. README mentions
"amd64 only" but Compose should omit the variable or document an override.

### 8. Default Ghidra heap may be too small — low

`GHIDRA_HEADLESS_MAXMEM=2G` is fine for small ELFs and was enough for
`/bin/ls`, but large firmware/desktop binaries will OOM. The README says to
raise it; the default could be 4G on machines with headroom.

### 9. Skill seeding only runs when the destination is absent — low

`entrypoint.sh` copies the bundled skill only if `$HOME/.agents/skills/...`
does not exist. With a persistent home, an image upgrade leaves a stale skill
and `rea doctor` can report `misaligned`. Compare contents or overwrite on
every start.

### 10. Miscellaneous

- The image installs `tini` but relies on Compose `init: true`; redundant.
- `.dockerignore` excludes `workspace`, which is correct for build context but
  means the default empty workspace mount must exist on the host.
- `workspace/test` and `workspace/test.c` are still present. They are user
  files and were intentionally not deleted; they should be removed or moved to
  a samples directory before sharing the repo.
- The README says "~10 GB free disk"; measured image + build cache can exceed
  that on a cold build with multiple variants. Suggest 15 GB.
- No license/NOTICE review for redistributing Ghidra/Apktool/JADX in an image.

## Recommended follow-ups (priority order)

1. Pin base image digest, platform-tools build + checksum, and Ghidra SHA-256.
2. Make `nobrowser` the default and add a browser profile/tag.
3. Add CI: build (full + lean), `test-mcp.sh --no-build`, and a real
   `opencode mcp list` assertion.
4. Add tool/prompt count assertions to the smoke test.
5. Unset browser/adb variables in variants where the binaries are absent.
6. Refresh the seeded skill on every container start.
7. Add resource limits and a read-only workspace example to Compose.
8. Clean `workspace/test*` or move them to `examples/`.

## Bottom line

Functionally complete and honestly validated. Before calling it
production-grade, fix the pinning gaps, flip the default to the lean image,
and make the OpenCode check part of CI rather than a manual step.
