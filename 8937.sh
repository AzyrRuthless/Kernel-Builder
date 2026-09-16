#!/bin/bash
#
# Compile script kernel 🐧
# Copyright (C) 2024-2025 Rve.
# Copyright (C) AzyrRuthless (Significant modifications)

# --- Configuration ---
CLANG_DIR="${GITHUB_WORKSPACE}/RvClang"
KERNEL_SOURCE="https://github.com/AzyrRuthless/kernel_xiaomi_msm8937"
KERNEL_BRANCH="susfs"
ANYKERNEL_DIR="AnyKernel3" # Consistent directory name
DATE=$(date +"%Y%m%d-%H%M%S")
JOBS=$(nproc --all)

# --- ASCII Art ---
echo "
   _   __  ______   ____  _____
  | | / / / ____/  / __ \/ ___/
  | |/ / / / __   / / / /\__ \
  |    / / /_/ /  / /_/ /___/ /
  | |\ \ \____/   \____//____/
  |_| \_\
  
  Rve's Kernel Builder 🚀
"

# Setup environment
echo "[INFO] Setting up the environment... 🌎"
export KBUILD_BUILD_USER="Audemars"
export KBUILD_BUILD_HOST="ROG-G834JYR"
export USE_CCACHE=1
export CCACHE_DIR=/tmp/ccache
export PATH="$CLANG_DIR/bin:$PATH"

# Clone Kernel Source
echo "[INFO] Cloning kernel source from $KERNEL_SOURCE (branch: $KERNEL_BRANCH)... 👇"
git clone --depth=1 "$KERNEL_SOURCE" --branch "$KERNEL_BRANCH" kernel
cd kernel || exit

# --- KernelSU-Next Integration ---

# Setup KernelSU-Next environment
echo "[INFO] Setting up KernelSU-Next... 🌱"
KERNELSU_DIR="${GITHUB_WORKSPACE}/kernel/KernelSU-Next"
# Clone the next branch for KernelSU-Next
test -d "$KERNELSU_DIR" || git clone -b next https://github.com/KernelSU-Next/KernelSU-Next.git "$KERNELSU_DIR" && echo "[+] Repository cloned."
cd "$KERNELSU_DIR"
git stash && echo "[-] Stashed current changes."
git checkout next-susfs-dev && echo "[-] Switched to next-susfs-dev branch."
git pull && echo "[+] Repository updated."
cd "${GITHUB_WORKSPACE}/kernel" # Go back to kernel root

# Determine driver directory
if test -d "${GITHUB_WORKSPACE}/kernel/drivers"; then
     DRIVER_DIR="${GITHUB_WORKSPACE}/kernel/drivers"
else
     echo '[ERROR] "drivers/" directory not found. 😱'
     exit 127
fi

# Create a symlink
echo "[INFO] Creating symbolic link... 🔗"
ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$KERNELSU_DIR/kernel")" "$DRIVER_DIR/kernelsu" && echo "[+] Symlink created."

# Modify Makefile and Kconfig
DRIVER_MAKEFILE="$DRIVER_DIR/Makefile"
DRIVER_KCONFIG="$DRIVER_DIR/Kconfig"

echo "[INFO] Modifying Makefile and Kconfig... ✏️"
grep -q "kernelsu" "$DRIVER_MAKEFILE" || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_MAKEFILE" && echo "[+] Modified Makefile."
grep -q "source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG" || sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG" && echo "[+] Modified Kconfig."

# --- End of KernelSU-Next Integration ---

# Apply patches or other customizations if needed (add your commands here)

# Clean output directory
echo "[INFO] Cleaning output directory... 🧹"
rm -rf out

# Create output directory
echo "[INFO] Creating output directory... 📂"
mkdir -p out

# Verify symlink and drivers directory before configuring the kernel
echo "[INFO] Verifying symlink and drivers directory... 🤔"
if [ -L "$DRIVER_DIR/kernelsu" ]; then
  echo "[INFO] Symlink exists: $DRIVER_DIR/kernelsu -> $(readlink "$DRIVER_DIR/kernelsu")"
else
  echo "[ERROR] Symlink does NOT exist: $DRIVER_DIR/kernelsu ❌"
  exit 1
fi

if [ -f "$DRIVER_DIR/kernelsu/Kconfig" ]; then
  echo "[INFO] Kconfig file found: $DRIVER_DIR/kernelsu/Kconfig"
else
  echo "[ERROR] Kconfig file NOT found: $DRIVER_DIR/kernelsu/Kconfig ❌"
  exit 1
fi

# Configure the kernel using the vendor defconfig
echo "[INFO] Configuring the kernel with KSU enabled... ⚙️"
DEFCONFIG="vendor/rvkernel-mi8937_defconfig"
make O=out ARCH=arm64 ${DEFCONFIG}

# Build the kernel
echo "[INFO] Building the kernel... 🚧 This might take a while! ☕"
make -j"$JOBS" O=out ARCH=arm64 \
     CC="ccache clang" \
     LD=ld.lld \
     AR=llvm-ar \
     AS=llvm-as \
     NM=llvm-nm \
     STRIP=llvm-strip \
     OBJCOPY=llvm-objcopy \
     OBJDUMP=llvm-objdump \
     READELF=llvm-readelf \
     HOSTCC=clang \
     HOSTCXX=clang++ \
     HOSTAR=llvm-ar \
     HOSTLD=ld.lld \
     CROSS_COMPILE=aarch64-linux-gnu- \
     CROSS_COMPILE_ARM32=arm-linux-gnueabi- 2>&1 | tee out/build.log

# Check for build success
echo "[INFO] Kernel compiled successfully! 🎉"

# --- Prepare for AnyKernel3 ---
KERNEL_IMAGE="out/arch/arm64/boot/Image.gz-dtb"
OUTPUT_ZIP="KSU-rvkernel-$(basename $(git remote get-url origin) | sed 's/.*[\/:]\(.*\).git/\1/')-$DATE.zip"

# Clone and setup AnyKernel3
echo "[INFO] Setting up AnyKernel3... 🎁"
cd ../
# IMPORTANT: Clone AnyKernel3 from the CORRECT repo and branch
git clone --depth=1 "https://github.com/AzyrRuthless/AnyKernel3" --branch "msm8937" "$ANYKERNEL_DIR"
cd "$ANYKERNEL_DIR" || exit

# Clean AnyKernel3 directory
echo "[INFO] Cleaning AnyKernel3 directory... 🧹"
rm -rf .git README.md *placeholder

# Copy the compiled kernel image (Image.gz-dtb) to AnyKernel3 ROOT
echo "[INFO] Packaging with AnyKernel3... 📦"
cp "../kernel/$KERNEL_IMAGE" .

# IMPORTANT: Do NOT remove patch, modules, and ramdisk. Create empty directories instead.
echo "[INFO] Creating necessary directories (patch, modules, ramdisk)... 🗂️"
mkdir -p patch modules ramdisk

# Zip the AnyKernel3 package
echo "[INFO] Zipping AnyKernel3 package... 🤐"
zip -r9 "$OUTPUT_ZIP" *

# Move the zip to the output directory
echo "[INFO] Moving ZIP to output directory... 🚚"
mv "$OUTPUT_ZIP" ../kernel/out/

# --- Send Telegram notification (UPDATED) ---
if [ -n "$TELEGRAM_CHAT_ID" ] && [ -n "$TELEGRAM_BOT_TOKEN" ]; then
  echo "[INFO] Sending Telegram notification... 💬"
  curl -sf -F chat_id="$TELEGRAM_CHAT_ID" \
    -F document=@"../kernel/out/$OUTPUT_ZIP" \
    "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" \
    -F caption="Build Successful!\nProject: $PROJECT_NAME\nDevice: msm8937\nDate: $DATE"
fi

# Clean up unnecessary files
# echo "[INFO] Cleaning up unnecessary files... 🧹"
# rm -rf ../kernel/out/build.log
# rm -rf ../kernel/out/arch/arm64/boot/*.o
# rm -rf ../kernel/out/arch/arm64/boot/*.cmd
# rm -rf ../kernel/out/arch/arm64/boot/.*.cmd
# rm -rf ../kernel/out/arch/arm64/boot/*.ko
# rm -rf ../kernel/out/arch/arm64/boot/modules.order
# rm -rf ../kernel/out/arch/arm64/boot/Module.symvers
# rm -rf ../kernel/out/arch/arm64/boot/modules.builtin
# rm -rf ../kernel/out/arch/arm64/boot/modules.builtin.modinfo

# Export artifact name for GitHub Actions
echo "artifact_name=$OUTPUT_ZIP" >> "$GITHUB_OUTPUT"
echo "artifact_path=${GITHUB_WORKSPACE}/kernel/out/$OUTPUT_ZIP" >> "$GITHUB_OUTPUT"

echo "[INFO] Build completed! ✅"
