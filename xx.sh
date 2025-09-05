#!/bin/bash
set -euo pipefail

# --- Configuration ---
readonly BASE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
readonly KERNEL_DIR="$BASE_DIR/Kinesis_Kernel"
readonly ARTIFACT_DIR="$BASE_DIR/kernel_artifacts"
readonly TOOLS_DIR="$BASE_DIR/tools"
readonly CLANG_DIR="$TOOLS_DIR/clang-r584948"
readonly DEFCONFIG="vendor/xiaomi/miatoll_defconfig"

# --- Helper Functions ---
log() {
    echo -e "[\033[1;32m$(date '+%Y-%m-%d %H:%M:%S')\033[0m] $*"
}

err() {
    echo -e "[\033[1;31mERROR\033[0m] $*" >&2
}

tg_msg() {
    local text="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$text" \
        -d parse_mode="HTML" >/dev/null
}

tg_doc() {
    local file="$1" caption="$2"
    [[ -f "$file" ]] || { err "File not found: $file"; return 1; }
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F chat_id="$TELEGRAM_CHAT_ID" \
        -F document="@$file" \
        -F caption="$caption" \
        -F parse_mode="HTML" >/dev/null || err "Failed to send document via Telegram"
}

die() {
    err "$*"
    tg_msg "❌ <b>Build Failed:</b> $*"
    exit 1
}

# --- Main Execution ---

log "🚀 Build Environment: $(uname -a)"
tg_msg "🚀 <b>Build Started!</b>%0AHost: $(uname -n)%0ADate: $(date)"

# 1. Cleanup & Clone
if [[ -d "$KERNEL_DIR" ]]; then
    log "🗑️ Cleaning previous kernel directory..."
    rm -rf "$KERNEL_DIR"
fi

log "⬇️ Cloning kernel source..."
git clone --quiet --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_SOURCE" "$KERNEL_DIR" || die "Kernel clone failed"
cd "$KERNEL_DIR"

# 2. KernelSU Setup
log "🔧 Setting up KernelSU..."
curl -LSs "https://raw.githubusercontent.com/rsuntk/KernelSU/main/kernel/setup.sh" | bash -s main

# 3. Toolchain Setup
mkdir -p "$TOOLS_DIR"
export CCACHE_DIR="/tmp/ccache"
export USE_CCACHE=1
ccache -M 10G -o compression=true -z

if [[ -x "$CLANG_DIR/bin/clang" ]]; then
    log "✅ Using cached Clang"
else
    log "⬇️ Downloading Google Clang r584948..."
    mkdir -p "$CLANG_DIR"
    CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/mirror-goog-main-llvm-toolchain-source/clang-r584948.tar.gz"
    
    wget -q "$CLANG_URL" -O "$TOOLS_DIR/clang.tar.gz" || die "Download failed: $CLANG_URL"
    
    # Extract correctly preserving paths
    tar -xf "$TOOLS_DIR/clang.tar.gz" -C "$CLANG_DIR" || die "Clang extraction failed"
    rm "$TOOLS_DIR/clang.tar.gz"
    log "✅ Clang setup complete"
fi

# 4. Variables
export PATH="$CLANG_DIR/bin:$PATH"
export ARCH=arm64
export KBUILD_BUILD_USER="Audemars"
export KBUILD_BUILD_HOST="ROG-G834JYR"

# 5. Defconfig
log "⚙️ Configuring Kernel..."
make O=out "$DEFCONFIG"

# Parse Version
RAW_VERSION=$(grep "CONFIG_LOCALVERSION=" out/.config | cut -d'"' -f2 | sed 's/^-//')
IFS=- read -r KERNEL_VARIANT KERNEL_CODENAME RELEASE_VERSION <<< "$RAW_VERSION"
KERNEL_VARIANT=${KERNEL_VARIANT:-"Kinesis"}
KERNEL_CODENAME=${KERNEL_CODENAME:-"miatoll"}
RELEASE_VERSION=${RELEASE_VERSION:-"Test"}

log "ℹ️ Info: $KERNEL_VARIANT | $KERNEL_CODENAME | $RELEASE_VERSION"

# 6. Compile
log "🔥 Compiling..."

# Force Linker to LLD
make -j"$(nproc)" O=out \
    CC="ccache clang" \
    LD=ld.lld \
    AR=llvm-ar \
    NM=llvm-nm \
    STRIP=llvm-strip \
    OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump \
    LLVM=1 \
    LLVM_IAS=1 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    2>&1 | tee build.log

[[ ${PIPESTATUS[0]} -eq 0 ]] || die "Compilation failed! Check build.log"

# 7. Packaging
log "📦 Packaging with AnyKernel3..."
git clone --quiet -b Ivory "https://github.com/AzyrRuthless/AnyKernel3" anykernel

# Dynamic Image Detection
if [[ -f out/arch/arm64/boot/Image.gz-dtb ]]; then
    cp out/arch/arm64/boot/Image.gz-dtb anykernel/Image.gz-dtb
elif [[ -f out/arch/arm64/boot/Image.gz ]]; then
    cp out/arch/arm64/boot/Image.gz anykernel/
    log "⚠️ Warning: Image.gz found, but Image.gz-dtb is usually required for Miatoll."
else
    die "No kernel image found"
fi

[[ -f out/arch/arm64/boot/dtbo.img ]] && cp out/arch/arm64/boot/dtbo.img anykernel/
mkdir -p anykernel/dtb
[[ -f out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb ]] && cp out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb anykernel/dtb/

# Zip
ZIP_NAME="${PROJECT_NAME}-${KERNEL_VARIANT}-${KERNEL_CODENAME}-${RELEASE_VERSION}-$(date '+%d%m%Y').zip"
cd anykernel
zip -r9 "../$ZIP_NAME" . -x "*.git*" "README.md" ".*"
cd ..

# 8. Artifacts & Notify
mkdir -p "$ARTIFACT_DIR"
cp "$ZIP_NAME" "$ARTIFACT_DIR/"
cp out/arch/arm64/boot/Image.gz "$ARTIFACT_DIR/" 2>/dev/null || true

BUILD_DURATION=$((SECONDS / 60))m$((SECONDS % 60))s
log "🎉 Build Success: $ZIP_NAME ($BUILD_DURATION)"

tg_msg "✅ <b>Build Success!</b>%0A%0A📦 File: <code>$ZIP_NAME</code>%0A⏱ Duration: $BUILD_DURATION"
tg_doc "$ZIP_NAME" "✅ Build by CircleCI"
