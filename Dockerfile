# syntax=docker/dockerfile:1.7
#
# REA (Reverse Engineer Anything) MCP server + the tools it drives.
#
# REA itself is distributed as the `rea-agents` npm package. This image pins a
# release, adds the native providers REA does not install for you, and exposes
# the MCP server over stdio (default CLI behaviour) or streamable HTTP.
#
# Build:
#   docker build -t rea-mcp:local .
#
# Optional build args (see docker-compose.yml / .env.example):
#   REA_VERSION=6.8.0            rea-agents npm version
#   INSTALL_GHIDRA=1             Ghidra 12.1.4 + JDK 21 (native binaries)
#   INSTALL_ANDROID=1            jadx-headless-mcp, apktool, adb
#   INSTALL_BROWSER=1            Debian Chromium + fonts (website analysis)
#   INSTALL_TSHARK=1             TShark/capinfos (pcap, packet captures)
#   INSTALL_PWNTOOLS=1           Debian python3-pwntools (ELF diagnostics, crashes)
#
# Not included by default because they are large or need extra host access:
#   - Binwalk 3.1 / Unblob 26.6 (firmware): see README.md
#   - Hopper, IDA, JEB, Kuna (commercial GUI tools)
#   - WABT 1.0.42 (WASM), Rizin
#   - Android device USB passthrough and Frida ptrace access: see README.md

ARG NODE_VERSION=24.22.1
FROM node:${NODE_VERSION}-trixie-slim

ARG TARGETARCH
ARG REA_VERSION=6.8.0
# REA 6.8.0 is verified against Ghidra 12.1.4 with JDK 21. Newer 12.x
# releases are accepted by REA but may require a newer JDK.
ARG GHIDRA_VERSION=12.1.4
ARG GHIDRA_BUILD=20260921
ARG JADX_MCP_VERSION=0.7.1
ARG APKTOOL_VERSION=3.0.3
ARG INSTALL_GHIDRA=1
ARG INSTALL_ANDROID=1
ARG INSTALL_BROWSER=1
ARG INSTALL_TSHARK=1
ARG INSTALL_PWNTOOLS=1

LABEL org.opencontainers.image.title="REA MCP" \
      org.opencontainers.image.description="REA reverse-engineering MCP server with Ghidra, JADX, Apktool, adb, Chromium and TShark" \
      org.opencontainers.image.source="https://github.com/morluto/rea" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    NODE_NO_WARNINGS=1

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
RUN set -eux; \
    packages="ca-certificates curl git jq file unzip zip xz-utils procps tini \
      python3 python3-pip openjdk-21-jdk-headless binutils"; \
    if [ "$INSTALL_BROWSER" = "1" ]; then \
      packages="$packages chromium fonts-dejavu-core fonts-liberation"; \
    fi; \
    if [ "$INSTALL_TSHARK" = "1" ]; then \
      echo "wireshark-common wireshark-common/install-setuid boolean false" \
        | debconf-set-selections; \
      packages="$packages tshark"; \
    fi; \
    if [ "$INSTALL_PWNTOOLS" = "1" ]; then \
      packages="$packages python3-pwntools"; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends $packages; \
    rm -rf /var/lib/apt/lists/*

# Ghidra needs a writable temp/home for the JVM and large analyses.
RUN install -d -m 0777 /tmp/rea-home /tmp/rea-cache /opt/rea-tools /work

# ---------------------------------------------------------------------------
# REA from npm (official distribution)
# ---------------------------------------------------------------------------
RUN set -eux; \
    npm install --global --no-fund --no-audit "rea-agents@${REA_VERSION}"; \
    rea --version

# Install the agent skill bundled with REA into a neutral location. The
# entrypoint seeds it into the caller's $HOME, which keeps `rea doctor`'s
# skill identity check healthy for arbitrary host UIDs.
RUN set -eux; \
    install -d -m 0755 /opt/rea-skill; \
    HOME=/opt/rea-skill rea setup --yes --skill --format json >/dev/null; \
    chmod -R a+rX /opt/rea-skill

# ---------------------------------------------------------------------------
# National Security Agency Ghidra (native binaries, decompilation)
# ---------------------------------------------------------------------------
RUN set -eux; \
    if [ "$INSTALL_GHIDRA" = "1" ]; then \
      curl -fL --retry 3 -o /tmp/ghidra.zip \
        "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/ghidra_${GHIDRA_VERSION}_PUBLIC_${GHIDRA_BUILD}.zip"; \
      unzip -q /tmp/ghidra.zip -d /opt; \
      mv "/opt/ghidra_${GHIDRA_VERSION}_PUBLIC" /opt/ghidra; \
      rm -f /tmp/ghidra.zip; \
      test -x /opt/ghidra/support/analyzeHeadless; \
    fi

# ---------------------------------------------------------------------------
# Android static analysis: JADX headless bridge, Apktool, adb
# ---------------------------------------------------------------------------
RUN set -eux; \
    if [ "$INSTALL_ANDROID" = "1" ]; then \
      curl -fL --retry 3 -o /opt/rea-tools/jadx-headless-mcp.jar \
        "https://github.com/1013503897/jadx-headless-mcp/releases/download/v${JADX_MCP_VERSION}/jadx-headless-mcp-${JADX_MCP_VERSION}-all.jar"; \
      echo "6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75  /opt/rea-tools/jadx-headless-mcp.jar" \
        | sha256sum -c -; \
      curl -fL --retry 3 -o /opt/rea-tools/apktool.jar \
        "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/apktool_${APKTOOL_VERSION}.jar"; \
      printf '%s\n' '#!/bin/sh' 'exec java -jar /opt/rea-tools/apktool.jar "$@"' \
        > /usr/local/bin/apktool; \
      chmod 0755 /usr/local/bin/apktool; \
    fi; \
    if [ "$INSTALL_ANDROID" = "1" ] && [ "$TARGETARCH" = "amd64" ]; then \
      curl -fL --retry 3 -o /tmp/platform-tools.zip \
        "https://dl.google.com/android/repository/platform-tools-latest-linux.zip"; \
      unzip -q /tmp/platform-tools.zip -d /opt/android-platform-tools; \
      rm -f /tmp/platform-tools.zip; \
      ln -sf /opt/android-platform-tools/platform-tools/adb /usr/local/bin/adb; \
    fi

# ---------------------------------------------------------------------------
# Browser executable path expected by REA's browser scenario examples
# ---------------------------------------------------------------------------
RUN if [ -x /usr/bin/chromium ]; then \
      install -d /opt/chromium; \
      ln -sf /usr/bin/chromium /opt/chromium/chrome; \
    fi

# ---------------------------------------------------------------------------
# Container entrypoint + HTTP smoke test
# ---------------------------------------------------------------------------
COPY docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY docker/mcp-smoke.mjs /opt/rea-tools/mcp-smoke.mjs
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

# HTTP defaults. The CLI still speaks stdio when started as `rea mcp`.
ENV MCP_HOST=0.0.0.0 \
    MCP_PORT=8765 \
    MCP_ALLOWED_HOSTS=127.0.0.1,localhost,rea,host.docker.internal \
    GHIDRA_HEADLESS_MAXMEM=2G

USER node
WORKDIR /work

EXPOSE 8765

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["rea", "mcp", "--http"]
