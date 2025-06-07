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
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage"     -d chat_id="$TELEGRAM_CHAT_ID"     -d text="$msg - \`$formatted_date\`" > /dev/null
}

# --- Function to send Telegram documents with error handling ---
tg_doc() {
  local file="$1"
  local caption="$2"
  local formatted_caption=$(printf '%q' "$caption") # Properly quote the caption
  log "➡️ Sending Telegram document: $file with caption: $caption"
  if ! curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument"     -F chat_id="$TELEGRAM_CHAT_ID"     -F document="@$file"     -F parse_mode="MarkdownV2"     -F caption="${formatted_caption}"; then # Use the quoted caption
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
if [ -d "$GITHUB_WORKSPACE/Kinesis_Kernel" ]; then
  log "🗑️ Cleaning up previous kernel directory..."
  rm -rf "$GITHUB_WORKSPACE/Kinesis_Kernel"
fi

# --- Clone the kernel source ---
log "⬇️ Cloning kernel source from: $KERNEL_SOURCE (branch: $KERNEL_BRANCH)..."
if ! git clone "$KERNEL_SOURCE" -b "$KERNEL_BRANCH" "$GITHUB_WORKSPACE/Kinesis_Kernel" --depth=1; then
  handle_error "Failed to clone kernel source"
fi
cd "$GITHUB_WORKSPACE/Kinesis_Kernel" || handle_error "Failed to enter kernel directory"

# --- Integrate KernelSU-Next ---
log "🧩 Integrating KernelSU-Next..."
KERNELSU_DIR_NAME="KernelSU-Next" # Define a name for the directory within the kernel tree
KERNELSU_TARGET_DIR="$GITHUB_WORKSPACE/Kinesis_Kernel/kernel/$KERNELSU_DIR_NAME"

# Check if KernelSU-Next needs to be cloned or updated (basic check)
if [ ! -d "$KERNELSU_TARGET_DIR/.git" ]; then # If not a git repo, clone it
  log "Cloning KernelSU-Next..."
  git clone -q -b next https://github.com/AzyrRuthless/KernelSU-Next.git "$KERNELSU_TARGET_DIR"
else
  log "Updating KernelSU-Next..."
  (cd "$KERNELSU_TARGET_DIR" && git stash --quiet && git checkout --quiet next && git pull --quiet)
fi
log "✅ KernelSU-Next integrated/updated."


# --- Determine driver directory ---
if [ -d "$GITHUB_WORKSPACE/Kinesis_Kernel/common/drivers" ]; then
  DRIVER_DIR="$GITHUB_WORKSPACE/Kinesis_Kernel/common/drivers"
elif [ -d "$GITHUB_WORKSPACE/Kinesis_Kernel/drivers" ];then
  DRIVER_DIR="$GITHUB_WORKSPACE/Kinesis_Kernel/drivers"
else
  handle_error '"drivers/" directory not found'
fi

# --- Create a symlink for KernelSU ---
log "🔗 Creating symlink for KernelSU..."
ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$KERNELSU_TARGET_DIR/kernel")" "$DRIVER_DIR/kernelsu"
log "✅ Symlink created."


# --- Modify Makefile and Kconfig ---
DRIVER_MAKEFILE="$DRIVER_DIR/Makefile"
DRIVER_KCONFIG="$DRIVER_DIR/Kconfig"

log "📝 Modifying Makefile..."
if ! grep -q "kernelsu" "$DRIVER_MAKEFILE"; then
  printf "
obj-\$(CONFIG_KSU) += kernelsu/
" >> "$DRIVER_MAKEFILE"
  log "✅ Makefile modified."
fi

log "📝 Modifying Kconfig..."
if ! grep -q "source "drivers/kernelsu/Kconfig"" "$DRIVER_KCONFIG"; then
  if grep -q "endmenu" "$DRIVER_KCONFIG"; then
    sed -i "/endmenu/i\source "drivers/kernelsu/Kconfig"" "$DRIVER_KCONFIG"
  else
    sed -i "/endif/i\source "drivers/kernelsu/Kconfig"" "$DRIVER_KCONFIG"
  fi
  log "✅ Kconfig modified."
fi

# --- ccache setup is now handled by Cirrus CI cache populate_script ---
log "✅ ccache is configured by Cirrus CI."

# --- Zyc-Clang is now cached by Cirrus CI ---
log "🧰 Using Zyc-Clang from cached directory: $ZYC_CLANG_DIR"
if [ ! -d "$ZYC_CLANG_DIR" ] || [ -z "$(ls -A $ZYC_CLANG_DIR)" ]; then
  handle_error "Zyc-Clang directory ($ZYC_CLANG_DIR) not found or empty. Cache might have failed."
fi
export PATH="$ZYC_CLANG_DIR/bin:$PATH"
log "✅ Zyc-Clang PATH configured."


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

# PROJECT_NAME is set in Cirrus CI env, DEVICE_CODENAME is specific to this script context
# export PROJECT_NAME="KSU" # This is set by Cirrus CI env
export DEVICE_CODENAME="miatoll"

# --- Set defconfig ---
DEFCONFIG="vendor/xiaomi/miatoll_defconfig"
log "⚙️ Using defconfig: $DEFCONFIG"

# --- Get release version from defconfig ---
DEFCONFIG_PATH="$GITHUB_WORKSPACE/Kinesis_Kernel/arch/arm64/configs/$DEFCONFIG"
if [ ! -f "$DEFCONFIG_PATH" ]; then
    handle_error "Defconfig file not found at $DEFCONFIG_PATH"
fi
DEFCONFIG_CONTENT=$(cat "$DEFCONFIG_PATH")
RELEASE_VERSION_LINE=$(echo "$DEFCONFIG_CONTENT" | grep "CONFIG_LOCALVERSION=")
if [ -z "$RELEASE_VERSION_LINE" ]; then
    handle_error "CONFIG_LOCALVERSION not found in defconfig"
fi
RELEASE_VERSION=$(echo "$RELEASE_VERSION_LINE" | sed 's/CONFIG_LOCALVERSION="\(.*\)"/\1/')
RELEASE_VERSION="${RELEASE_VERSION#-}"

KERNEL_VARIANT_FROM_DEFCONFIG=""
KERNEL_CODENAME_FROM_DEFCONFIG=""
VERSION_SUFFIX_FROM_DEFCONFIG=""

if [[ "$RELEASE_VERSION" == KSU-* ]]; then
    KERNEL_VARIANT_FROM_DEFCONFIG="KSU"
    TEMP_VERSION=${RELEASE_VERSION#KSU-}
    KERNEL_CODENAME_FROM_DEFCONFIG=$(echo "$TEMP_VERSION" | cut -d'-' -f1)
    VERSION_SUFFIX_FROM_DEFCONFIG=$(echo "$TEMP_VERSION" | cut -d'-' -f2-)
else
    IFS='-' read -ra PARTS <<< "$RELEASE_VERSION"
    KERNEL_VARIANT_FROM_DEFCONFIG="${PARTS[0]}"
    KERNEL_CODENAME_FROM_DEFCONFIG="${PARTS[1]}"
    VERSION_SUFFIX_FROM_DEFCONFIG=$(IFS="-"; echo "${PARTS[*]:2}")
fi

log "ℹ️ Kernel Variant from defconfig: $KERNEL_VARIANT_FROM_DEFCONFIG"
log "ℹ️ Kernel Codename from defconfig: $KERNEL_CODENAME_FROM_DEFCONFIG"
log "ℹ️ Version Suffix from defconfig: $VERSION_SUFFIX_FROM_DEFCONFIG"


# --- Create output directory ---
mkdir -p out
log "📁 Output directory created at: out/"

# --- Make defconfig ---
log "⚙️ Generating defconfig..."
make O=out $DEFCONFIG

# --- Clean output directory if requested ---
if [[ "$1" == "-c" || "$1" == "--clean" ]]; then
  log "🗑️ Cleaning output directory..."
  rm -rf out
  log "✅ Output directory cleaned."
  exit 0
fi

# --- Regenerate defconfig if requested ---
if [[ "$1" == "-r" || "$1" == "--regen" ]]; then
  log "🔄 Regenerating defconfig..."
  make O=out ARCH=arm64 $DEFCONFIG savedefconfig
  cp out/defconfig "$DEFCONFIG_PATH"
  log "✅ Defconfig regenerated."
  exit 0
fi

# --- Start kernel compilation ---
log "🔥 Starting kernel compilation..."
export USE_CCACHE=1
make -j$(nproc --all) O=out ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1 LD=ld.lld CROSS_COMPILE=aarch64-linux-gnu- 2>&1 | tee build.log

if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
  tg_doc "build.log" "❌ Build failed after $((SECONDS / 60)) minutes $((SECONDS % 60)) seconds. Error during make."
  handle_error "Compilation failed (make process exited with non-zero)"
fi

# --- Get Clang and LLD versions ---
CLANG_VERSION=$($ZYC_CLANG_DIR/bin/clang --version 2>&1 | head -n 1)
LLD_VERSION=$($ZYC_CLANG_DIR/bin/ld.lld --version 2>&1 | head -n 1)
log "ℹ️ Using Clang: $CLANG_VERSION"
log "ℹ️ Using LLD: $LLD_VERSION"

# --- AnyKernel3 is now cached by Cirrus CI ---
ANYKERNEL_LOCAL_PATH="$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"
log "📦 Using AnyKernel3 from cached directory: $ANYKERNEL_DIR"
if [ ! -d "$ANYKERNEL_DIR" ] || [ -z "$(ls -A $ANYKERNEL_DIR)" ]; then
  handle_error "AnyKernel3 directory ($ANYKERNEL_DIR) not found or empty. Cache might have failed."
fi
cp -r "$ANYKERNEL_DIR/." "$ANYKERNEL_LOCAL_PATH/" # Ensure dotfiles are copied if any, and content goes into dir
log "✅ AnyKernel3 copied to $ANYKERNEL_LOCAL_PATH"


# --- Copy files to AnyKernel3 ---
log "➡️ Copying Image.gz..."
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "$ANYKERNEL_LOCAL_PATH/"
log "➡️ Copying dtbo.img..."
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "$ANYKERNEL_LOCAL_PATH/"
log "📁 Creating dtb directory in AnyKernel3..."
mkdir -p "$ANYKERNEL_LOCAL_PATH/dtb"
log "➡️ Copying cust-atoll-ab.dtb..."
SOURCE_DTB_PATH="$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb"
if [ ! -f "$SOURCE_DTB_PATH" ]; then
    handle_error "cust-atoll-ab.dtb not found at $SOURCE_DTB_PATH"
fi
cp "$SOURCE_DTB_PATH" "$ANYKERNEL_LOCAL_PATH/dtb/"


# --- Create ZIP archive ---
# Use PROJECT_NAME from Cirrus env
FINAL_PROJECT_NAME=${PROJECT_NAME} # Relies on PROJECT_NAME from Cirrus CI env
ZIP_NAME="${FINAL_PROJECT_NAME}-${KERNEL_VARIANT_FROM_DEFCONFIG}-${KERNEL_CODENAME_FROM_DEFCONFIG}-${DEVICE_CODENAME}-${VERSION_SUFFIX_FROM_DEFCONFIG}-$(date '+%d%m%Y').zip"
ZIP_NAME=$(echo "$ZIP_NAME" | sed 's/--/-/g' | sed 's/^-//' | sed 's/-$//')

log "🗜️ Creating ZIP archive: $ZIP_NAME"
cd "$ANYKERNEL_LOCAL_PATH" || handle_error "Failed to enter AnyKernel3 directory ($ANYKERNEL_LOCAL_PATH)"
zip -r9 "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" ./* -x '*.git*' README.md ./*placeholder '.github/*'
cd "$GITHUB_WORKSPACE/Kinesis_Kernel" || handle_error "Failed to return to kernel directory"


# --- Build completion notification ---
BUILD_DURATION_MINUTES=$((SECONDS / 60))
BUILD_DURATION_SECONDS=$((SECONDS % 60))
log "🎉 Build completed in ${BUILD_DURATION_MINUTES} minutes ${BUILD_DURATION_SECONDS} seconds!"
log "📦 ZIP archive: $ZIP_NAME"

TG_CAPTION="✅ Build finished after ${BUILD_DURATION_MINUTES}m ${BUILD_DURATION_SECONDS}s"
tg "✅ Kernel compilation completed\! 🎉 File: \`$ZIP_NAME\`"
tg_doc "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "$TG_CAPTION"


# --- Upload artifacts ---
ARTIFACT_DIR="$GITHUB_WORKSPACE/kernel_artifacts"
log "⬆️ Uploading artifacts to: $ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "$ARTIFACT_DIR/"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "$ARTIFACT_DIR/"
if [ -f "$SOURCE_DTB_PATH" ]; then
    cp "$SOURCE_DTB_PATH" "$ARTIFACT_DIR/"
fi
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "$ARTIFACT_DIR/"

# --- Debugging output ---
log "🔍 Contents of $GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot:"
ls -la "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/"
log "🔍 Contents of $GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom:"
ls -la "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/"
log "🔍 Contents of $ARTIFACT_DIR:"
ls -la "$ARTIFACT_DIR"

log "✅ Build process finished successfully."
