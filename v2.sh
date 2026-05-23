#!/usr/bin/env bash

set -e
SECONDS=0

############################ helpers ############################
log() { echo "[$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- Telegram helpers ----------------------------------------------------
tg() {                       # send plain-text message
    local msg="$1"
    local ts=$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S')
    echo "➡️  Telegram: $msg (at $ts WIB)"
    curl -s -X POST \
         "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
         -d chat_id="${TELEGRAM_CHAT_ID}" \
         -d text="${msg} - \`${ts}\`" >/dev/null
}

tg_doc() {                   # send file with caption
    local file="$1" caption="$2"
    local esc=$(printf '%q' "$caption")
    echo "➡️  Telegram upload: $file"
    if ! curl -s -X POST \
          "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
          -F chat_id="${TELEGRAM_CHAT_ID}" \
          -F document="@$file" \
          -F parse_mode="MarkdownV2" \
          -F caption="${esc}"; then
        echo "❌ Telegram upload failed: $file"
        tg "❌ Telegram upload failed: $file"
    fi
}

handle_error() {             # generic trap-handler
    local cmd="$BASH_COMMAND" line="$LINENO"
    echo "❌ Error at line $line: $cmd"
    tg   "❌ Error at line \`$line\`: \`$cmd\`"
    exit 1
}
trap 'handle_error' ERR
# -------------------------------------------------------------------------

############################ cleanup & source ###################
log "🚀 Build started"
tg  "🚀 Build started!"

rm -rf "$GITHUB_WORKSPACE/Velion_Kernel"
git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_SOURCE" "$GITHUB_WORKSPACE/Velion_Kernel"
cd "$GITHUB_WORKSPACE/Velion_Kernel"

############################ KernelSU manual ####################
log "🧩 Integrating KernelSU"
curl -LSs "https://raw.githubusercontent.com/AzyrRuthless/KernelSU/main/kernel/setup.sh" | bash -s susfs-rksu-master

############################ ccache #############################
export CCACHE_DIR=/tmp/ccache
export USE_CCACHE=1
ccache -M10G -o compression=true -z

############################ Clang r547379 ######################
log "⬇️ Setting up Clang r547379"
CLANG_DIR="$HOME/clang-r547379"
if [ ! -d "$CLANG_DIR" ]; then
  git clone --depth=1 https://gitea.com/ihsanulrahman/aosp-clang-22 "$CLANG_DIR"
fi
export PATH="$CLANG_DIR/bin:$PATH"

############################ build vars #########################
export ARCH=arm64
export KBUILD_BUILD_USER=Aetherion
export KBUILD_BUILD_HOST=VelionV2
export TZ=Asia/Jakarta
export KBUILD_BUILD_TIMESTAMP=$(date '+%a %b %d %H:%M:%S %Z %Y')
export LD=ld.lld AR=llvm-ar NM=llvm-nm STRIP=llvm-strip OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump
export CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-

export PROJECT_NAME="KSU"
export DEVICE_CODENAME="miatoll"

DEFCONFIG=vendor/xiaomi/miatoll_defconfig
log "⚙️ Using defconfig: $DEFCONFIG"

# Extract version info from defconfig
RELEASE_VERSION=$(grep "CONFIG_LOCALVERSION=" arch/arm64/configs/$DEFCONFIG | sed 's/CONFIG_LOCALVERSION="\(.*\)"/\1/')
RELEASE_VERSION="${RELEASE_VERSION#-}"
IFS=- read -r KERNEL_VARIANT KERNEL_CODENAME RELEASE <<< "$RELEASE_VERSION" || true

log "ℹ️ Kernel Variant: $KERNEL_VARIANT"
log "ℹ️ Kernel Codename: $KERNEL_CODENAME"
log "ℹ️ Release Version: $RELEASE"

mkdir -p out
make O=out $DEFCONFIG

############################ compile ############################
log "🔥 Compiling kernel"
make -j"$(nproc)" O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     CC="ccache clang" LD=ld.lld AR=$AR NM=$NM STRIP=$STRIP \
     OBJCOPY=$OBJCOPY OBJDUMP=$OBJDUMP \
     CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
     2>&1 | tee build.log

# Tool-chain versions
CLANG_VERSION=$(clang --version | head -n 1)
LLD_VERSION=$(ld.lld --version | head -n 1)
log "ℹ️ Using clang: $CLANG_VERSION"
log "ℹ️ Using ld.lld: $LLD_VERSION"

############################ package ############################
log "⬇️ Cloning AnyKernel3"
AK3="$PWD/anykernel"
git clone -q -b V2 https://github.com/AzyrRuthless/AnyKernel3 "$AK3"

log "➡️ Copying build outputs"
cp out/arch/arm64/boot/Image.gz "$AK3"
cp out/arch/arm64/boot/dtbo.img "$AK3"
mkdir -p "$AK3/dtb"
cp out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb "$AK3/dtb"

ZIP_NAME="${PROJECT_NAME}-${KERNEL_VARIANT}-${KERNEL_CODENAME}-${RELEASE}-${DEVICE_CODENAME}-$(date '+%d%m%Y').zip"
log "🗜️ Creating ZIP archive: $ZIP_NAME"
cd "$AK3"
zip -r9 "../$ZIP_NAME" ./* -x '*.git*' README.md ./*placeholder
cd "$GITHUB_WORKSPACE/Velion_Kernel"

ARTIFACT_DIR="$GITHUB_WORKSPACE/kernel_artifacts"
mkdir -p "$ARTIFACT_DIR"
cp "$ZIP_NAME" build.log "$ARTIFACT_DIR"
echo "artifact_dir=$ARTIFACT_DIR" >> $GITHUB_OUTPUT

DUR_MIN=$((SECONDS/60)); DUR_SEC=$((SECONDS%60))
log "🎉 Build completed in ${DUR_MIN}m ${DUR_SEC}s!"
log "📦 ZIP archive: $ZIP_NAME"
tg  "✅ Kernel compilation completed! 🎉 File: \`$ZIP_NAME\`"
tg_doc "$ZIP_NAME" "✅ Build finished after ${DUR_MIN}m ${DUR_SEC}s"
