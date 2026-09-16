#!/bin/bash
set -e

# --- Project and Kernel Configuration ---
PROJECT_NAME="KSU-Kinesis"
KERNEL_SOURCE="https://github.com/AzyrRuthless/kernel_xiaomi_sm6250"
KERNEL_BRANCH="Next"
DEVICE_CODENAME="miatoll"  # Replace with your device's codename
DEFCONFIG="vendor/xiaomi/miatoll_defconfig"  # Replace with your defconfig path
KERNEL_VARIANT="KSU"
# --- Telegram Bot (Optional) ---
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}" # Set in Gitpod Environment Variables
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" # Set in Gitpod Environment Variables
USE_TELEGRAM_NOTIF=false  # Set to true if you want Telegram notifications
if [ -n "$TELEGRAM_CHAT_ID" ] && [ -n "$TELEGRAM_BOT_TOKEN" ]; then
  USE_TELEGRAM_NOTIF=true
fi

# --- Function to log messages with timestamp ---
log() {
  local msg="$1"
  local formatted_date=$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S')
  echo "[$formatted_date] $msg"
}

# --- Function to send Telegram notifications ---
tg() {
  if ! $USE_TELEGRAM_NOTIF; then
    return 0
  fi
  local msg="$1"
  local formatted_date=$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S')
  log "➡️ Sending Telegram message: $msg (at $formatted_date WIB)"
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d text="$msg - \`$formatted_date\`" > /dev/null
}

# --- Function to send Telegram documents with error handling ---
tg_doc() {
  if ! $USE_TELEGRAM_NOTIF; then
    return 0
  fi
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

# --- Build start time ---
SECONDS=0
log "🚀 Starting build at $(date)"
tg "🚀 Build started\!"

# --- Install Dependencies ---
log "📦 Installing dependencies..."
sudo apt update
sudo apt install -y git bison flex libxml2 libssl-dev bc zip default-jre python3 python3-pip wget curl cpio bash ccache jq
log "✅ Dependencies installed successfully!"

# --- Setup ccache ---
log "🧰 Setting up ccache..."
export CCACHE_DIR=/tmp/ccache
export CCACHE_EXEC=$(which ccache)
export USE_CCACHE=1
ccache -M 10G
ccache -o compression=true
ccache -z
log "✅ ccache configured."

# --- Download and Extract Zyc-Clang ---
log "⬇️ Downloading and extracting Zyc-Clang..."
if [ ! -d "$HOME/Zyc-Clang" ]; then
  LATEST_RELEASE_URL=$(curl -s "https://api.github.com/repos/ZyCromerZ/Clang/releases/latest" | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url')
  if [ -z "$LATEST_RELEASE_URL" ]; then
    handle_error "Failed to retrieve the latest release URL for Zyc-Clang"
  fi
  wget "$LATEST_RELEASE_URL" -O "$HOME/Zyc-Clang.tar.gz"
  mkdir -p "$HOME/Zyc-Clang"
  tar -xf "$HOME/Zyc-Clang.tar.gz" -C "$HOME/Zyc-Clang"
  rm "$HOME/Zyc-Clang.tar.gz"
  log "✅ Zyc-Clang downloaded and extracted to $HOME/Zyc-Clang"
else
  log "✅ Zyc-Clang already exists at $HOME/Zyc-Clang"
fi

# --- Set environment variables ---
log "🔧 Setting environment variables..."
export PATH="$HOME/Zyc-Clang/bin:$PATH"
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

# --- Set project variables ---
export PROJECT_NAME="${PROJECT_NAME}"

# --- Clean up previous kernel directory ---
if [ -d "/workspace/Kinesis_Kernel" ]; then
  log "🗑️ Cleaning up previous kernel directory..."
  rm -rf "/workspace/Kinesis_Kernel"
fi

# --- Clone the kernel source ---
log "⬇️ Cloning kernel source from: $KERNEL_SOURCE (branch: $KERNEL_BRANCH)..."
if ! git clone "$KERNEL_SOURCE" -b "$KERNEL_BRANCH" "/workspace/Kinesis_Kernel" --depth=1; then
  handle_error "Failed to clone kernel source"
fi
cd "/workspace/Kinesis_Kernel" || handle_error "Failed to enter kernel directory"

# --- Integrate KernelSU-Next ---
log "🧩 Integrating KernelSU-Next..."
KERNELSU_DIR="/workspace/Kinesis_Kernel/kernel/KernelSU-Next"
if [ ! -d "$KERNELSU_DIR" ]; then
  git clone -b next https://github.com/AzyrRuthless/KernelSU-Next.git "$KERNELSU_DIR"
  log "✅ KernelSU-Next repository cloned."
fi
cd "$KERNELSU_DIR"
git stash && log "➖ Stashed current changes."
git checkout next && log "➖ Switched to 'next' branch."
git pull && log "🔄 KernelSU-Next repository updated."
cd "/workspace/Kinesis_Kernel"

# --- Determine driver directory ---
if [ -d "/workspace/Kinesis_Kernel/common/drivers" ]; then
  DRIVER_DIR="/workspace/Kinesis_Kernel/common/drivers"
elif [ -d "/workspace/Kinesis_Kernel/drivers" ]; then
  DRIVER_DIR="/workspace/Kinesis_Kernel/drivers"
else
  handle_error '"drivers/" directory not found'
fi

# --- Create a symlink for KernelSU ---
log "🔗 Creating symlink for KernelSU..."
ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$KERNELSU_DIR/kernel")" "$DRIVER_DIR/kernelsu"
log "✅ Symlink created."

# --- Modify Makefile and Kconfig ---
DRIVER_MAKEFILE="$DRIVER_DIR/Makefile"
DRIVER_KCONFIG="$DRIVER_DIR/Kconfig"

log "📝 Modifying Makefile..."
if ! grep -q "kernelsu" "$DRIVER_MAKEFILE"; then
  printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_MAKEFILE"
  log "✅ Makefile modified."
fi

log "📝 Modifying Kconfig..."
if ! grep -q "source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG"; then
  sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG"
  log "✅ Kconfig modified."
fi

# --- Set defconfig ---
log "⚙️ Using defconfig: $DEFCONFIG"

# --- Get release version from defconfig ---
DEFCONFIG_CONTENT=$(cat arch/arm64/configs/$DEFCONFIG)
RELEASE_VERSION=$(echo "$DEFCONFIG_CONTENT" | grep "CONFIG_LOCALVERSION=" | sed 's/CONFIG_LOCALVERSION="\(.*\)"/\1/')
RELEASE_VERSION="${RELEASE_VERSION#-}"
IFS=- read -r KERNEL_VARIANT_DEFCONFIG KERNEL_CODENAME_DEFCONFIG RELEASE_VERSION <<< "$RELEASE_VERSION" || true
KERNEL_VARIANT="${KERNEL_VARIANT:-$KERNEL_VARIANT_DEFCONFIG}"
KERNEL_CODENAME="${DEVICE_CODENAME:-$KERNEL_CODENAME_DEFCONFIG}"
log "ℹ️ Kernel Variant: $KERNEL_VARIANT"
log "ℹ️ Kernel Codename: $KERNEL_CODENAME"
log "ℹ️ Release Version: $RELEASE_VERSION"

# --- Create output directory ---
mkdir -p out
log "📁 Output directory created at: out/"

# --- Make defconfig ---
log "⚙️ Generating defconfig..."
make O=out $DEFCONFIG

# --- Clean output directory if requested with -c or --clean ---
if [[ "$1" == "-c" || "$1" == "--clean" ]]; then
  log "🗑️ Cleaning output directory..."
  rm -rf out
  log "✅ Output directory cleaned."
  exit 0
fi

# --- Regenerate defconfig if requested with -r or --regen ---
if [[ "$1" == "-r" || "$1" == "--regen" ]]; then
  log "🔄 Regenerating defconfig..."
  make O=out ARCH=arm64 $DEFCONFIG savedefconfig
  cp out/defconfig arch/arm64/configs/$DEFCONFIG
  log "✅ Defconfig regenerated."
  exit 0
fi

# --- Start kernel compilation ---
log "🔥 Starting kernel compilation..."
make -j$(nproc --all) O=out ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1 LD=ld.lld CROSS_COMPILE=aarch64-linux-gnu- 2>&1 | tee build.log

# --- Check for compilation errors ---
if [[ $? -ne 0 ]]; then
  handle_error "Compilation failed"
  tg_doc "build.log" "❌ Build failed after $((SECONDS / 60)) minutes $((SECONDS % 60)) seconds"
  exit 1
fi

# --- Get Clang and LLD versions ---
CLANG_VERSION=$($HOME/Zyc-Clang/bin/clang --version 2>&1 | head -n 1)
LLD_VERSION=$($HOME/Zyc-Clang/bin/ld.lld --version 2>&1 | head -n 1)
log "ℹ️ Using Clang: $CLANG_VERSION"
log "ℹ️ Using LLD: $LLD_VERSION"

# --- Clone AnyKernel3 ---
log "⬇️ Cloning AnyKernel3..."
if ! git clone -q https://github.com/AzyrRuthless/AnyKernel3 "/workspace/Kinesis_Kernel/anykernel"; then
  handle_error "Failed to clone AnyKernel3"
fi

# --- Copy files to AnyKernel3 ---
log "➡️ Copying Image.gz..."
cp "/workspace/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "/workspace/Kinesis_Kernel/anykernel"
log "➡️ Copying dtbo.img..."
cp "/workspace/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "/workspace/Kinesis_Kernel/anykernel"
log "📁 Creating dtb directory in AnyKernel3..."
mkdir -p "/workspace/Kinesis_Kernel/anykernel/dtb"
log "➡️ Copying cust-atoll-ab.dtb..."
cp "/workspace/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb" "/workspace/Kinesis_Kernel/anykernel/dtb"

# --- Create ZIP archive ---
ZIP_NAME="${PROJECT_NAME}-${KERNEL_VARIANT}-${DEVICE_CODENAME}-$(date '+%Y%m%d').zip"
log "🗜️ Creating ZIP archive: $ZIP_NAME"
cd "/workspace/Kinesis_Kernel/anykernel" || handle_error "Failed to enter AnyKernel3 directory"
zip -r9 "../$ZIP_NAME" ./* -x '*.git*' README.md ./*placeholder
cd "/workspace/Kinesis_Kernel" || handle_error "Failed to return to kernel directory"

# --- Build completion notification ---
BUILD_DURATION_MINUTES=$((SECONDS / 60))
BUILD_DURATION_SECONDS=$((SECONDS % 60))
log "🎉 Build completed in ${BUILD_DURATION_MINUTES} minutes ${BUILD_DURATION_SECONDS} seconds!"
log "📦 ZIP archive: $ZIP_NAME"

tg "✅ Kernel compilation completed\! 🎉 File: \`$ZIP_NAME\`"
tg_doc "/workspace/Kinesis_Kernel/$ZIP_NAME" "✅ Build finished after ${BUILD_DURATION_MINUTES} minutes ${BUILD_DURATION_SECONDS} seconds"

# --- Copy artifacts to a dedicated directory ---
ARTIFACT_DIR="/workspace/kernel_artifacts"
log "⬆️ Copying artifacts to directory: $ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"
cp "/workspace/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "$ARTIFACT_DIR/"
cp "/workspace/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "$ARTIFACT_DIR/"
cp "/workspace/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb" "$ARTIFACT_DIR/"
cp "/workspace/Kinesis_Kernel/$ZIP_NAME" "$ARTIFACT_DIR/"

log "🔍 Contents of /workspace/Kinesis_Kernel/out/arch/arm64/boot:"
ls -la "/workspace/Kinesis_Kernel/out/arch/arm64/boot/"
log "🔍 Contents of /workspace/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom:"
ls -la "/workspace/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/"
log "🔍 Contents of $ARTIFACT_DIR:"
ls -la "$ARTIFACT_DIR"

log "✅ Kernel artifacts and zip archive successfully copied to $ARTIFACT_DIR"
log "🎉 Kernel Build Completed! Artifacts can be found at: $ARTIFACT_DIR"
tg "🎉 Kernel Build Completed! Artifacts can be found at: \`$ARTIFACT_DIR\`"
