#!/bin/bash

set -e

# --- Function to log messages with timestamp ---
log() {
    local msg="$1"
    local formatted_date=$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S')
    echo "[$formatted_date] $msg"
}

# --- Function to send Telegram notifications ---
tg() {
    local msg="$1"
    local formatted_date=$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S')
    log "➡️ Sending Telegram message: $msg (at $formatted_date WIB)"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$msg - \`$formatted_date\`" > /dev/null
}

# --- Function to send Telegram documents with error handling ---
tg_doc() {
    local file="$1"
    local caption="$2"
    local formatted_caption=$(printf '%q' "$caption")
    log "➡️ Sending Telegram document: $file"
    if ! curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" \
        -F chat_id="$TELEGRAM_CHAT_ID" \
        -F document="@$file" \
        -F parse_mode="MarkdownV2" \
        -F caption="${formatted_caption}"; then
        log "❌ Failed to send Telegram document: $file"
        tg "❌ Failed to send Telegram document: $file"
    fi
}

# --- Function to handle errors with logging ---
handle_error() {
    local error_message="$1"
    log "❌ An error occurred: $error_message"
    tg "❌ An error occurred: \`$error_message\`"
    exit 1
}

# --- Start the build process ---
log "🚀 Starting build at $(date)"
tg "🚀 Build started\!"

# --- Clean up previous kernel directory ---
if [ -d "$GITHUB_WORKSPACE/8937_Kernel" ]; then
    log "🗑️ Cleaning up previous kernel directory..."
    rm -rf "$GITHUB_WORKSPACE/8937_Kernel"
fi

# --- Clone the kernel source ---
log "⬇️ Cloning kernel source from: $KERNEL_SOURCE (branch: $KERNEL_BRANCH)..."
if ! git clone "$KERNEL_SOURCE" -b "$KERNEL_BRANCH" "$GITHUB_WORKSPACE/8937_Kernel" --depth=1; then
    handle_error "Failed to clone kernel source"
fi

cd "$GITHUB_WORKSPACE/8937_Kernel" || handle_error "Failed to enter kernel directory"

TAG=$(curl -s https://api.github.com/repos/backslashxx/KernelSU/tags | grep '"name"' | head -n1 | cut -d'"' -f4) && curl -LSs "https://raw.githubusercontent.com/backslashxx/KernelSU/refs/heads/master/kernel/setup.sh" | bash -s -- "$TAG"

# --- Setup ccache ---
log "🧰 Setting up ccache..."
export CCACHE_DIR=/tmp/ccache
export CCACHE_EXEC=$(which ccache)
export USE_CCACHE=1
ccache -M 10G
ccache -o compression=true
ccache -z
log "✅ ccache configured."

# --- Download CRDroid Clang (ESSENTIAL CHANGE) ---
log "⬇️ Setting up Clang r547379"
CLANG_DIR="$HOME/clang-r547379"

if [ ! -d "$CLANG_DIR" ]; then
    git clone --depth=1 https://gitlab.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-r547379 "$CLANG_DIR"
fi

export PATH="$CLANG_DIR/bin:$PATH"

# --- Set environment variables ---
log "🔧 Setting environment variables..."
export ARCH=arm64
export KBUILD_BUILD_USER=Audemars
export KBUILD_BUILD_HOST=ROG-G834JYR
export TZ=Asia/Jakarta
export KBUILD_BUILD_TIMESTAMP=$(date '+%a %b %d %H:%M:%S %Z %Y')

# --- Set LLVM toolchain flags ---
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export STRIP=llvm-strip
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export PROJECT_NAME="KSU"
export DEVICE_CODENAME="8937"

# --- Set defconfig ---
DEFCONFIG="los_defconfig"
log "⚙️ Using defconfig: $DEFCONFIG"

# --- Get release version from defconfig ---
DEFCONFIG_CONTENT=$(cat arch/arm64/configs/$DEFCONFIG)
RELEASE_VERSION=$(echo "$DEFCONFIG_CONTENT" | grep "CONFIG_LOCALVERSION=" | sed 's/CONFIG_LOCALVERSION="\(.*\)"/\1/')
RELEASE_VERSION="${RELEASE_VERSION#-}"

IFS=- read -r KERNEL_VARIANT KERNEL_CODENAME RELEASE_VERSION <<< "$RELEASE_VERSION" || true

log "ℹ️ Kernel Variant: $KERNEL_VARIANT"
log "ℹ️ Kernel Codename: $KERNEL_CODENAME"
log "ℹ️ Release Version: $RELEASE_VERSION"

# --- Create output directory ---
mkdir -p out
log "📁 Output directory created at: out/"

# --- Make defconfig ---
log "⚙️ Generating defconfig..."
make O=out $DEFCONFIG

# --- Start kernel compilation (ESSENTIAL CHANGE) ---
log "🔥 Starting kernel compilation..."
make -j$(nproc --all) O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    CC="ccache clang" LD=ld.lld AR=$AR NM=$NM STRIP=$STRIP \
    OBJCOPY=$OBJCOPY OBJDUMP=$OBJDUMP \
    CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    2>&1 | tee build.log

# --- Check for compilation errors ---
if [[ $? -ne 0 ]]; then
    handle_error "Compilation failed"
    tg_doc "build.log" "❌ Build failed after $((SECONDS / 60)) minutes $((SECONDS % 60)) seconds"
    exit 1
fi

# --- Get Clang and LLD versions ---
CLANG_VERSION=$(clang --version 2>&1 | head -n 1)
LLD_VERSION=$(ld.lld --version 2>&1 | head -n 1)

log "ℹ️ Using Clang: $CLANG_VERSION"
log "ℹ️ Using LLD: $LLD_VERSION"

# --- Clone AnyKernel3 ---
log "⬇️ Cloning AnyKernel3..."
if ! git clone -q -b msm8937 https://github.com/AzyrRuthless/AnyKernel3 "$GITHUB_WORKSPACE/8937_Kernel/anykernel"; then
    handle_error "Failed to clone AnyKernel3"
fi

# --- Copy files to AnyKernel3 ---
log "➡️ Copying Image.gz-dtb..."
cp "$GITHUB_WORKSPACE/8937_Kernel/out/arch/arm64/boot/Image.gz-dtb" "$GITHUB_WORKSPACE/8937_Kernel/anykernel"

# --- Create ZIP archive ---
ZIP_NAME="${PROJECT_NAME}-${KERNEL_VARIANT}-${KERNEL_CODENAME}-${RELEASE_VERSION}-${DEVICE_CODENAME}-$(date '+%d%m%Y').zip"

log "🗜️ Creating ZIP archive: $ZIP_NAME"
cd "$GITHUB_WORKSPACE/8937_Kernel/anykernel" || handle_error "Failed to enter AnyKernel3 directory"

zip -r9 "../$ZIP_NAME" ./* -x '*.git*' README.md ./*placeholder

cd "$GITHUB_WORKSPACE/8937_Kernel" || handle_error "Failed to return to kernel directory"

# --- Build completion notification ---
BUILD_DURATION_MINUTES=$((SECONDS / 60))
BUILD_DURATION_SECONDS=$((SECONDS % 60))

log "🎉 Build completed in ${BUILD_DURATION_MINUTES} minutes ${BUILD_DURATION_SECONDS} seconds!"
log "📦 ZIP archive: $ZIP_NAME"

tg "✅ Kernel compilation completed\! 🎉 File: \`$ZIP_NAME\`"
tg_doc "$GITHUB_WORKSPACE/8937_Kernel/$ZIP_NAME" "✅ Build finished after ${BUILD_DURATION_MINUTES} minutes ${BUILD_DURATION_SECONDS} seconds"
