#!/bin/bash

# Telegram notification functions
tg() {
  local msg="$1"
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" -d chat_id="$TELEGRAM_CHAT_ID" -d text="$msg" > /dev/null
}

tg_doc() {
  local file="$1"
  local caption="$2"
  local formatted_caption=$(printf '%q' "$caption")
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" -F chat_id="$TELEGRAM_CHAT_ID" -F document="@$file" -F parse_mode="MarkdownV2" -F caption="${formatted_caption}" > /dev/null
}

# Start notification
tg "Starting build!"

# Clean up previous kernel directory if it exists
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

# Clone crDroid Clang Toolchain
if [ ! -d "$HOME/crdroid-clang" ]; then
    if ! git clone https://gitlab.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-r536225.git --depth=1 --single-branch -b 15.0 "$HOME/crdroid-clang"; then
      tg "❌ Failed to clone crDroid Clang Toolchain!"
      exit 1
    fi
fi

# Set defconfig
DEFCONFIG="vendor/xiaomi/miatoll_defconfig"

# Set environment variables
# Prioritize crDroid Clang in PATH
export PATH="$HOME/crdroid-clang/bin:$PATH"
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

# Split release version
RELEASE_VERSION="${RELEASE_VERSION#-}"
IFS=- read -r KERNEL_VARIANT KERNEL_CODENAME RELEASE_VERSION <<< "$RELEASE_VERSION" || true

# Create output directory
mkdir -p out

# Make defconfig
make O=out $DEFCONFIG

# Optional: Clean output directory
if [[ "$1" == "-c" || "$1" == "--clean" ]]; then
  rm -rf out
  echo "✅ Output directory cleaned."
  exit 0
fi

# Optional: Regenerate defconfig
if [[ "$1" == "-r" || "$1" == "--regen" ]]; then
  make O=out ARCH=arm64 $DEFCONFIG savedefconfig
  cp out/defconfig arch/arm64/configs/$DEFCONFIG
  echo "✅ Defconfig regenerated."
  exit 0
fi

# --- Verification and Debugging Information ---
echo "=============================================="
echo "Environment Variables and Toolchain Verification"
echo "=============================================="
echo "PATH: $PATH"
echo "------------------------"
echo "which clang: $(which clang)"
echo "clang --version:"
clang --version
echo "------------------------"
echo "which llvm-ar: $(which llvm-ar)"
echo "llvm-ar --version:"
llvm-ar --version
echo "------------------------"
echo "which aarch64-linux-gnu-gcc: $(which aarch64-linux-gnu-gcc)"
echo "aarch64-linux-gnu-gcc --version:"
aarch64-linux-gnu-gcc --version
echo "------------------------"
echo "which arm-linux-gnueabi-gcc: $(which arm-linux-gnueabi-gcc)"
echo "arm-linux-gnueabi-gcc --version:"
arm-linux-gnueabi-gcc --version
echo "------------------------"
echo "which ld.lld: $(which ld.lld)"
echo "ld.lld version in crDroid Clang toolchain:"
if [ -f "$HOME/crdroid-clang/bin/ld.lld" ]; then
  "$HOME/crdroid-clang/bin/ld.lld" --version
else
  echo "ld.lld not found in crDroid Clang toolchain."
fi
echo "=============================================="
# --- End Verification ---

# Explicitly set LD to the toolchain's ld.lld
export LD=ld.lld

# Start kernel compilation with mixed GCC and Clang
make -j$(nproc --all) O=out ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
  CC="ccache clang" \
  LD=ld.lld \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  | tee build.log

# Capture the exit code from the make command
build_exit_code=$?

# Create the artifact directory
ARTIFACT_DIR="$GITHUB_WORKSPACE/kernel_artifacts"
mkdir -p "$ARTIFACT_DIR"

# Copy build.log to the artifact directory (always do this)
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/build.log" "$ARTIFACT_DIR/"

# Check compilation success
if [[ $build_exit_code -ne 0 ]]; then
  tg "❌ Compilation failed!"
  tg_doc "$ARTIFACT_DIR/build.log" "❌ Build failed after $((SECONDS / 60)) minutes $((SECONDS % 60)) seconds"
  # Continue to upload other artifacts if needed, or exit
  # exit 1  # Remove or comment out this line if you still want to upload artifacts on failure
fi

# Get clang and lld version (only if compilation succeeded)
if [[ $build_exit_code -eq 0 ]]; then
    CLANG_VERSION=$(clang --version | head -n 1)
    LLD_VERSION=$(ld.lld --version | head -n 1)
    # Get GCC version
    GCC_VERSION=$(aarch64-linux-gnu-gcc --version | head -n 1)

    # Modify kernel version
    export KERNEL_VERSION=$(make kernelversion)
    sed -i "s/${KERNEL_VERSION}/${KERNEL_VERSION} #1 ${KBUILD_BUILD_TIMESTAMP}/" out/Makefile
    sed -i "s/${KERNEL_VERSION}/#1 ${KBUILD_BUILD_TIMESTAMP}/g" out/include/config/kernel.release
    sed -i "s/${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST}/${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST} (${CLANG_VERSION}), (${GCC_VERSION}), (${LLD_VERSION})/" out/include/linux/version.h
    
    # Clone AnyKernel3
    if ! git clone -q https://github.com/AzyrRuthless/AnyKernel3 "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"; then
      tg "❌ Failed to clone AnyKernel3!"
      exit 1
    fi
    
    # Copy files to AnyKernel3
    cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"
    cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"
    cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel/dtb"
    
    # Create ZIP archive
    ZIP_NAME="${PROJECT_NAME}-${KERNEL_VARIANT}-${KERNEL_CODENAME}-${RELEASE_VERSION}-${KERNEL_VERSION}-${DEVICE_CODENAME}-$(date '+%d%m%Y').zip"
    cd "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel" || exit 1
    zip -r9 "../$ZIP_NAME" ./* -x '*.git*' README.md ./*placeholder
    cd "$GITHUB_WORKSPACE/Kinesis_Kernel" || exit 1
    
    # Copy other needed files to artifact directory
    cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "$ARTIFACT_DIR/"
    cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "$ARTIFACT_DIR/"
    cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb" "$ARTIFACT_DIR/"
    cp "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "$ARTIFACT_DIR/"
fi

# Debugging: List contents of directories
echo "Contents of $GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot:"
ls -la "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/"
echo "Contents of $GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom:"
ls -la "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/"
echo "Contents of $ARTIFACT_DIR:"
ls -la "$ARTIFACT_DIR"

# Set output variable for subsequent steps (only if compilation succeeded)
if [[ $build_exit_code -eq 0 ]]; then
  echo "artifact_dir=$ARTIFACT_DIR" >> $GITHUB_OUTPUT

  # Build completion notification
  echo -e "\n🎉 Completed in $((SECONDS / 60)) minutes $((SECONDS % 60)) seconds!"
  echo "🗜️ Zip: $ZIP_NAME"

  tg "✅ Kernel compilation completed! 🎉 File: $ZIP_NAME"
  tg_doc "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "✅ Build finished after $((SECONDS / 60)) minutes $((SECONDS % 60)) seconds"
fi