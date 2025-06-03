#!/bin/bash
set -e

# --- Function to log messages with timestamp and log level ---
LOG_FILE="build.log"
log() {
  local level="$1"
  local msg="$2"
  local formatted_date=$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S')
  echo "[$formatted_date] [$level] $msg" | tee -a "$LOG_FILE"
}

# --- Function to send Telegram notifications ---
tg() {
  local msg="$1"
  local formatted_date=$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S')
  log "INFO" "➡️ Sending Telegram message: $msg (at $formatted_date WIB)"
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d text="$msg - \`$formatted_date\`" > /dev/null
}

# --- Function to send Telegram documents with error handling ---
tg_doc() {
  local file="$1"
  local caption="$2"
  local formatted_caption=$(printf '%q' "$caption")
  log "INFO" "➡️ Sending Telegram document: $file"
  if ! curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" \
    -F chat_id="$TELEGRAM_CHAT_ID" \
    -F document="@$file" \
    -F parse_mode="MarkdownV2" \
    -F caption="${formatted_caption}"; then
    log "ERROR" "❌ Failed to send Telegram document: $file"
    tg "❌ Failed to send Telegram document: $file"
  fi
}

# --- Function to handle errors with logging ---
handle_error() {
  local line_number="$1"
  local error_message="$2"
  log "ERROR" "❌ An error occurred in script '$0' at line $line_number: $error_message"
  tg "❌ An error occurred in script '$0' at line $line_number: \`$error_message\`"
  exit 1
}

# --- Start of Script ---

# --- Environment Setup ---
log "INFO" "🚀 Starting build at $(date)"
tg "🚀 Build started\!"

# --- Clean up previous kernel directory ---
if [ -d "$GITHUB_WORKSPACE/Kinesis_Kernel" ]; then
  log "INFO" "🗑️ Cleaning up previous kernel directory..."
  rm -rf "$GITHUB_WORKSPACE/Kinesis_Kernel"
fi

# --- Clone the kernel source ---
log "INFO" "⬇️ Cloning kernel source from: $KERNEL_SOURCE (branch: $KERNEL_BRANCH)..."
if ! git clone "$KERNEL_SOURCE" -b "$KERNEL_BRANCH" "$GITHUB_WORKSPACE/Kinesis_Kernel" --depth=1; then
  handle_error "$LINENO" "Failed to clone kernel source"
fi
cd "$GITHUB_WORKSPACE/Kinesis_Kernel" || handle_error "$LINENO" "Failed to enter kernel directory"

# --- Setup ccache ---
log "INFO" "🧰 Setting up ccache..."
export CCACHE_DIR=/tmp/ccache
export CCACHE_EXEC=$(which ccache)
export USE_CCACHE=1
ccache -M 10G
ccache -o compression=true
ccache -z
log "INFO" "✅ ccache configured."

# --- Download and Extract Zyc-Clang ---
log "INFO" "⬇️ Downloading and extracting Zyc-Clang..."
if [ ! -d "$HOME/Zyc-Clang" ]; then
  LATEST_RELEASE_URL=$(curl -s "https://api.github.com/repos/ZyCromerZ/Clang/releases/latest" | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url')
  if [ -z "$LATEST_RELEASE_URL" ]; then
    handle_error "$LINENO" "Failed to retrieve the latest release URL for Zyc-Clang"
  fi
  wget "$LATEST_RELEASE_URL" -O "$HOME/Zyc-Clang.tar.gz"
  mkdir -p "$HOME/Zyc-Clang"
  tar -xf "$HOME/Zyc-Clang.tar.gz" -C "$HOME/Zyc-Clang"
  rm "$HOME/Zyc-Clang.tar.gz"
  log "INFO" "✅ Zyc-Clang downloaded and extracted to $HOME/Zyc-Clang"
else
  log "INFO" "✅ Zyc-Clang already exists at $HOME/Zyc-Clang"
fi

# --- Set environment variables ---
log "INFO" "🔧 Setting environment variables..."
export PATH="$HOME/Zyc-Clang/bin:$PATH"
export ARCH=arm64
export KBUILD_BUILD_USER=Audemars
export KBUILD_BUILD_HOST=ROG-G834JYR
export TZ=Asia/Jakarta
export KBUILD_BUILD_TIMESTAMP=$(date '+%a %b %d %H:%M:%S %Z %Y')

# --- Set LLVM toolchain flags ---
# These ensure that the kernel is compiled with LLVM tools
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export STRIP=llvm-strip
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump

export PROJECT_NAME="NONKSU" # Project name
export DEVICE_CODENAME="miatoll" # Device codename

# --- Set defconfig ---
DEFCONFIG="vendor/xiaomi/miatoll_defconfig" # Defconfig path
log "INFO" "⚙️ Using defconfig: $DEFCONFIG"

# --- Get release version from defconfig ---
# This extracts the kernel version information from the defconfig file
DEFCONFIG_CONTENT=$(cat arch/arm64/configs/$DEFCONFIG)
RELEASE_VERSION=$(echo "$DEFCONFIG_CONTENT" | grep "CONFIG_LOCALVERSION=" | sed 's/CONFIG_LOCALVERSION="\(.*\)"/\1/')
RELEASE_VERSION="${RELEASE_VERSION#-}" # Remove leading hyphen if present
IFS=- read -r KERNEL_VARIANT KERNEL_CODENAME RELEASE_VERSION <<< "$RELEASE_VERSION" || true # Split version string
log "INFO" "ℹ️ Kernel Variant: $KERNEL_VARIANT"
log "INFO" "ℹ️ Kernel Codename: $KERNEL_CODENAME"
log "INFO" "ℹ️ Release Version: $RELEASE_VERSION"

# --- Kernel Compilation ---

# --- Create output directory ---
mkdir -p out
log "INFO" "📁 Output directory created at: out/"

# --- Make defconfig ---
log "INFO" "⚙️ Generating defconfig..."
make O=out $DEFCONFIG

# --- Clean output directory if requested ---
# Allows for cleaning the output directory using -c or --clean argument
if [[ "$1" == "-c" || "$1" == "--clean" ]]; then
  log "INFO" "🗑️ Cleaning output directory..."
  rm -rf out
  log "INFO" "✅ Output directory cleaned."
  exit 0
fi

# --- Regenerate defconfig if requested ---
# Allows for regenerating and saving the defconfig using -r or --regen argument
if [[ "$1" == "-r" || "$1" == "--regen" ]]; then
  log "INFO" "🔄 Regenerating defconfig..."
  make O=out ARCH=arm64 $DEFCONFIG savedefconfig
  cp out/defconfig arch/arm64/configs/$DEFCONFIG
  log "INFO" "✅ Defconfig regenerated."
  exit 0
fi

# --- Start kernel compilation ---
log "INFO" "🔥 Starting kernel compilation..."
# The output of the compilation is piped to tee to both display it and write it to build.log
make -j$(nproc --all) O=out ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1 LD=ld.lld CROSS_COMPILE=aarch64-linux-gnu- 2>&1 | tee -a "$LOG_FILE"

# --- Check for compilation errors ---
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
  handle_error "$LINENO" "Compilation failed"
  tg_doc "$LOG_FILE" "❌ Build failed after $((SECONDS / 60)) minutes $((SECONDS % 60)) seconds"
  exit 1
fi
fi

# --- Get Clang and LLD versions ---
CLANG_VERSION=$($HOME/Zyc-Clang/bin/clang --version 2>&1 | head -n 1)
LLD_VERSION=$($HOME/Zyc-Clang/bin/ld.lld --version 2>&1 | head -n 1)
log "INFO" "ℹ️ Using Clang: $CLANG_VERSION"
log "INFO" "ℹ️ Using LLD: $LLD_VERSION"

# --- AnyKernel3 Setup ---

# --- Clone AnyKernel3 ---
log "INFO" "⬇️ Cloning AnyKernel3..."
if ! git clone -q https://github.com/AzyrRuthless/AnyKernel3 "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"; then
  handle_error "$LINENO" "Failed to clone AnyKernel3"
fi

# --- Copy files to AnyKernel3 ---
log "INFO" "➡️ Copying Image.gz..."
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"
log "INFO" "➡️ Copying dtbo.img..."
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"
log "INFO" "📁 Creating dtb directory in AnyKernel3..."
mkdir -p "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel/dtb"
log "INFO" "➡️ Copying cust-atoll-ab.dtb..."
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel/dtb"

# --- Create ZIP archive ---
ZIP_NAME="${PROJECT_NAME}-${KERNEL_VARIANT}-${KERNEL_CODENAME}-${RELEASE_VERSION}-${DEVICE_CODENAME}-$(date '+%d%m%Y').zip"
log "INFO" "🗜️ Creating ZIP archive: $ZIP_NAME"
cd "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel" || handle_error "$LINENO" "Failed to enter AnyKernel3 directory"
zip -r9 "../$ZIP_NAME" ./* -x '*.git*' README.md ./*placeholder
cd "$GITHUB_WORKSPACE/Kinesis_Kernel" || handle_error "$LINENO" "Failed to return to kernel directory"

# --- Build Completion ---

# --- Build completion notification ---
BUILD_DURATION_MINUTES=$((SECONDS / 60))
BUILD_DURATION_SECONDS=$((SECONDS % 60))
log "INFO" "🎉 Build completed in ${BUILD_DURATION_MINUTES} minutes ${BUILD_DURATION_SECONDS} seconds!"
log "INFO" "📦 ZIP archive: $ZIP_NAME"

tg "✅ Kernel compilation completed\! 🎉 File: \`$ZIP_NAME\`"
tg_doc "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "✅ Build finished after ${BUILD_DURATION_MINUTES} minutes ${BUILD_DURATION_SECONDS} seconds"

# --- Upload artifacts ---
ARTIFACT_DIR="$GITHUB_WORKSPACE/kernel_artifacts"
log "INFO" "⬆️ Uploading artifacts to: $ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "$ARTIFACT_DIR/"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "$ARTIFACT_DIR/"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb" "$ARTIFACT_DIR/"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "$ARTIFACT_DIR/"

# --- Debugging output (Optional) ---
# These lines list the contents of specific directories for debugging purposes.
log "DEBUG" "🔍 Contents of $GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot:"
ls -la "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/"
log "DEBUG" "🔍 Contents of $GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom:"
ls -la "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/"
log "DEBUG" "🔍 Contents of $ARTIFACT_DIR:"
ls -la "$ARTIFACT_DIR"

# --- Set 'artifact_dir' output variable for GitHub Actions ---
echo "artifact_dir=$ARTIFACT_DIR" >> $GITHUB_OUTPUT

# --- End of Script ---
