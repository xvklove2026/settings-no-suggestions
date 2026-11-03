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

TWEAK=APSNoSuggestions
BUNDLE=APSNoSuggestionsPrefs

PKG_ID="$(sed -n 's/^Package:[[:space:]]*//p' control)"
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' control)"
[ -n "${PKG_ID}" ] && [ -n "${VERSION}" ] || {
    echo "build: control has no Package or Version" >&2
    exit 1
}

# Apelin 的开发支持组件（substrate.h、Preferences 头文件）在 bootstrap 里，
# 编译器的路径是真实路径，roothide 上要从项目真实路径里取回 jbroot。
if [ "${APELIN_BOOTSTRAP}" = roothide ]; then
    # 构建脚本在 bootstrap 的 shell 里（jbroot 就是它的 /，真实系统在 /rootfs 下），
    # 而 clang 用真实路径：在真实根下找出带开发支持组件的那个 .jbroot-*。
    VROOT=/rootfs
    JBROOT=""
    for d in /rootfs/private/var/containers/Bundle/Application/.jbroot-*; do
        if [ -d "${d}/usr/share/apelin/development" ]; then
            JBROOT="${d#/rootfs}"
            break
        fi
    done
    [ -n "${JBROOT}" ] || {
        echo "build: cannot locate the bootstrap root" >&2
        exit 1
    }
else
    VROOT=""
    JBROOT=/var/jb
fi
echo "build: bootstrap root is ${JBROOT}" >&2
DEV="${JBROOT}/usr/share/apelin/development"
TWEAK_INC="${DEV}/wiki.qaq.apelin.dev.tweak/support/include"
PREFS_INC="${DEV}/wiki.qaq.apelin.dev.preferences/support/include"

[ -f "${VROOT}${TWEAK_INC}/substrate.h" ] || {
    echo "build: missing ${TWEAK_INC}/substrate.h" >&2
    exit 1
}
[ -f "${VROOT}${PREFS_INC}/Preferences/PSListController.h" ] || {
    echo "build: missing ${PREFS_INC}/Preferences/PSListController.h" >&2
    exit 1
}

DEFS="-DAPELIN_PACKAGE_ID=\"${PKG_ID}\" -DAPELIN_VERSION=\"${VERSION}\" -DAPELIN_BUILD_ID=\"${APELIN_BUILD_ID}\""
case "${APELIN_BOOTSTRAP}" in
    roothide)
        DEFS="${DEFS} -DAPELIN_BOOTSTRAP_ROOTHIDE=1"
        ARCHS="arm64e"
        ;;
    *)
        DEFS="${DEFS} -DAPELIN_BOOTSTRAP_ROOTLESS=1"
        ARCHS="arm64 arm64e"
        ;;
esac

OBJ="${stage}/.obj"
mkdir -p "${OBJ}" "${stage}/Library/MobileSubstrate/DynamicLibraries"

# 1. tweak 本体
for arch in ${ARCHS}; do
    clang -arch "${arch}" -dynamiclib -fobjc-arc -fvisibility=hidden -O2 \
        -Werror=unguarded-availability-new \
        -I "${TWEAK_INC}" \
        ${DEFS} \
        -framework Foundation -framework UIKit \
        -Wl,-U,_MSHookMessageEx \
        Sources/Tweak.m \
        -o "${OBJ}/${TWEAK}.${arch}.dylib"
done
if [ "${ARCHS}" = "arm64e" ]; then
    cp "${OBJ}/${TWEAK}.arm64e.dylib" "${OBJ}/${TWEAK}.dylib"
else
    lipo -create -output "${OBJ}/${TWEAK}.dylib" \
        "${OBJ}/${TWEAK}.arm64.dylib" "${OBJ}/${TWEAK}.arm64e.dylib"
fi
ldid -S "${OBJ}/${TWEAK}.dylib"
cp "${OBJ}/${TWEAK}.dylib" "${stage}/Library/MobileSubstrate/DynamicLibraries/${TWEAK}.dylib"
cp "Resources/${TWEAK}.plist" "${stage}/Library/MobileSubstrate/DynamicLibraries/${TWEAK}.plist"

# 2. 设置面板（存在时才构建）
if [ -d Sources/Prefs ] && [ -d Resources/Bundle ]; then
    BUNDLE_DIR="${stage}/Library/PreferenceBundles/${BUNDLE}.bundle"
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
    if [ "${ARCHS}" = "arm64e" ]; then
        cp "${OBJ}/${BUNDLE}.arm64e" "${OBJ}/${BUNDLE}"
    else
        lipo -create -output "${OBJ}/${BUNDLE}" \
            "${OBJ}/${BUNDLE}.arm64" "${OBJ}/${BUNDLE}.arm64e"
    fi
    ldid -S "${OBJ}/${BUNDLE}"
    cp "${OBJ}/${BUNDLE}" "${BUNDLE_DIR}/${BUNDLE}"
    sed -e "s|@PACKAGE_ID@|${PKG_ID}|g" -e "s|@VERSION@|${VERSION}|g" \
        Resources/Bundle/Root.plist > "${BUNDLE_DIR}/Root.plist"
    sed -e "s|@PACKAGE_ID@|${PKG_ID}|g" -e "s|@VERSION@|${VERSION}|g" \
        Resources/Bundle/Info.plist > "${BUNDLE_DIR}/Info.plist"

    mkdir -p "${stage}/Library/PreferenceLoader/Preferences"
    cp Resources/Bundle/Entry.plist \
        "${stage}/Library/PreferenceLoader/Preferences/${BUNDLE}.plist"
fi

# 3. 打包
mkdir -p "${stage}/DEBIAN"
sed "s|@ARCH@|${APELIN_ARCHITECTURE}|" control > "${stage}/DEBIAN/control"
rm -rf -- "${OBJ:?}"
dpkg-deb -b --root-owner-group "${stage:?}" "${APELIN_PACKAGE_DIR:?}/"
