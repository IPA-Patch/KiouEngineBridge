# syntax=docker/dockerfile:1.7
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04
ARG _REMOTE_USER_HOME=/home/vscode

# ── Reverse Engineering Tools + Theos 依存パッケージ (apt) ──
RUN \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
    wget \
    unzip \
    jq \
    radare2 \
    apktool \
    make \
    perl \
    fakeroot \
    zip \
    xz-utils \
    lzma \
    xxd \
    binutils \
    libtinfo6 \
    libxml2 \
    libncurses6 \
    libz3-dev \
    adb \
    android-sdk-platform-tools \
    # ── agent-iossolve 向け追加ツール ────────────────────────
    # libimobiledevice: idevicesyslog で os_log 取得 (rootless iOS には log コマンドが無いため、SSH 経由ではなく USB 経由が現実的)
    # class-dump:       Ubuntu 24.04 で利用可能 (universe)。recon の主力
    # socat / netcat:   JB 機との中継、port forward
    # file:             Mach-O / FAT 判定
    libimobiledevice-utils \
    libimobiledevice6 \
    ideviceinstaller \
    libplist-utils \
    socat \
    netcat-openbsd \
    file \
    llvm

# ── jadx (GitHub Release) ──
# Android APK → Java 逆コンパイル (プラットフォーム非依存 JAR、JRE は devcontainer feature の Java で提供)
RUN \
    --mount=type=cache,target=/var/cache/dl,sharing=locked,uid=1000,gid=1000 \
    JADX_URL=$(wget -qO- https://api.github.com/repos/skylot/jadx/releases/latest | jq -r '.assets[] | select(.name | test("^jadx-[0-9].*\\.zip$")) | .browser_download_url') && \
    JADX_FILE=/var/cache/dl/$(basename "$JADX_URL") && \
    { [ -f "$JADX_FILE" ] || wget -q "$JADX_URL" -O "$JADX_FILE"; } && \
    unzip -q "$JADX_FILE" -d /opt/jadx && \
    ln -s /opt/jadx/bin/jadx /usr/local/bin/jadx && \
    ln -s /opt/jadx/bin/jadx-gui /usr/local/bin/jadx-gui

# ── Ghidra (Headless) ──
# NSA 製リバースエンジニアリングツール。ヘッドレスモードで C++ 擬似コード生成に使用
# 使い方: analyzeHeadless /tmp/project name -import <binary>
RUN \
    --mount=type=cache,target=/var/cache/dl,sharing=locked,uid=1000,gid=1000 \
    GHIDRA_URL=$(wget -qO- https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest | jq -r '.assets[] | select(.name | test("PUBLIC.*\\.zip$")) | .browser_download_url') && \
    GHIDRA_FILE=/var/cache/dl/$(basename "$GHIDRA_URL") && \
    { [ -f "$GHIDRA_FILE" ] || wget -q "$GHIDRA_URL" -O "$GHIDRA_FILE"; } && \
    unzip -q "$GHIDRA_FILE" -d /opt && \
    GHIDRA_DIR=$(find /opt -maxdepth 1 -name 'ghidra_*' -type d) && \
    ln -s "$GHIDRA_DIR" /opt/ghidra
ENV PATH="/opt/ghidra/support:$PATH"

# ── ipsw ──
# Go 製 Mach-O 解析ツール。iOS バイナリの ObjC/Swift クラスダンプ、シンボル解析に使用
# 使い方: ipsw macho info <binary> --class-dump
RUN \
    --mount=type=cache,target=/var/cache/dl,sharing=locked,uid=1000,gid=1000 \
    IPSW_URL=$(wget -qO- https://api.github.com/repos/blacktop/ipsw/releases/latest | jq -r '.assets[] | select(.name | test("^ipsw_.*linux_arm64\\.tar\\.gz$")) | .browser_download_url') && \
    IPSW_FILE=/var/cache/dl/$(basename "$IPSW_URL") && \
    { [ -f "$IPSW_FILE" ] || wget -q "$IPSW_URL" -O "$IPSW_FILE"; } && \
    tar xzf "$IPSW_FILE" -C /usr/local/bin ipsw

# ── yq (mikefarah/yq, Go 製) ──
# YAML 操作。agent-iossolve の hook 仕様 YAML を扱う recon/frida エージェントが使う
RUN \
    --mount=type=cache,target=/var/cache/dl,sharing=locked,uid=1000,gid=1000 \
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    YQ_URL=$(wget -qO- https://api.github.com/repos/mikefarah/yq/releases/latest | jq -r --arg arch "$ARCH" '.assets[] | select(.name == "yq_linux_\($arch)") | .browser_download_url') && \
    YQ_FILE=/var/cache/dl/yq_linux_${ARCH} && \
    { [ -f "$YQ_FILE" ] || wget -q "$YQ_URL" -O "$YQ_FILE"; } && \
    install -m 0755 "$YQ_FILE" /usr/local/bin/yq

# ── Theos 本体 ──
USER vscode
ENV THEOS=/home/vscode/theos
RUN git clone --recursive https://github.com/theos/theos.git ${THEOS}

# ── Toolchain (L1ghtmann, aarch64 対応) ──
RUN \
    --mount=type=cache,target=/var/cache/dl,sharing=locked,uid=1000,gid=1000 \
    ARCH=$(uname -m) && \
    TC_FILE=/var/cache/dl/iOSToolchain-${ARCH}.tar.xz && \
    { [ -f "$TC_FILE" ] || curl -fsSL -o "$TC_FILE" "https://github.com/L1ghtmann/llvm-project/releases/latest/download/iOSToolchain-${ARCH}.tar.xz"; } && \
    tar xJf "$TC_FILE" -C ${THEOS}/toolchain

# ── Swift Toolchain (kabiroberai, iOS クロスコンパイル用) ──
RUN \
    --mount=type=cache,target=/var/cache/dl,sharing=locked,uid=1000,gid=1000 \
    ARCH=$(uname -m) && \
    SWIFT_TC_FILE=/var/cache/dl/swift-5.8-ubuntu22.04-${ARCH}.tar.xz && \
    { [ -f "$SWIFT_TC_FILE" ] || curl -fsSL -o "$SWIFT_TC_FILE" "https://github.com/kabiroberai/swift-toolchain-linux/releases/download/v2.3.0/swift-5.8-ubuntu22.04-${ARCH}.tar.xz"; } && \
    tar xJf "$SWIFT_TC_FILE" -C ${THEOS}/toolchain

# ── ホスト Swift (SPM ビルド用) ──
USER root
RUN \
    --mount=type=cache,target=/var/cache/dl,sharing=locked,uid=1000,gid=1000 \
    ARCH=$(uname -m) && \
    HOST_SWIFT_FILE=/var/cache/dl/swift-5.8.1-RELEASE-ubuntu22.04-${ARCH}.tar.gz && \
    { [ -f "$HOST_SWIFT_FILE" ] || curl -fsSL -o "$HOST_SWIFT_FILE" "https://download.swift.org/swift-5.8.1-release/ubuntu2204-${ARCH}/swift-5.8.1-RELEASE/swift-5.8.1-RELEASE-ubuntu22.04-${ARCH}.tar.gz"; } && \
    tar xzf "$HOST_SWIFT_FILE" --strip-components=2 -C /usr
USER vscode

# ── iOS SDKs (15.6 + 16.5) ──
RUN \
    --mount=type=cache,target=/var/cache/dl,sharing=locked,uid=1000,gid=1000 \
    SDKS_FILE=/var/cache/dl/theos-sdks-master.tar.gz && \
    { [ -f "$SDKS_FILE" ] || curl -fsSL -o "$SDKS_FILE" "https://github.com/theos/sdks/archive/master.tar.gz"; } && \
    tar xzf "$SDKS_FILE" -C /tmp && \
    mv /tmp/sdks-master/iPhoneOS15.6.sdk ${THEOS}/sdks/ && \
    mv /tmp/sdks-master/iPhoneOS16.5.sdk ${THEOS}/sdks/ && \
    rm -rf /tmp/sdks-master
