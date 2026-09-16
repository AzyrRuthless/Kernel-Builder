#!/bin/bash
set -e

# --- Function to send Telegram notifications ---
tg() {
  local msg="$1"
  local formatted_date=$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S')
  echo "➡️ Sending Telegram message: $msg (at $formatted_date WIB)"
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" -d chat_id="$TELEGRAM_CHAT_ID" -d text="$msg - \`$formatted_date\`" > /dev/null
}

# --- Function to send Telegram documents with error handling ---
tg_doc() {
  local file="$1"
  local caption="$2"
  local formatted_caption=$(printf '%q' "$caption")
  echo "➡️ Sending Telegram document: $file"
  if ! curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" -F chat_id="$TELEGRAM_CHAT_ID" -F document="@$file" -F parse_mode="MarkdownV2" -F caption="${formatted_caption}"; then
    echo "❌ Failed to send Telegram document: $file"
    tg "❌ Failed to send Telegram document: $file"
  fi
}

# --- Function to handle errors with line number ---
handle_error() {
  local error_message="$1"
  local line_number="$2"
  echo "❌ An error occurred at line $line_number: $error_message"
  tg "❌ An error occurred at line \`$line_number\`: \`$error_message\`"
  exit 1
}

# --- Trap errors and call handle_error ---
trap 'handle_error "$BASH_COMMAND" $LINENO' ERR

# --- Start the build process ---
echo "🚀 Starting build at $(date)"
tg "🚀 Build started\!"

# --- Clean up previous kernel directory ---
[ -d "$GITHUB_WORKSPACE/Kinesis_Kernel" ] && rm -rf "$GITHUB_WORKSPACE/Kinesis_Kernel"

# --- Clone the kernel source ---
echo "⬇️ Cloning kernel source from: $KERNEL_SOURCE (branch: $KERNEL_BRANCH)..."
git clone "$KERNEL_SOURCE" -b "$KERNEL_BRANCH" "$GITHUB_WORKSPACE/Kinesis_Kernel" --depth=1 || handle_error "Failed to clone kernel source"
cd "$GITHUB_WORKSPACE/Kinesis_Kernel"

curl -LSs "https://raw.githubusercontent.com/AzyrRuthless/KernelSU/main/kernel/setup.sh" | bash -s main

# --- Setup ccache ---
echo "🧰 Setting up ccache..."
export CCACHE_DIR=/tmp/ccache
export CCACHE_EXEC=$(which ccache)
export USE_CCACHE=1
ccache -M 10G
ccache -o compression=true
ccache -z

# --- Download and setup AzyrRuthless LLVM ---
echo "⬇️ Downloading and setting up AzyrRuthless LLVM..."
LLVM_DIR="$HOME/AzyrRuthless-LLVM"
if [ ! -d "$LLVM_DIR" ]; then
  git clone https://gitlab.com/AzyrRuthless/llvm-compiler-toolchain "$LLVM_DIR"
else
  cd "$LLVM_DIR"
  git pull
  cd "$GITHUB_WORKSPACE/Kinesis_Kernel"
fi

# --- Set environment variables ---
echo "🔧 Setting environment variables..."
export PATH="$LLVM_DIR/bin:$PATH"
export ARCH=arm64
export KBUILD_BUILD_USER=Audemars
export KBUILD_BUILD_HOST=ROG-G834JYR
export TZ=Asia/Jakarta
export KBUILD_BUILD_TIMESTAMP=$(date '+%a %b %d %H:%M:%S %Z %Y')
export PROJECT_NAME="KSU"
export DEVICE_CODENAME="miatoll"

# --- Set defconfig ---
DEFCONFIG="vendor/xiaomi/miatoll_defconfig"
echo "⚙️ Using defconfig: $DEFCONFIG"

# --- Get release version from defconfig ---
RELEASE_VERSION=$(grep "CONFIG_LOCALVERSION=" arch/arm64/configs/$DEFCONFIG | sed 's/CONFIG_LOCALVERSION="\(.*\)"/\1/')
RELEASE_VERSION="${RELEASE_VERSION#-}"
IFS=- read -r KERNEL_VARIANT KERNEL_CODENAME RELEASE_VERSION <<< "$RELEASE_VERSION" || true
echo "ℹ️ Kernel Variant: $KERNEL_VARIANT"
echo "ℹ️ Kernel Codename: $KERNEL_CODENAME"
echo "ℹ️ Release Version: $RELEASE_VERSION"

# --- Create output directory ---
mkdir -p out

# --- Make defconfig ---
echo "⚙️ Generating defconfig..."
make O=out $DEFCONFIG

# --- Clean output directory if requested ---
if [[ "$1" == "-c" || "$1" == "--clean" ]]; then
  echo "🗑️ Cleaning output directory..."
  rm -rf out
  exit 0
fi

# --- Start kernel compilation (using Clang/LLVM as primary) ---
echo "🔥 Starting kernel compilation (using Clang with LLD)..."
make -j$(nproc --all) O=out ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
  CC="ccache clang" \
  LD=ld.lld \
  AR=llvm-ar \
  NM=llvm-nm \
  STRIP=llvm-strip \
  OBJCOPY=llvm-objcopy \
  OBJDUMP=llvm-objdump \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  2>&1 | tee build.log

# --- Check for compilation errors ---
if [[ $? -ne 0 ]]; then
  handle_error "Compilation failed"
  tg_doc "build.log" "❌ Build failed after $((SECONDS / 60)) minutes $((SECONDS % 60)) seconds"
  exit 1
fi

# --- Get GCC and Clang versions ---
GCC_VERSION_ARM64=$(aarch64-linux-gnu-gcc --version | head -n 1)
GCC_VERSION_ARM32=$(arm-linux-gnueabi-gcc --version | head -n 1)
CLANG_VERSION=$(clang --version | head -n 1)
LLD_VERSION=$(ld.lld --version | head -n 1)
echo "ℹ️ Using aarch64-linux-gnu-gcc: $GCC_VERSION_ARM64"
echo "ℹ️ Using arm-linux-gnueabi-gcc: $GCC_VERSION_ARM32"
echo "ℹ️ Using clang: $CLANG_VERSION"
echo "ℹ️ Using ld.lld: $LLD_VERSION"

# --- Clone AnyKernel3 ---
echo "⬇️ Cloning AnyKernel3..."
AK3_DIR="$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"
git clone -q -b Ivory https://github.com/AzyrRuthless/AnyKernel3 "$AK3_DIR" || handle_error "Failed to clone AnyKernel3"

# --- Copy files to AnyKernel3 ---
echo "➡️ Copying required files to AnyKernel3..."
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "$AK3_DIR"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "$AK3_DIR"
mkdir -p "$AK3_DIR/dtb"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb" "$AK3_DIR/dtb"

# --- Create ZIP archive ---
ZIP_NAME="${PROJECT_NAME}-${KERNEL_VARIANT}-${KERNEL_CODENAME}-${RELEASE_VERSION}-${DEVICE_CODENAME}-$(date '+%d%m%Y').zip"
echo "🗜️ Creating ZIP archive: $ZIP_NAME"
cd "$AK3_DIR"
zip -r9 "../$ZIP_NAME" ./* -x '*.git*' README.md ./*placeholder
cd "$GITHUB_WORKSPACE/Kinesis_Kernel"

# --- Build completion notification ---
BUILD_DURATION_MINUTES=$((SECONDS / 60))
BUILD_DURATION_SECONDS=$((SECONDS % 60))
echo -e "\n🎉 Build completed in ${BUILD_DURATION_MINUTES} minutes ${BUILD_DURATION_SECONDS} seconds!"
echo "📦 ZIP archive: $ZIP_NAME"

tg "✅ Kernel compilation completed\! 🎉 File: \`$ZIP_NAME\`"
tg_doc "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "✅ Build finished after ${BUILD_DURATION_MINUTES} minutes ${BUILD_DURATION_SECONDS} seconds"

# --- Upload artifacts ---
ARTIFACT_DIR="$GITHUB_WORKSPACE/kernel_artifacts"
echo "⬆️ Uploading artifacts to: $ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "$ARTIFACT_DIR/"
find "$AK3_DIR" -maxdepth 1 -type f -print0 | xargs -0 -I {} cp {} "$ARTIFACT_DIR/"
cp "build.log" "$ARTIFACT_DIR/"

# --- Debugging output ---
echo "🔍 Contents of $GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot:"
ls -la "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/"
echo "🔍 Contents of $GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom:"
ls -la "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/"
echo "🔍 Contents of $ARTIFACT_DIR:"
ls -la "$ARTIFACT_DIR"

# --- Set 'artifact_dir' output variable ---
echo "artifact_dir=$ARTIFACT_DIR" >> $GITHUB_OUTPUT
