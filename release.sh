#!/bin/bash

user_error() {
  echo user error, please replace user and try again >&2
  exit 1
}

[[ $# -eq 1 ]] || user_error
[[ -n $BUILD_NUMBER ]] || user_error

KEY_DIR=keys/$1
OUT=out/release-$1-$BUILD_NUMBER
PREFIX=aosp_

source device/common/clear-factory-images-variables.sh

DEVICE=$1
case "$DEVICE" in
  hikey*)
    VERITY_MODE=none
    PREFIX=
    ;;
  bullhead)
    VENDOR=lge
    VERITY_MODE=legacy
    ;;
  angler)
    VENDOR=huawei
    VERITY_MODE=legacy
    ;;
  marlin|sailfish)
    VENDOR=google_devices
    VERITY_MODE=legacy
    ;;
  taimen|walleye)
    VENDOR=google_devices
    VERITY_MODE=avb1
    ;;
  crosshatch|blueline|*)
    VENDOR=google_devices
    VERITY_MODE=avb2
esac

get_radio_image() {
  grep -Po "require version-$1=\K.+" vendor/$2/vendor-board-info.txt | tr '[:upper:]' '[:lower:]'
}

if [ -n "$VENDOR" ]; then
  BOOTLOADER=$(get_radio_image bootloader $VENDOR/$1)
  RADIO=$(get_radio_image baseband $VENDOR/$1)
fi

BUILD=$BUILD_NUMBER
VERSION=$(grep -Po "export BUILD_ID=\K.+" build/core/build_id.mk | tr '[:upper:]' '[:lower:]')

mkdir -p $OUT || exit 1

TARGET_FILES=$DEVICE-target_files-$BUILD.zip

case "$VERITY_MODE" in
  legacy)
    VERITY_SWITCHES=(--replace_verity_public_key "$KEY_DIR/verity_key.pub" --replace_verity_private_key "$KEY_DIR/verity"
                     --replace_verity_keyid "$KEY_DIR/verity.x509.pem")
    ;;
  avb1)
    # Use avb.pem to sign vbmeta.img, which contains salts + hashes for
    # all partitions.
    VERITY_SWITCHES=(--avb_vbmeta_key "$KEY_DIR/avb.pem" --avb_vbmeta_algorithm SHA256_RSA2048)
    ;;
  avb2)
    # By default, Android sets BOARD_AVB_SYSTEM_KEY_PATH to
    # external/avb/test/data/testkey_rsa2048.pem, which means system.img
    # uses a chained descriptor signed with an insecure test key.  Replace
    # the test key with our own avb.pem.
    VERITY_SWITCHES=(--avb_vbmeta_key "$KEY_DIR/avb.pem" --avb_vbmeta_algorithm SHA256_RSA2048 --avb_system_key "$KEY_DIR/avb.pem" --avb_system_algorithm SHA256_RSA2048)
    ;;
esac

if [[ $DEVICE == bullhead ]]; then
  EXTRA_OTA=(-b device/lge/bullhead/update-binary)
fi

build/tools/releasetools/sign_target_files_apks -o -d "$KEY_DIR" "${VERITY_SWITCHES[@]}" \
  out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/$PREFIX$DEVICE-target_files-$BUILD_NUMBER.zip \
  $OUT/$TARGET_FILES || exit 1

if [[ $DEVICE != hikey* ]]; then
  build/tools/releasetools/ota_from_target_files --block -k "$KEY_DIR/releasekey" "${EXTRA_OTA[@]}" $OUT/$TARGET_FILES \
    $OUT/$DEVICE-ota_update-$BUILD.zip || exit 1
fi

sed -i 's/zipfile\.ZIP_DEFLATED/zipfile\.ZIP_STORED/' build/tools/releasetools/img_from_target_files.py
build/tools/releasetools/img_from_target_files $OUT/$TARGET_FILES \
  $OUT/$DEVICE-img-$BUILD.zip || exit 1

cd $OUT || exit 1

# used by generate-factory-images-common.sh
PRODUCT=$DEVICE

if [[ $DEVICE == hikey* ]]; then
  source ../../device/linaro/hikey/factory-images/generate-factory-images-$DEVICE.sh
else
  sed -i 's/zip -r/tar cvf/' ../../device/common/generate-factory-images-common.sh
  sed -i 's/factory\.zip/factory\.tar/' ../../device/common/generate-factory-images-common.sh
  sed -i '/^mv / d' ../../device/common/generate-factory-images-common.sh
  source ../../device/common/generate-factory-images-common.sh
fi

mv $DEVICE-$VERSION-factory.tar $DEVICE-factory-$BUILD_NUMBER.tar
rm -f $DEVICE-factory-$BUILD_NUMBER.tar.xz
pxz -v $DEVICE-factory-$BUILD_NUMBER.tar
