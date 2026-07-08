FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/opt/zig:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    xz-utils \
    jq \
    # kcov build dependencies (kcov is not packaged for Ubuntu 24.04)
    cmake \
    g++ \
    make \
    binutils-dev \
    libdw-dev \
    libiberty-dev \
    libcurl4-openssl-dev \
    zlib1g-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Zig toolchain (pinned; also used by CI)
ARG ZIG_VERSION=0.16.0
RUN ARCH=$(uname -m) \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz \
    && zig version

# ZLS (Zig Language Server) for the VS Code extension
RUN ARCH=$(uname -m) \
    && curl -fsSL "https://builds.zigtools.org/zls-${ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zls.tar.xz \
    && mkdir -p /opt/zls \
    && tar -xJf /tmp/zls.tar.xz -C /opt/zls \
    && ln -s /opt/zls/zls /usr/local/bin/zls \
    && zls --version

# kcov (line coverage for the test binaries; used by coverage.sh and CI)
RUN curl -fsSL https://github.com/SimonKagstrom/kcov/archive/refs/tags/v43.tar.gz | tar xz -C /tmp \
    && cmake -S /tmp/kcov-43 -B /tmp/kcov-43/build -DCMAKE_BUILD_TYPE=Release \
    && make -C /tmp/kcov-43/build -j"$(nproc)" \
    && make -C /tmp/kcov-43/build install \
    && rm -rf /tmp/kcov-43

# Node.js (LTS) for Claude Code
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code
RUN npm install -g @anthropic-ai/claude-code

# GitHub CLI (gh) — installed from GitHub's official apt repository
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

CMD ["/bin/bash"]
