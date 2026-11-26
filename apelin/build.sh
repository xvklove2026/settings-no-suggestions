#!/bin/sh
# 工作区构建脚本：apelin_project_build 运行它，产出一个 .deb。
set -eu

: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}"  # roothide 上为空

stage="$(mktemp -d "${TMPDIR:?}stage.XXXXXX")"
trap 'rm -rf -- "${stage:?}"' EXIT

cd "${APELIN_PROJECT_ROOT:?}"

# 本机没有编译器时，使用与指定源码提交对应的公开云编译产物。
if ! command -v clang >/dev/null 2>&1 && [ -s cloud-cache/expected-source.txt ]; then
    exec sh apelin/package-cloud.sh
fi

TWEAK=APSNoSuggestions
BUNDLE=APSNoSuggestionsPrefs

PKG_ID="$(sed -n 's/^Package:[[:space:]]*//p' control)"
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' control)"
[ -n "${PKG_ID}" ] && [ -n "${VERSION}" ] || {
    echo "build: control has no Package or Version" >&2
    exit 1
}

# Apelin 的开发支持组件（substrate.h、Preferences 头文件）装在引导自己的 root 里：
# roothide 在 .jbroot-* 下，rootless 在 /var/jb 下。脚本跑在 bootstrap 的 shell 里
# （jbroot 是它的 /，真实系统在 /rootfs 下），而 clang 用真实路径，所以先在 shell
# 视角的 /rootfs 下把那个 root 找出来，再去掉 /rootfs 前缀交给编译器。
# 两个目标用的是同一份头文件，编 rootless 包时也从这里取。
DEV=""
DEVSHELL=""
for d in /rootfs/private/var/containers/Bundle/Application/.jbroot-* \
         /rootfs/var/jb /var/jb; do
    if [ -d "${d}/usr/share/apelin/development" ]; then
        DEVSHELL="${d}/usr/share/apelin/development"
        DEV="${d#/rootfs}/usr/share/apelin/development"
        break
    fi
done
[ -n "${DEV}" ] && [ -n "${DEVSHELL}" ] || {
    echo "build: cannot locate apelin development support" >&2
    exit 1
}
echo "build: development support at ${DEV}" >&2
TWEAK_INC="${DEV}/wiki.qaq.apelin.dev.tweak/support/include"
PREFS_INC="${DEV}/wiki.qaq.apelin.dev.preferences/support/include"

[ -f "${DEVSHELL}/wiki.qaq.apelin.dev.tweak/support/include/substrate.h" ] || {
    echo "build: missing ${TWEAK_INC}/substrate.h" >&2
    exit 1
}
[ -f "${DEVSHELL}/wiki.qaq.apelin.dev.preferences/support/include/Preferences/PSListController.h" ] || {
    echo "build: missing ${PREFS_INC}/Preferences/PSListController.h" >&2
    exit 1
}

DEFS="-DAPELIN_PACKAGE_ID=\"${PKG_ID}\" -DAPELIN_VERSION=\"${VERSION}\" -DAPELIN_BUILD_ID=\"${APELIN_BUILD_ID}\""
case "${APELIN_BOOTSTRAP}" in
    roothide)
        DEFS="${DEFS} -DAPELIN_BOOTSTRAP_ROOTHIDE=1"
        ;;
    *)
        DEFS="${DEFS} -DAPELIN_BOOTSTRAP_ROOTLESS=1"
        ;;
esac
# arm64e 是本机原生架构，arm64 让 A11 及更早的设备（以及 arm64 的引导）也能
# 加载同一个 dylib：两种引导都编两个切片，最后用 lipo 合成一个通用二进制。
ARCHS="arm64 arm64e"

OBJ="${stage}/.obj"
# rootless 的包内路径从 /var/jb 起（APELIN_PREFIX），roothide 上为空。
DEST="${stage}${APELIN_PREFIX}"
mkdir -p "${OBJ}" "${DEST}/Library/MobileSubstrate/DynamicLibraries"

# 1. tweak 本体
for arch in ${ARCHS}; do
    clang -arch "${arch}" -dynamiclib -fobjc-arc -fvisibility=hidden -O2 \
        -Werror=unguarded-availability-new \
        -I "${TWEAK_INC}" \
        ${DEFS} \
        -framework Foundation -framework UIKit \
        -Wl,-U,_MSHookMessageEx \
        Sources/Tweak.m \
        Sources/SpringBoard.m \
        -o "${OBJ}/${TWEAK}.${arch}.dylib"
done
lipo -create -output "${OBJ}/${TWEAK}.dylib" \
    "${OBJ}/${TWEAK}.arm64.dylib" "${OBJ}/${TWEAK}.arm64e.dylib"
ldid -S "${OBJ}/${TWEAK}.dylib"
cp "${OBJ}/${TWEAK}.dylib" "${DEST}/Library/MobileSubstrate/DynamicLibraries/${TWEAK}.dylib"
cp "Resources/${TWEAK}.plist" "${DEST}/Library/MobileSubstrate/DynamicLibraries/${TWEAK}.plist"

# 2. 设置面板（存在时才构建）
if [ -d Sources/Prefs ] && [ -d Resources/Bundle ]; then
    BUNDLE_DIR="${DEST}/Library/PreferenceBundles/${BUNDLE}.bundle"
    mkdir -p "${BUNDLE_DIR}"
    for arch in ${ARCHS}; do
        clang -arch "${arch}" -bundle -fobjc-arc -fvisibility=hidden -O2 \
            -Werror=unguarded-availability-new \
            -I "${PREFS_INC}" \
            ${DEFS} \
            -framework Foundation -framework UIKit \
            '-Wl,-U,_OBJC_CLASS_$_PSListController' \
            '-Wl,-U,_OBJC_METACLASS_$_PSListController' \
            '-Wl,-U,_OBJC_CLASS_$_PSSpecifier' \
            Sources/Prefs/*.m \
            -o "${OBJ}/${BUNDLE}.${arch}"
    done
    lipo -create -output "${OBJ}/${BUNDLE}" \
        "${OBJ}/${BUNDLE}.arm64" "${OBJ}/${BUNDLE}.arm64e"
    ldid -S "${OBJ}/${BUNDLE}"
    cp "${OBJ}/${BUNDLE}" "${BUNDLE_DIR}/${BUNDLE}"
    sed -e "s|@PACKAGE_ID@|${PKG_ID}|g" -e "s|@VERSION@|${VERSION}|g" \
        Resources/Bundle/Root.plist > "${BUNDLE_DIR}/Root.plist"
    sed -e "s|@PACKAGE_ID@|${PKG_ID}|g" -e "s|@VERSION@|${VERSION}|g" \
        Resources/Bundle/Info.plist > "${BUNDLE_DIR}/Info.plist"
    cp Resources/Bundle/icon.png Resources/Bundle/icon@2x.png \
        Resources/Bundle/icon@3x.png "${BUNDLE_DIR}/"

    mkdir -p "${DEST}/Library/PreferenceLoader/Preferences"
    cp Resources/Bundle/Entry.plist \
        "${DEST}/Library/PreferenceLoader/Preferences/${BUNDLE}.plist"
fi

# 3. 打包
mkdir -p "${stage}/DEBIAN"
sed "s|@ARCH@|${APELIN_ARCHITECTURE}|" control > "${stage}/DEBIAN/control"
rm -rf -- "${OBJ:?}"
dpkg-deb -b --root-owner-group "${stage:?}" "${APELIN_PACKAGE_DIR:?}/"
