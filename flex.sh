#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.
# set -x # Uncomment for detailed command tracing

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
  # Use MarkdownV2, escape message for safety
  local escaped_msg=$(echo "$msg" | sed 's/\([_*\[\]()~`>#+-=|{}.!]\)/\\\1/g')
  curl -s --connect-timeout 10 --retry 3 -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d parse_mode="MarkdownV2" \
    -d text="${escaped_msg} \- \`${formatted_date}\`" > /dev/null || log "⚠️ Failed to send Telegram message (non-critical)"
}

# --- Function to send Telegram documents with error handling ---
tg_doc() {
  local file="$1"
  local caption="$2"
  # Escape Markdown characters in caption
  local escaped_caption=$(echo "$caption" | sed 's/\([_*\[\]()~`>#+-=|{}.!]\)/\\\1/g')
  log "➡️ Sending Telegram document: $file"
  # Use MarkdownV2 for caption formatting
  if ! curl -s --connect-timeout 15 --retry 3 -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" \
    -F chat_id="$TELEGRAM_CHAT_ID" \
    -F document="@$file" \
    -F parse_mode="MarkdownV2" \
    -F caption="${escaped_caption}"; then
    log "❌ Failed to send Telegram document: $file"
    # Send plain text fallback notification
    tg "❌ Failed to send Telegram document: \`$file\`\. Check logs\."
  fi
}

# --- Function to handle errors with logging ---
handle_error() {
  local error_message="$1"
  local exit_code=${2:-1} # Use provided exit code or default to 1
  log "❌ An error occurred: $error_message"
  tg "❌ Build failed: \`$error_message\`"
  # Attempt to upload logs even on failure
  if [ -f "build.log" ]; then
     local log_snippet=$(tail -n 10 build.log | sed 's/\([_*\[\]()~`>#+-=|{}.!]\)/\\\1/g') # Escape snippet
     tg_doc "build.log" "📄 Build log snippet on failure: $error_message \n\`\`\`\n$log_snippet\n\`\`\`"
  fi
  exit $exit_code
}

# --- Start the build process ---
START_TIME=$SECONDS
log "🚀 Starting build at $(date)"
tg "🚀 Build triggered for Source: \`${KERNEL_SOURCE:-Not Set}\` Branch: \`${KERNEL_BRANCH:-Not Set}\`"

# --- Check if KERNEL_SOURCE and KERNEL_BRANCH are set ---
if [ -z "$KERNEL_SOURCE" ] || [ -z "$KERNEL_BRANCH" ]; then
  handle_error "KERNEL_SOURCE or KERNEL_BRANCH environment variable is not set."
fi

# --- Clean up previous kernel directory ---
KERNEL_DIR="$GITHUB_WORKSPACE/Kinesis_Kernel"
if [ -d "$KERNEL_DIR" ]; then
  log "🗑️ Cleaning up previous kernel directory..."
  rm -rf "$KERNEL_DIR"
fi

# --- Clone the kernel source ---
log "⬇️ Cloning kernel source from: $KERNEL_SOURCE (branch: $KERNEL_BRANCH)..."
if ! git clone --depth=1 "$KERNEL_SOURCE" -b "$KERNEL_BRANCH" "$KERNEL_DIR"; then
  handle_error "Failed to clone kernel source"
fi
cd "$KERNEL_DIR" || handle_error "Failed to enter kernel directory: $KERNEL_DIR"

# --- Integrate KernelSU-Next ---
# (KernelSU integration steps remain the same)
log "🧩 Integrating KernelSU-Next..."
KERNELSU_DIR="$KERNEL_DIR/kernel/KernelSU-Next"
USE_KERNELSU=false # Default to false
if [ ! -d "$KERNELSU_DIR" ]; then
  log "⬇️ Cloning KernelSU-Next repository..."
  if git clone -q --depth=1 -b next https://github.com/AzyrRuthless/KernelSU-Next.git "$KERNELSU_DIR"; then
     log "✅ KernelSU-Next repository cloned."
     USE_KERNELSU=true
  else
     log "⚠️ Failed to clone KernelSU-Next repository. Continuing without it."
  fi
else
  log "✅ KernelSU-Next directory found within source. Updating..."
  cd "$KERNELSU_DIR" || log "⚠️ Could not enter KSU dir to update"
  if git stash >/dev/null 2>&1; then log "➖ Stashed current changes (if any)."; fi
  if git checkout -q next; then log "➖ Switched to 'next' branch."; fi
  if git pull; then
    log "🔄 KernelSU-Next repository updated."
    USE_KERNELSU=true
  else
    log "⚠️ Failed to update KernelSU-Next. Using existing version."
    USE_KERNELSU=true # Still attempt to use it if update failed
  fi
  cd "$KERNEL_DIR" || handle_error "Failed to return to kernel directory after KSU update"
fi

if [ "$USE_KERNELSU" = true ]; then
  DRIVER_DIR=""
  if [ -d "$KERNEL_DIR/common/drivers" ]; then DRIVER_DIR="$KERNEL_DIR/common/drivers";
  elif [ -d "$KERNEL_DIR/drivers" ]; then DRIVER_DIR="$KERNEL_DIR/drivers";
  else log '⚠️ "drivers/" directory not found, cannot integrate KSU fully.'; USE_KERNELSU=false; fi

  if [ "$USE_KERNELSU" = true ]; then
    log "🔗 Creating symlink for KernelSU..."
    if [ ! -d "$KERNELSU_DIR/kernel" ]; then
        log "⚠️ KernelSU source directory '$KERNELSU_DIR/kernel' not found! Skipping KSU integration."
        USE_KERNELSU=false
    else
      ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$KERNELSU_DIR/kernel")" "$DRIVER_DIR/kernelsu"
      log "✅ Symlink created."

      DRIVER_MAKEFILE="$DRIVER_DIR/Makefile"
      DRIVER_KCONFIG="$DRIVER_DIR/Kconfig"

      if [ -f "$DRIVER_MAKEFILE" ]; then
        if ! grep -q "kernelsu/" "$DRIVER_MAKEFILE"; then
          printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_MAKEFILE"; log "📝 Makefile modified.";
        fi
      fi
      if [ -f "$DRIVER_KCONFIG" ]; then
        if ! grep -q "source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG"; then
          if grep -q "endmenu" "$DRIVER_KCONFIG"; then sed -i "/endmenu/i\source \"drivers\/kernelsu\/Kconfig\"" "$DRIVER_KCONFIG";
          else echo "source \"drivers/kernelsu/Kconfig\"" >> "$DRIVER_KCONFIG"; fi
          log "📝 Kconfig modified.";
        fi
      fi
    fi
  fi
else
  log "ℹ️ Skipping KernelSU integration steps."
fi


# --- Setup ccache ---
log "🧰 Setting up ccache..."
export CCACHE_DIR=/tmp/ccache
if command -v ccache &> /dev/null; then
    export CCACHE_EXEC=$(which ccache)
    export USE_CCACHE=1
    ccache -M 15G
    ccache -o compression=true
    ccache -z
    log "✅ ccache configured. Initial stats: $(ccache -s | grep 'cache size')"
else
    log "⚠️ ccache command not found. Disabling ccache."
    export USE_CCACHE=0
fi

# --- Download and Extract Zyc-Clang ---
CLANG_DIR="$HOME/Zyc-Clang"
CLANG_VERSION_FILE="$CLANG_DIR/clang_version.txt"
log "⬇️ Checking for Zyc-Clang..."

# Function to download and extract
download_extract_clang() {
    log " Downloading and extracting Zyc-Clang..."
    LATEST_RELEASE_URL=$(curl -s --retry 3 --retry-delay 5 "https://api.github.com/repos/ZyCromerZ/Clang/releases/latest" | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url')
    if [ -z "$LATEST_RELEASE_URL" ] || [ "$LATEST_RELEASE_URL" == "null" ]; then
      handle_error "Failed to retrieve the latest release URL for Zyc-Clang after retries."
    fi
    log " Downloading from $LATEST_RELEASE_URL"
    wget --quiet "$LATEST_RELEASE_URL" -O "$HOME/Zyc-Clang.tar.gz" || handle_error "Failed to download Zyc-Clang"
    mkdir -p "$CLANG_DIR"
    # Use original extraction method
    tar -xf "$HOME/Zyc-Clang.tar.gz" -C "$CLANG_DIR" || handle_error "Failed to extract Zyc-Clang"
    log " Listing contents of $CLANG_DIR after extraction:"
    ls -l "$CLANG_DIR"
    rm "$HOME/Zyc-Clang.tar.gz"
    # Store version info
    if [ -f "$CLANG_DIR/bin/clang" ]; then
      "$CLANG_DIR/bin/clang" --version > "$CLANG_VERSION_FILE"
      log "✅ Zyc-Clang extracted to $CLANG_DIR"
      log "✅ Clang version: $(head -n 1 $CLANG_VERSION_FILE)"
    else
      log " Listing contents of $CLANG_DIR/bin/ (if exists):"
      ls -l "$CLANG_DIR/bin/" || true
      handle_error "Clang executable not found at '$CLANG_DIR/bin/clang' after extraction!"
    fi
}

# Check if Clang directory exists and is valid
if [ ! -d "$CLANG_DIR" ] || [ ! -f "$CLANG_DIR/bin/clang" ] || [ ! -f "$CLANG_VERSION_FILE" ]; then
  log "⚠️ Clang directory invalid or version file missing. Re-downloading..."
  if [ -d "$CLANG_DIR" ]; then rm -rf "$CLANG_DIR"; fi # Clean before download
  download_extract_clang
else
  log "✅ Existing Zyc-Clang found at $CLANG_DIR. Version: $(head -n 1 $CLANG_VERSION_FILE)"
fi

# --- Add Clang directory to PATH ---
log "🔧 Adding Clang tools to PATH..."
export PATH="$CLANG_DIR/bin:$PATH"
log " PATH set to: $PATH"

# --- Verify toolchain access ---
log " Verifying toolchain access in PATH..."
if ! command -v clang &> /dev/null; then handle_error "❌ clang not found in PATH!"; fi
if ! command -v ld.lld &> /dev/null; then handle_error "❌ ld.lld not found in PATH!"; fi
log "✅ clang found at: $(command -v clang)"
log "✅ ld.lld found at: $(command -v ld.lld)"

# --- Set environment variables for build ---
log "🔧 Setting build environment variables..."
export ARCH=arm64
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-Audemars}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-GitHubActions} # Use GitHubActions as default host
export TZ=Asia/Jakarta
export KBUILD_BUILD_TIMESTAMP=$(TZ=$TZ date '+%a %b %d %H:%M:%S %Z %Y')

# --- Set LLVM/Clang toolchain flags ---
export CLANG_TRIPLE="aarch64-linux-gnu-"
# Set CROSS_COMPILE needed by Kbuild for non-CC tasks (like linker scripts, objcopy etc.)
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
# Set main compiler and linker Kbuild will use when LLVM=1
export CC=clang
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export STRIP=llvm-strip
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump

export PROJECT_NAME="KSU"
export DEVICE_CODENAME="miatoll"

# --- Set defconfig ---
DEFCONFIG="vendor/xiaomi/miatoll_defconfig"
DEFCONFIG_PATH="arch/arm64/configs/$DEFCONFIG"
log "⚙️ Using defconfig: $DEFCONFIG"
if [ ! -f "$DEFCONFIG_PATH" ]; then
    handle_error "Defconfig file not found at: $DEFCONFIG_PATH"
fi

# --- Get release version from defconfig ---
DEFCONFIG_CONTENT=$(cat "$DEFCONFIG_PATH")
RELEASE_VERSION=$(echo "$DEFCONFIG_CONTENT" | grep "CONFIG_LOCALVERSION=" | sed 's/CONFIG_LOCALVERSION="\(.*\)"/\1/')
RELEASE_VERSION="${RELEASE_VERSION#-}"
IFS=- read -r KERNEL_VARIANT KERNEL_CODENAME RELEASE_VERSION_SUFFIX <<< "$RELEASE_VERSION" || true
FULL_RELEASE_VERSION="${KERNEL_VARIANT}-${KERNEL_CODENAME}-${RELEASE_VERSION_SUFFIX}"
FULL_RELEASE_VERSION=$(echo "$FULL_RELEASE_VERSION" | sed 's/--/-/g' | sed 's/-$//' | sed 's/^-//') # Clean up hyphens
log "ℹ️ Full Release String: $FULL_RELEASE_VERSION"

# --- Create output directory ---
export KBUILD_OUTPUT="${KBUILD_OUTPUT:-out}"
mkdir -p "$KBUILD_OUTPUT"
log "📁 Output directory set to: $KBUILD_OUTPUT/"

# --- Handle clean/regen arguments ---
if [[ "$1" == "-c" || "$1" == "--clean" ]]; then
  log "🗑️ Cleaning output directory ($KBUILD_OUTPUT)..."
  make O="$KBUILD_OUTPUT" mrproper
  log "✅ Output directory cleaned."
elif [[ "$1" == "-r" || "$1" == "--regen" ]]; then
  log "🔄 Regenerating defconfig ($DEFCONFIG)..."
  # Ensure necessary vars are passed for defconfig regeneration too
  make O="$KBUILD_OUTPUT" ARCH=arm64 \
       CROSS_COMPILE=$CROSS_COMPILE \
       CLANG_TRIPLE=$CLANG_TRIPLE \
       CC=$CC LD=$LD AR=$AR NM=$NM STRIP=$STRIP OBJCOPY=$OBJCOPY OBJDUMP=$OBJDUMP \
       LLVM=1 LLVM_IAS=1 \
       $DEFCONFIG
  make O="$KBUILD_OUTPUT" savedefconfig
  if [ -f "$KBUILD_OUTPUT/defconfig" ]; then
    cp "$KBUILD_OUTPUT/defconfig" "$DEFCONFIG_PATH"
    log "✅ Defconfig regenerated and saved to $DEFCONFIG_PATH."
    tg "✅ Defconfig \`$DEFCONFIG\` regenerated for branch \`${KERNEL_BRANCH}\`\."
  else
    handle_error "Failed to regenerate defconfig (out/defconfig not found)."
  fi
  exit 0
fi

# --- Make defconfig ---
log "⚙️ Generating .config from $DEFCONFIG..."
# Pass necessary vars for defconfig generation
make O="$KBUILD_OUTPUT" ARCH=arm64 \
     CROSS_COMPILE=$CROSS_COMPILE \
     CLANG_TRIPLE=$CLANG_TRIPLE \
     CC=$CC LD=$LD AR=$AR NM=$NM STRIP=$STRIP OBJCOPY=$OBJCOPY OBJDUMP=$OBJDUMP \
     LLVM=1 LLVM_IAS=1 \
     $DEFCONFIG

# --- Start kernel compilation ---
log "🔥 Starting kernel compilation... (Log: build.log)"
# Check CROSS_COMPILE value just before make
log " Using CROSS_COMPILE=${CROSS_COMPILE}"

# --- Define MAKE_ARGS Array ---
MAKE_ARGS=(
    "O=$KBUILD_OUTPUT"
    "ARCH=arm64"
    # Explicitly pass CROSS_COMPILE on make command line, similar to original script
    "CROSS_COMPILE=${CROSS_COMPILE}"
    "CLANG_TRIPLE=${CLANG_TRIPLE}" # Pass clang triple too
    "CC=${CC}" # Pass CC
    "LD=${LD}" # Pass LD
    "AR=${AR}" # Pass AR
    "NM=${NM}" # Pass NM
    "STRIP=${STRIP}" # Pass STRIP
    "OBJCOPY=${OBJCOPY}" # Pass OBJCOPY
    "OBJDUMP=${OBJDUMP}" # Pass OBJDUMP
    "LLVM=1"
    "LLVM_IAS=1"
    "-j$(nproc --all)"
)
# Add ccache wrapper if enabled (Kbuild should handle USE_CCACHE=1, but being explicit can help)
if [ "$USE_CCACHE" = 1 ] && [ -n "$CCACHE_EXEC" ]; then
     MAKE_ARGS+=("CC=ccache clang") # Explicitly wrap CC with ccache
     log " ccache explicitly added to CC make argument"
fi

# Execute build and tee output to log file
make "${MAKE_ARGS[@]}" 2>&1 | tee build.log
BUILD_STATUS=${PIPESTATUS[0]} # Get the exit code of 'make'

# --- Check for compilation errors ---
if [[ $BUILD_STATUS -ne 0 ]]; then
  handle_error "Kernel compilation failed (Exit code: $BUILD_STATUS). Check build.log." $BUILD_STATUS
fi

log "✅ Kernel compilation successful."

# --- Get Clang and LLD versions ---
CLANG_VERSION=$(head -n 1 "$CLANG_VERSION_FILE")
LLD_VERSION=$("$CLANG_DIR/bin/ld.lld" --version 2>&1 | head -n 1)
log "ℹ️ Using Clang: $CLANG_VERSION"
log "ℹ️ Using LLD: $LLD_VERSION"

# --- Define expected output files ---
IMAGE_FILE="$KBUILD_OUTPUT/arch/arm64/boot/Image.gz"
DTBO_FILE="$KBUILD_OUTPUT/arch/arm64/boot/dtbo.img"
DTB_QCOM_DIR="$KBUILD_OUTPUT/arch/arm64/boot/dts/qcom"
DTB_FILE="$DTB_QCOM_DIR/cust-atoll-ab.dtb"

# --- Check if essential build artifacts exist ---
if [ ! -f "$IMAGE_FILE" ]; then handle_error "Build artifact 'Image.gz' not found"; fi
if [ ! -f "$DTBO_FILE" ]; then log "⚠️ Build artifact 'dtbo.img' not found. This might be expected."; fi
if [ ! -f "$DTB_FILE" ]; then log "⚠️ Build artifact 'cust-atoll-ab.dtb' not found. This might be expected."; fi

# --- Clone AnyKernel3 ---
ANYKERNEL_DIR="$KERNEL_DIR/anykernel"
log "⬇️ Cloning AnyKernel3..."
if ! git clone -q --depth=1 -b Ivory https://github.com/AzyrRuthless/AnyKernel3 "$ANYKERNEL_DIR"; then handle_error "Failed to clone AnyKernel3"; fi

# --- Copy files to AnyKernel3 ---
log "📦 Preparing AnyKernel3 zip..."
cp "$IMAGE_FILE" "$ANYKERNEL_DIR/"; log " Copied Image.gz"
if [ -f "$DTBO_FILE" ]; then cp "$DTBO_FILE" "$ANYKERNEL_DIR/"; log " Copied dtbo.img"; fi
if [ -d "$DTB_QCOM_DIR" ]; then
    mkdir -p "$ANYKERNEL_DIR/dtb"
    if [ -f "$DTB_FILE" ]; then cp "$DTB_FILE" "$ANYKERNEL_DIR/dtb/"; log " Copied cust-atoll-ab.dtb";
    else log " Specific DTB ($DTB_FILE) not found, skipping copy."; fi
else log "⚠️ DTB directory ($DTB_QCOM_DIR) not found, skipping DTB copy."; fi

# --- Create ZIP archive ---
ZIP_NAME="${PROJECT_NAME}-${FULL_RELEASE_VERSION}-${DEVICE_CODENAME}-$(date '+%Y%m%d-%H%M').zip"
ZIP_PATH="$KERNEL_DIR/$ZIP_NAME"
log "🗜️ Creating ZIP archive: $ZIP_NAME"
cd "$ANYKERNEL_DIR" || handle_error "Failed to enter AnyKernel3 directory"
zip -r9 "$ZIP_PATH" ./* -x '*.git*' README.md ./*placeholder || handle_error "Failed to create ZIP archive"
cd "$KERNEL_DIR" || handle_error "Failed to return to kernel directory"

# --- Build completion notification ---
END_TIME=$SECONDS
BUILD_DURATION=$((END_TIME - START_TIME))
BUILD_DURATION_MINUTES=$((BUILD_DURATION / 60))
BUILD_DURATION_SECONDS=$((BUILD_DURATION % 60))
log "🎉 Build completed in ${BUILD_DURATION_MINUTES} minutes ${BUILD_DURATION_SECONDS} seconds!"
log "📦 ZIP archive created: $ZIP_NAME"

# --- Show ccache statistics ---
if [ "$USE_CCACHE" = 1 ]; then
    log "📊 ccache statistics:"
    ccache -s
fi

# --- Send success notifications ---
tg "✅ Build successful\! 🎉 \`${ZIP_NAME}\` (${BUILD_DURATION_MINUTES}m ${BUILD_DURATION_SECONDS}s)"
tg_doc "$ZIP_PATH" "✅ \`${ZIP_NAME}\` Built in ${BUILD_DURATION_MINUTES}m ${BUILD_DURATION_SECONDS}s"

# --- Prepare artifacts for upload ---
ARTIFACT_DIR="$GITHUB_WORKSPACE/kernel_artifacts"
log "⬆️ Preparing artifacts for upload in: $ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"
cp "$IMAGE_FILE" "$ARTIFACT_DIR/"
if [ -f "$DTBO_FILE" ]; then cp "$DTBO_FILE" "$ARTIFACT_DIR/"; fi
if [ -f "$DTB_FILE" ]; then cp "$DTB_FILE" "$ARTIFACT_DIR/"; fi
cp "$ZIP_PATH" "$ARTIFACT_DIR/"
if [ -f "build.log" ]; then cp "build.log" "$ARTIFACT_DIR/build-${ZIP_NAME%.zip}.log"; fi

# --- Debugging output ---
log "🔍 Final contents of $ARTIFACT_DIR:"
ls -la "$ARTIFACT_DIR"

# --- Set 'artifact_dir' output variable for the workflow ---
echo "artifact_dir=$ARTIFACT_DIR" >> "$GITHUB_OUTPUT"

log "✅ Script finished successfully."
exit 0

