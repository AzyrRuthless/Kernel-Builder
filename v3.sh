#!/bin/bash
set -euo pipefail

# --- Configuration ---
readonly WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
readonly KERNEL_DIR="$WORKSPACE/Velion_Kernel"
readonly TOOLS_DIR="$WORKSPACE/tools"
# Use env var from YAML, fallback to default if run locally
readonly CLANG_VER="${CLANG_VERSION:-r596125}"
readonly CLANG_DIR="$TOOLS_DIR/clang-$CLANG_VER"
readonly DEFCONFIG="vendor/xiaomi/miatoll_defconfig"
readonly ANYKERNEL_BRANCH="Ivory"

# --- Cleanup Trap ---
function cleanup() {
    if [[ -n "${MONITOR_PID:-}" ]]; then
        kill "$MONITOR_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Telegram Functions ---
tg_send() {
    local text="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$text" \
        -d parse_mode="HTML" || true
}

tg_edit() {
    local msg_id="$1"
    local text="$2"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/editMessageText" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d message_id="$msg_id" \
        -d text="$text" \
        -d parse_mode="HTML" >/dev/null || true
}

tg_doc() {
    local file="$1" caption="$2"
    [[ -f "$file" ]] || { echo "File not found: $file"; return 1; }
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F chat_id="$TELEGRAM_CHAT_ID" \
        -F document="@$file" \
        -F caption="$caption" \
        -F parse_mode="HTML" >/dev/null || true
}

# --- Background Monitor ---
start_monitor() {
    local msg_id="$1"
    local start_time="$2"

    while true; do
        sleep 30
        local current_time=$(date +%s)
        local diff=$((current_time - start_time))
        local min=$((diff / 60))
        local sec=$((diff % 60))
        local obj_count=$(find out -name "*.o" 2>/dev/null | wc -l)

        local status_txt="<b>🚀 Velion Build Progress</b>%0A%0A"
        status_txt+="<b>• Device:</b> Miatoll%0A"
        status_txt+="<b>• Compiler:</b> Clang $CLANG_VER%0A"
        status_txt+="<b>• Objects Built:</b> ${obj_count}%0A"
        status_txt+="<b>• Duration:</b> ${min}m ${sec}s%0A"
        status_txt+="<b>• Status:</b> Compiling..."

        tg_edit "$msg_id" "$status_txt"
    done
}

# --- Main Execution ---

echo "🚀 Setup Environment..."

# 1. Clone Kernel Source
if [[ -d "$KERNEL_DIR" ]]; then rm -rf "$KERNEL_DIR"; fi
git clone --quiet --depth=1 -b "$KERNEL_BRANCH" \
  "https://${GL_DEPLOY_USER}:${GL_DEPLOY_TOKEN}@${KERNEL_REPO_URL#https://}" \
  "$KERNEL_DIR"
cd "$KERNEL_DIR"

# 2. Setup KernelSU
echo "🔧 Setting up KernelSU..."
curl -LSs "https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh" | bash

# 3. Setup Toolchain & Ccache
mkdir -p "$TOOLS_DIR"
export CCACHE_DIR="/tmp/ccache"
export USE_CCACHE=1

# Check Clean Build Request
if [[ "${CLEAN_BUILD:-false}" == "true" ]]; then
    echo "🧹 Clean Build requested: Clearing Ccache..."
    ccache -C
    ccache -z
else
    echo "♻️  Using existing Ccache..."
fi

ccache -M 10G -o compression=true

if [[ ! -x "$CLANG_DIR/bin/clang" ]]; then
    echo "⬇️ Downloading Clang $CLANG_VER..."
    mkdir -p "$CLANG_DIR"
    wget --quiet "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/mirror-goog-main-llvm-toolchain-source/clang-$CLANG_VER.tar.gz" -O /tmp/clang.tar.gz
    tar -xf /tmp/clang.tar.gz -C "$CLANG_DIR"
    rm -f /tmp/clang.tar.gz
fi

export ARCH=arm64
export KBUILD_BUILD_USER="Aetherion"
export KBUILD_BUILD_HOST="VelionV3"
export PATH="$CLANG_DIR/bin:$PATH"

# 4. Configure Defconfig
echo "🔧 Configuring..."
DEFCONFIG_PATH="arch/arm64/configs/$DEFCONFIG"
sed -i '/CONFIG_COMPAT_VDSO/d' "$DEFCONFIG_PATH" || true
echo "CONFIG_COMPAT_VDSO=y" >> "$DEFCONFIG_PATH"

make O=out "$DEFCONFIG"

# Parse Version Info (Safe Mode)
if [[ -f out/.config ]]; then
    RAW_VERSION=$(grep "CONFIG_LOCALVERSION=" out/.config | cut -d'"' -f2 || echo "Velion")
    RAW_VERSION="${RAW_VERSION#-}"
    IFS=- read -r KERNEL_VARIANT KERNEL_CODENAME RELEASE_VERSION <<< "$RAW_VERSION"
fi

KERNEL_VARIANT=${KERNEL_VARIANT:-"Velion"}
KERNEL_CODENAME=${KERNEL_CODENAME:-"miatoll"}
RELEASE_VERSION=${RELEASE_VERSION:-"Test"}

# 5. Start Compilation & Dashboard
echo "🔥 Starting Compilation..."
START_TIME=$(date +%s)

TG_RESPONSE=$(tg_send "🚀 <b>Build Started</b>%0AInitializing compilation with Clean Build: <b>${CLEAN_BUILD:-false}</b>")
MSG_ID=$(echo "$TG_RESPONSE" | jq -r '.result.message_id' 2>/dev/null || echo "")

if [[ -n "$MSG_ID" && "$MSG_ID" != "null" ]]; then
    start_monitor "$MSG_ID" "$START_TIME" &
    MONITOR_PID=$!
else
    echo "⚠️ Failed to get Message ID. Live updates disabled."
fi

# Run Make
if ! make -j"$(nproc)" O=out \
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
    2>&1 | tee build.log; then

    [[ -n "$MSG_ID" ]] && tg_edit "$MSG_ID" "❌ <b>Build Failed</b>%0ACheck logs for details."
    exit 1
fi

# 6. Post-Build Actions
[[ -n "$MSG_ID" ]] && tg_edit "$MSG_ID" "✅ <b>Compilation Done</b>%0APackaging Kernel..."

echo "📦 Packaging..."
# Optimized clone depth
git clone --quiet --depth=1 -b "$ANYKERNEL_BRANCH" "https://github.com/AzyrRuthless/AnyKernel3" anykernel

if [[ -f out/arch/arm64/boot/Image.gz-dtb ]]; then
    cp out/arch/arm64/boot/Image.gz-dtb anykernel/Image.gz-dtb
elif [[ -f out/arch/arm64/boot/Image.gz ]]; then
    cp out/arch/arm64/boot/Image.gz anykernel/
fi

# Safe copy for dtbo/dtb
[[ -f out/arch/arm64/boot/dtbo.img ]] && cp out/arch/arm64/boot/dtbo.img anykernel/
mkdir -p anykernel/dtb
find out/arch/arm64/boot/dts/qcom -name "cust-atoll-ab.dtb" -exec cp {} anykernel/dtb/ \;

TIME_TAG=$(date '+%d%m%Y')
ZIP_NAME="${PROJECT_NAME}-${KERNEL_VARIANT}-${KERNEL_CODENAME}-${RELEASE_VERSION}-${TIME_TAG}.zip"

cd anykernel
zip -r9 "../$ZIP_NAME" . -x "*.git*" "README.md" ".*" >/dev/null
cd ..

# Final Success Notification
FINAL_DURATION=$(( ($(date +%s) - START_TIME) / 60 ))m
[[ -n "$MSG_ID" ]] && tg_edit "$MSG_ID" "✅ <b>Build Success</b>%0A%0A📦 File: <code>$ZIP_NAME</code>%0A⏱ Duration: $FINAL_DURATION"
tg_doc "$ZIP_NAME" "✅ Build by GitHub Actions"
