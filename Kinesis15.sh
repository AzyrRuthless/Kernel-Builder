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
  # local formatted_caption=$(printf '%q' "$caption") # Simplified caption for testing
  local retries=3
  local success=false

  while [[ $retries -gt 0 && $success == false ]]; do
    # Send a document to Telegram with a simplified caption and verbose output for debugging
    curl -v -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" \
      -F chat_id="$TELEGRAM_CHAT_ID" \
      -F document="@$file" \
      -F caption="$caption" &> "curl_log_$retries.txt" # Verbose output to a log file

    if [[ $? -eq 0 ]]; then
      success=true
      echo "Successfully sent the document after $((3 - retries)) retries."
    else
      retries=$((retries - 1))
      echo "Failed to send the document. Retries left: $retries"
      sleep 5 # Wait for 5 seconds before retrying
    fi
  done

  if [[ $success == false ]]; then
    tg "❌ Failed to send ZIP file after multiple retries."
    # cat curl_log.txt # Output the log file content to the console if needed
    exit 1
  fi
}

# Start notification
tg "Starting build!"

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

# Download and Extract Zyc Clang
if [ ! -d "$HOME/Zyc-Clang" ]; then
    # Get the latest release URL from GitHub API
    LATEST_RELEASE_URL=$(curl -s https://api.github.com/repos/ZyCromerZ/Clang/releases/latest | grep "browser_download_url.*tar.gz" | cut -d : -f 2,3 | tr -d \" | tr -d '[:space:]')

    # Download the latest release
    wget "$LATEST_RELEASE_URL" -O "$HOME/Zyc-Clang.tar.gz"

    # Extract Zyc-Clang
    mkdir -p "$HOME/Zyc-Clang"
    tar -xf "$HOME/Zyc-Clang.tar.gz" -C "$HOME/Zyc-Clang"

    # Clean up the tar.gz file
    rm "$HOME/Zyc-Clang.tar.gz"
fi

# Set defconfig
DEFCONFIG="vendor/xiaomi/miatoll_defconfig"

# Set environment variables
# The prebuilt clang binaries are inside the extracted Zyc-Clang folder
export PATH="$HOME/Zyc-Clang/bin:$PATH"
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

# Start kernel compilation and pipe output to build.log
make -j$(nproc --all) O=out ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1 LD=ld.lld CROSS_COMPILE=aarch64-linux-gnu- | tee build.log

# Check if compilation was successful
if [[ $? -ne 0 ]]; then
  tg "❌ Compilation failed!"
  tg_doc "build.log" "❌ Build failed after $((SECONDS / 60)) minutes $((SECONDS % 60)) seconds"
  exit 1
fi

# Get clang and lld version
CLANG_VERSION=$("$HOME/Zyc-Clang/bin/clang" --version 2>&1 | head -n 1)
LLD_VERSION=$("$HOME/Zyc-Clang/bin/ld.lld" --version 2>&1 | head -n 1)

# Modify kernel version
export KERNEL_VERSION=$(make kernelversion)
sed -i "s/${KERNEL_VERSION}/${KERNEL_VERSION} #1 ${KBUILD_BUILD_TIMESTAMP}/" out/Makefile
sed -i "s/${KERNEL_VERSION}/#1 ${KBUILD_BUILD_TIMESTAMP}/g" out/include/config/kernel.release
sed -i "s/${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST}/${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST} (${CLANG_VERSION}), (${LLD_VERSION})/" out/include/linux/version.h

# Clone AnyKernel3
if ! git clone -q https://github.com/AzyrRuthless/AnyKernel3 "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"; then
  tg "❌ Failed to clone AnyKernel3!"
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

# Use variables for Clang and LLD versions in Telegram messages
tg "✅ Kernel compilation completed! 🎉 File: $ZIP_NAME"
# Simplified caption for testing:
tg_doc "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "✅ Build finished: $ZIP_NAME"

# Create Artifact Directory
mkdir -p "$ARTIFACT_DIR"

# Copy artifacts
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "$ARTIFACT_DIR/"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "$ARTIFACT_DIR/"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb" "$ARTIFACT_DIR/"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "$ARTIFACT_DIR/"

# Debugging: List contents of source and destination directories
echo "Contents of $GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot:"
ls -la "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/"
echo "Contents of $GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom:"
ls -la "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/"
echo "Contents of $ARTIFACT_DIR:"
ls -la "$ARTIFACT_DIR"
