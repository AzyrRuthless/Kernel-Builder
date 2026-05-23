#!/bin/bash

# Telegram notification functions
tg() {
  local msg="$1"
  # Send a message to Telegram
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" -d chat_id="$TELEGRAM_CHAT_ID" -d text="$msg" > /dev/null
}

tg_doc() {
  local file="$1"
  local caption="$2"
  local formatted_caption=$(printf '%q' "$caption")
  # Send a document to Telegram with MarkdownV2 formatting for the caption
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" -F chat_id="$TELEGRAM_CHAT_ID" -F document="@$file" -F parse_mode="MarkdownV2" -F caption="${formatted_caption}" > /dev/null
}

# Start notification
tg "Starting build (Personal Fork, Zenith)!"

# Clean previous kernel directory if it exists
if [ -d "$GITHUB_WORKSPACE/Kinesis_Kernel" ]; then
  rm -rf "$GITHUB_WORKSPACE/Kinesis_Kernel"
fi

# Clone kernel source
if ! git clone "$KERNEL_SOURCE" -b "$KERNEL_BRANCH" "$GITHUB_WORKSPACE/Kinesis_Kernel" --depth=1; then
  tg "❌ Failed to clone kernel source!"
  exit 1
fi
cd "$GITHUB_WORKSPACE/Kinesis_Kernel" || exit 1

# Setup ccache
export CCACHE_DIR=/tmp/ccache
export CCACHE_EXEC=$(which ccache)
export USE_CCACHE=1
ccache -M 10G
ccache -o compression=true
ccache -z

# Clone PixelOS Clang (Prebuilt)
if [ ! -d "$HOME/PixelOS-Clang" ]; then
    if ! git clone https://gitlab.com/PixelOS-Devices/playgroundtc.git --depth=1 --branch 17 "$HOME/PixelOS-Clang"; then
      tg "❌ Failed to clone PixelOS Clang!"
      exit 1
    fi
fi

# Set defconfig
DEFCONFIG="vendor/xiaomi/miatoll_defconfig"

# Set environment variables
# The prebuilt clang binaries are inside 'bin'
export PATH="$HOME/PixelOS-Clang/bin:$PATH"
export ARCH=arm64
export KBUILD_BUILD_USER=AzyrRuthless
export KBUILD_BUILD_HOST=$(hostname)
export TZ=Asia/Jakarta
export KBUILD_BUILD_TIMESTAMP=$(date '+%a %b %d %H:%M:%S %Z %Y')

export PROJECT_NAME="KSU"
export DEVICE_CODENAME="miatoll"

# Get release version from defconfig
DEFCONFIG_CONTENT=$(cat arch/arm64/configs/$DEFCONFIG)
RELEASE_VERSION=$(echo "$DEFCONFIG_CONTENT" | grep "CONFIG_LOCALVERSION=" | sed 's/CONFIG_LOCALVERSION="\(.*\)"/\1/')

# Split the release version and remove leading dash
RELEASE_VERSION="${RELEASE_VERSION#-}"
IFS=- read -r KERNEL_VARIANT KERNEL_CODENAME RELEASE_VERSION <<< "$RELEASE_VERSION" || true

# Create output directory
mkdir -p out

# Make defconfig
make O=out $DEFCONFIG

# Clean output directory if requested (e.g., with -c or --clean flag)
if [[ "$1" == "-c" || "$1" == "--clean" ]]; then
  rm -rf out
  echo "✅ Output directory cleaned."
  exit 0
fi

# Regenerate defconfig if requested (e.g., with -r or --regen flag)
if [[ "$1" == "-r" || "$1" == "--regen" ]]; then
  make O=out ARCH=arm64 $DEFCONFIG savedefconfig
  cp out/defconfig arch/arm64/configs/$DEFCONFIG
  echo "✅ Defconfig regenerated."
  exit 0
fi

# Start kernel compilation and pipe output to build.log
make -j$(nproc --all) O=out ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1 LD=ld.lld CROSS_COMPILE=aarch64-linux-gnu- | tee build.log

# Check if compilation was successful
if [[ $? -ne 0 ]]; then
  tg "❌ Compilation failed!"
  tg_doc "build.log" "❌ Build failed after $((SECONDS / 60)) minutes $((SECONDS % 60)) seconds"
  exit 1
fi

# Get clang and lld version
CLANG_VERSION=$(clang --version | head -n 1)
LLD_VERSION=$(ld.lld --version | head -n 1)

# Modify kernel version
export KERNEL_VERSION=$(make kernelversion)
sed -i "s/${KERNEL_VERSION}/${KERNEL_VERSION} #1 ${KBUILD_BUILD_TIMESTAMP}/" out/Makefile
sed -i "s/${KERNEL_VERSION}/#1 ${KBUILD_BUILD_TIMESTAMP}/g" out/include/config/kernel.release
sed -i "s/${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST}/${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST} (${CLANG_VERSION}), (${LLD_VERSION})/" out/include/linux/version.h

# Clone AnyKernel3 (Personal-Fork Branch)
if ! git clone -q -b Personal-Fork https://github.com/AzyrRuthless/AnyKernel3 "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"; then
  tg "❌ Failed to clone AnyKernel3 (Personal Fork, Zenith)!"
  exit 1
fi

# Copy necessary files to AnyKernel3
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel/dtb"

# Create ZIP archive
ZIP_NAME="${PROJECT_NAME}-${KERNEL_VARIANT}-${KERNEL_CODENAME}-${RELEASE_VERSION}-${KERNEL_VERSION}-${DEVICE_CODENAME}-$(date '+%d%m%Y').zip"
cd "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel" || exit 1
zip -r9 "../$ZIP_NAME" ./* -x '*.git*' README.md ./*placeholder
cd "$GITHUB_WORKSPACE/Kinesis_Kernel" || exit 1

# Build completion notification
echo -e "\n🎉 Completed in $((SECONDS / 60)) minutes $((SECONDS % 60)) seconds!"
echo "🗜️ Zip: $ZIP_NAME"

tg "✅ Kernel compilation completed! 🎉 File: $ZIP_NAME (Personal Fork, Zenith)"
tg_doc "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "✅ Build finished after $((SECONDS / 60)) minutes $((SECONDS % 60)) seconds (Personal Fork, Zenith)"

# Upload artifacts
ARTIFACT_DIR="$GITHUB_WORKSPACE/kernel_artifacts" # Use absolute path
mkdir -p "$ARTIFACT_DIR"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "$ARTIFACT_DIR/"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "$ARTIFACT_DIR/"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb" "$ARTIFACT_DIR/"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "$ARTIFACT_DIR/"

# Debugging: List contents of source and destination directories (using absolute paths)
echo "Contents of $GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot:"
ls -la "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/"
echo "Contents of $GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom:"
ls -la "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/"
echo "Contents of $ARTIFACT_DIR:"
ls -la "$ARTIFACT_DIR"

# Set the 'artifact_dir' output variable for subsequent steps to use.
echo "artifact_dir=$ARTIFACT_DIR" >> $GITHUB_OUTPUT