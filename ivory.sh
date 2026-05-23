#!/bin/bash
set -e

# --- Helper Functions (From sh 2) ---
log() {
  local msg="$1"
  local formatted_date=$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S')
  echo "[$formatted_date] $msg"
}

# --- Function to send Telegram notifications (From sh 2) ---
tg() {
  local msg="$1"
  local formatted_date=$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S')
  log "➡️ Sending Telegram message: $msg (at $formatted_date WIB)"
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d text="$msg - \`$formatted_date\`" > /dev/null
}

# --- Function to send Telegram documents with error handling (From sh 2) ---
tg_doc() {
  local file="$1"
  local caption="$2"
  local formatted_caption=$(printf '%q' "$caption")  # Use printf '%q'
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

# --- Function to handle errors with logging (From sh 2) ---
handle_error() {
  local error_message="$1"
  log "❌ An error occurred: $error_message"
  tg "❌ An error occurred: \`$error_message\`"
  exit 1
}

# --- Telegram specific command ---
tg_start() {
    tg "🚀 Build started\!"
}

# --- Handle arguments for Telegram functionality (before other operations) ---
if [[ "$1" == "tg_start" ]]; then
  tg_start
  exit 0
fi

# --- Kernel Source and Branch Configuration ---
case "$KERNEL_BRANCH" in
  Ivory)
    KERNEL_SOURCE="https://gitlab.com/AzyrRuthless/kernel_xiaomi_sm6250_backup"
    ;;
  Ivory2)
    KERNEL_SOURCE="https://gitlab.com/AzyrRuthless/kernel_xiaomi_sm6250_backup"
    ;;
  *)
    handle_error "Invalid KERNEL_BRANCH: $KERNEL_BRANCH"
    ;;
esac

ANYKERNEL_BRANCH="Ivory"

# --- Clean up previous kernel directory ---
if [ -d "$GITHUB_WORKSPACE/Kinesis_Kernel" ]; then
  rm -rf "$GITHUB_WORKSPACE/Kinesis_Kernel"
fi

# --- Clone the kernel source ---
if ! git clone "$KERNEL_SOURCE" -b "$KERNEL_BRANCH" "$GITHUB_WORKSPACE/Kinesis_Kernel" --depth=1; then
  handle_error "Failed to clone kernel source"
fi
cd "$GITHUB_WORKSPACE/Kinesis_Kernel" || handle_error "Failed to enter kernel directory"

# --- Integrate KernelSU-Next (Ivory only) ---
if [ "$KERNEL_BRANCH" = "Ivory" ]; then
  KERNELSU_DIR="$GITHUB_WORKSPACE/Kinesis_Kernel/kernel/KernelSU-Next"
  if [ ! -d "$KERNELSU_DIR" ]; then
    git clone -b next https://github.com/AzyrRuthless/KernelSU-Next.git "$KERNELSU_DIR"
  fi
  cd "$KERNELSU_DIR"
  git stash
  git checkout next
  git pull
  cd "$GITHUB_WORKSPACE/Kinesis_Kernel"

  if [ -d "$GITHUB_WORKSPACE/Kinesis_Kernel/common/drivers" ]; then
    DRIVER_DIR="$GITHUB_WORKSPACE/Kinesis_Kernel/common/drivers"
  elif [ -d "$GITHUB_WORKSPACE/Kinesis_Kernel/drivers" ]; then
    DRIVER_DIR="$GITHUB_WORKSPACE/Kinesis_Kernel/drivers"
  else
    handle_error '"drivers/" directory not found'
  fi

  ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$KERNELSU_DIR/kernel")" "$DRIVER_DIR/kernelsu"

  DRIVER_MAKEFILE="$DRIVER_DIR/Makefile"
  DRIVER_KCONFIG="$DRIVER_DIR/Kconfig"

  if ! grep -q "kernelsu" "$DRIVER_MAKEFILE"; then
    printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_MAKEFILE"
  fi

  if ! grep -q "source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG"; then
    sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG"
  fi
fi

# --- COMPLETELY DISABLE CCACHE ---

# --- Download and Extract Zyc-Clang ---
if [ ! -d "$HOME/Zyc-Clang" ]; then
  LATEST_RELEASE_URL=$(curl -s "https://api.github.com/repos/ZyCromerZ/Clang/releases/latest" | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url')
  if [ -z "$LATEST_RELEASE_URL" ]; then
    handle_error "Failed to retrieve the latest release URL for Zyc-Clang"
  fi
  wget "$LATEST_RELEASE_URL" -O "$HOME/Zyc-Clang.tar.gz"
  mkdir -p "$HOME/Zyc-Clang"
  tar -xf "$HOME/Zyc-Clang.tar.gz" -C "$HOME/Zyc-Clang"
  rm "$HOME/Zyc-Clang.tar.gz"
fi

# --- Set environment variables ---
export PATH="$HOME/Zyc-Clang/bin:$PATH"
export ARCH=arm64
export KBUILD_BUILD_USER=Audemars
export KBUILD_BUILD_HOST=ROG-G834JYR
export TZ=Asia/Jakarta
export KBUILD_BUILD_TIMESTAMP=$(date '+%a %b %d %H:%M:%S %Z %Y')
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export STRIP=llvm-strip
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export PROJECT_NAME="KSU"
export DEVICE_CODENAME="miatoll"
DEFCONFIG="vendor/xiaomi/miatoll_defconfig"
DEFCONFIG_CONTENT=$(cat arch/arm64/configs/$DEFCONFIG)
RELEASE_VERSION=$(echo "$DEFCONFIG_CONTENT" | grep "CONFIG_LOCALVERSION=" | sed 's/CONFIG_LOCALVERSION="\(.*\)"/\1/')
RELEASE_VERSION="${RELEASE_VERSION#-}"
IFS=- read -r KERNEL_VARIANT KERNEL_CODENAME RELEASE_VERSION <<< "$RELEASE_VERSION" || true
mkdir -p out
make O=out $DEFCONFIG

# --- Optional: clean and regen targets ---
if [[ "$1" == "-c" || "$1" == "--clean" ]]; then
  rm -rf out
  exit 0
fi

if [[ "$1" == "-r" || "$1" == "--regen" ]]; then
  make O=out ARCH=arm64 $DEFCONFIG savedefconfig
  cp out/defconfig arch/arm64/configs/$DEFCONFIG
  exit 0
fi

# --- Start kernel compilation ---
make -j$(nproc --all) O=out ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1 LD=ld.lld CROSS_COMPILE=aarch64-linux-gnu- 2>&1 | tee build.log

# --- Check for compilation errors ---
if [[ $? -ne 0 ]]; then
  handle_error "Compilation failed"
  tg_doc "build.log" "Build failed"  # Send build log on failure
  exit 1  # Exit after sending the error message
fi

# --- Get Clang and LLD versions (for logging/debugging) ---
CLANG_VERSION=$($HOME/Zyc-Clang/bin/clang --version 2>&1 | head -n 1)
LLD_VERSION=$($HOME/Zyc-Clang/bin/ld.lld --version 2>&1 | head -n 1)

# --- Clone AnyKernel3 (using the hardcoded branch) ---
if ! git clone -q https://github.com/AzyrRuthless/AnyKernel3 -b "$ANYKERNEL_BRANCH" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"; then
  handle_error "Failed to clone AnyKernel3"
fi

# --- Copy build artifacts to AnyKernel3 directory ---
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/Image.gz" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dtbo.img" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel"
mkdir -p "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel/dtb"
cp "$GITHUB_WORKSPACE/Kinesis_Kernel/out/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb" "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel/dtb"

# --- Create ZIP archive ---
ZIP_NAME="${PROJECT_NAME}-${KERNEL_VARIANT}-${KERNEL_CODENAME}-${RELEASE_VERSION}-${DEVICE_CODENAME}-${KERNEL_BRANCH}-$(date '+%d%m%Y').zip"
cd "$GITHUB_WORKSPACE/Kinesis_Kernel/anykernel" || handle_error "Failed to enter AnyKernel3 directory"
zip -r9 "../$ZIP_NAME" ./* -x '*.git*' README.md ./*placeholder
cd "$GITHUB_WORKSPACE/Kinesis_Kernel" || handle_error "Failed to return to kernel directory"

# --- Send build completion notification ---
BUILD_DURATION_MINUTES=$((SECONDS / 60))
BUILD_DURATION_SECONDS=$((SECONDS % 60))
tg "✅ Kernel compilation completed\! 🎉 File: \`$ZIP_NAME\`" #From sh 2
tg_doc "$GITHUB_WORKSPACE/Kinesis_Kernel/$ZIP_NAME" "✅ Build finished after ${BUILD_DURATION_MINUTES} minutes ${BUILD_DURATION_SECONDS} seconds" #From sh 2
