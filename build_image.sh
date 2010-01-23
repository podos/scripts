#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to build a bootable keyfob-based chromeos system image.
# It uses debootstrap (see https://wiki.ubuntu.com/DebootstrapChroot) to
# create a base file system. It then cusotmizes the file system and adds
# Ubuntu and chromeos specific packages. Finally, it creates a bootable USB
# image from the root fs.
#
# NOTE: This script must be run from the chromeos build chroot environment.
#

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

assert_inside_chroot
assert_not_root_user

DEFAULT_PKGLIST="${SRC_ROOT}/package_repo/package-list-prod.txt"

# Flags
DEFINE_integer build_attempt 1                                \
  "The build attempt for this image build."
DEFINE_string output_root "${DEFAULT_BUILD_ROOT}/images"      \
  "Directory in which to place image result directories (named by version)"
DEFINE_string build_root "$DEFAULT_BUILD_ROOT"                \
  "Root of build output"
DEFINE_boolean replace $FLAGS_FALSE "Overwrite existing output, if any."
DEFINE_boolean increment $FLAGS_FALSE \
  "Picks the latest build and increments the minor version by one."

DEFINE_string arch "x86" \
  "The target architecture to build for. One of { x86, armel }."
DEFINE_string mirror "$DEFAULT_IMG_MIRROR" "Repository mirror to use."
DEFINE_string suite "$DEFAULT_IMG_SUITE" "Repository suite to base image on."
DEFINE_string mirror2 "" "Additional repository mirror to use (URL only)."
DEFINE_string suite2 "" "Repository suite for additional mirror."
DEFINE_string pkglist "$DEFAULT_PKGLIST" \
  "Name of file listing packages to install from repository."
DEFINE_boolean with_dev_pkgs $FLAGS_TRUE \
  "Include additional developer-friendly packages in the image."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

# Determine build version
. "${SCRIPTS_DIR}/chromeos_version.sh"

# Use canonical path since some tools (e.g. mount) do not like symlinks
# Append build attempt to output directory
IMAGE_SUBDIR="${CHROMEOS_VERSION_STRING}-a${FLAGS_build_attempt}"
OUTPUT_DIR="${FLAGS_output_root}/${IMAGE_SUBDIR}"
ROOT_FS_DIR="${OUTPUT_DIR}/rootfs"
ROOT_FS_IMG="${OUTPUT_DIR}/rootfs.image"
MBR_IMG="${OUTPUT_DIR}/mbr.image"
OUTPUT_IMG="${OUTPUT_DIR}/usb.img"

LOOP_DEV=

# Handle existing directory
if [ -e "$OUTPUT_DIR" ]
then
  if [ $FLAGS_replace -eq $FLAGS_TRUE ]
  then
    sudo rm -rf "$OUTPUT_DIR"
  else
    echo "Directory $OUTPUT_DIR already exists."
    echo "Use --build_attempt option to specify an unused attempt."
    echo "Or use --replace if you want to overwrite this directory."
    exit 1
  fi
fi

# create the output directory
mkdir -p "$OUTPUT_DIR"

cleanup_rootfs_loop() {
  sudo umount "$LOOP_DEV"
  sleep 1  # in case $LOOP_DEV is in use
  sudo losetup -d "$LOOP_DEV"
  LOOP_DEV=""
}

cleanup() {
  # Disable die on error.
  set +e
  if [ -n "$LOOP_DEV" ]
  then
    cleanup_rootfs_loop
  fi

  # Turn die on error back on.
  set -e
}
trap cleanup EXIT

mkdir -p "$ROOT_FS_DIR"

# Create root file system disk image to fit on a 1GB memory stick.
# 1 GB in hard-drive-manufacturer-speak is 10^9, not 2^30.  700MB < 10^9 bytes.
ROOT_SIZE_BYTES=$((1024 * 1024 * 700))
dd if=/dev/zero of="$ROOT_FS_IMG" bs=1 count=1 seek=$((ROOT_SIZE_BYTES - 1))

# Format, tune, and mount the rootfs.
# Make sure we have a mtab to keep mkfs happy.
if [ ! -e /etc/mtab ]; then
  sudo touch /etc/mtab
fi
UUID=`uuidgen`
DISK_LABEL=C-ROOT
LOOP_DEV=`sudo losetup -f`
sudo losetup "$LOOP_DEV" "$ROOT_FS_IMG"
sudo mkfs.ext3 "$LOOP_DEV"
sudo tune2fs -L "$DISK_LABEL" -U "$UUID" -c 0 -i 0 "$LOOP_DEV"
sudo mount "$LOOP_DEV" "$ROOT_FS_DIR"

# -- Install packages and customize root file system. --
PKGLIST="$FLAGS_pkglist"
if [ $FLAGS_with_dev_pkgs -eq $FLAGS_TRUE ]; then
  PKGLIST="$PKGLIST,${SRC_ROOT}/package_repo/package-list-debug.txt"
fi
"${SCRIPTS_DIR}/install_packages.sh"  \
  --build_root="${FLAGS_build_root}"  \
  --root="$ROOT_FS_DIR"               \
  --output_dir="${OUTPUT_DIR}"        \
  --package_list="$PKGLIST"           \
  --arch="$FLAGS_arch"                \
  --mirror="$FLAGS_mirror"            \
  --suite="$FLAGS_suite"              \
  --mirror2="$FLAGS_mirror2"          \
  --suite2="$FLAGS_suite2"

"${SCRIPTS_DIR}/customize_rootfs.sh" --root="${ROOT_FS_DIR}"

# -- Turn root file system into bootable image --

if [ "$FLAGS_arch" = "x86" ]; then
  # Setup extlinux configuration.
  # TODO: For some reason the /dev/disk/by-uuid is not being generated by udev
  # in the initramfs. When we figure that out, switch to root=UUID=$UUID.
  cat <<EOF | sudo dd of="$ROOT_FS_DIR"/boot/extlinux.conf
DEFAULT chromeos-usb
PROMPT 0
TIMEOUT 0

  label chromeos-usb
  menu label chromeos-usb
  kernel vmlinuz
  append quiet console=tty2 initrd=initrd.img init=/sbin/init boot=local rootwait root=LABEL=$DISK_LABEL ro noresume noswap i915.modeset=1 loglevel=1

label chromeos-hd
  menu label chromeos-hd
  kernel vmlinuz
  append quiet console=tty2 init=/sbin/init boot=local rootwait root=HDROOT ro noresume noswap i915.modeset=1 loglevel=1
EOF

# Make partition bootable and label it.
sudo "$SCRIPTS_DIR/extlinux.sh" -z --install "${ROOT_FS_DIR}/boot"

fi  # --arch=x86

cleanup_rootfs_loop

if [ "$FLAGS_arch" = "x86" ]; then

# Create a master boot record.
# Start with the syslinux master boot record. We need to zero-pad to
# fill out a 512-byte sector size.
  SYSLINUX_MBR="/usr/lib/syslinux/mbr.bin"
  dd if="$SYSLINUX_MBR" of="$MBR_IMG" bs=512 count=1 conv=sync
  # Create a partition table in the MBR.
  NUM_SECTORS=$((`stat --format="%s" "$ROOT_FS_IMG"` / 512))
  sudo sfdisk -H64 -S32 -uS -f "$MBR_IMG" <<EOF
,$NUM_SECTORS,L,-,
,$NUM_SECTORS,S,-,
,$NUM_SECTORS,L,*,
;
EOF

fi  # --arch=x86

OUTSIDE_OUTPUT_DIR="${EXTERNAL_TRUNK_PATH}/src/build/images/${IMAGE_SUBDIR}"
echo "Done.  Image created in ${OUTPUT_DIR}"
echo "To copy to USB keyfob, outside the chroot, do something like:"
echo "  ./image_to_usb.sh --from=${OUTSIDE_OUTPUT_DIR} --to=/dev/sdb"
echo "To convert to VMWare image, outside the chroot, do something like:"
echo "  ./image_to_vmware.sh --from=${OUTSIDE_OUTPUT_DIR}"

trap - EXIT
