#!/bin/bash
set -euo pipefail
cd "${GITHUB_WORKSPACE:?}"
: "${BOOTSTRAP:?}" "${GITHUB_SHA:?}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="cloud-out/${BOOTSTRAP}"
mkdir -p "$OUT"
PKG_ID="$(sed -n 's/^Package:[[:space:]]*//p' control)"
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' control)"
DEFS=(-DAPELIN_PACKAGE_ID="\"${PKG_ID}\"" -DAPELIN_VERSION="\"${VERSION}\"" -DAPELIN_BUILD_ID="\"cloud-${GITHUB_SHA}\"")
if [[ "$BOOTSTRAP" == roothide ]]; then DEFS+=(-DAPELIN_BOOTSTRAP_ROOTHIDE=1); else DEFS+=(-DAPELIN_BOOTSTRAP_ROOTLESS=1); fi
for ARCH in arm64 arm64e; do
  COMMON=(-target "${ARCH}-apple-ios16.0" -isysroot "$SDK" -fobjc-arc -fvisibility=hidden -O2 -I apelin/cloud-include -include apelin/cloud-include/CloudBuildMarker.h)
  xcrun clang "${COMMON[@]}" "${DEFS[@]}" -dynamiclib Sources/Tweak.m Sources/SpringBoard.m -framework Foundation -framework UIKit -Wl,-U,_MSHookMessageEx -o "$OUT/tweak.$ARCH"
  xcrun clang "${COMMON[@]}" "${DEFS[@]}" -bundle Sources/Prefs/*.m -framework Foundation -framework UIKit '-Wl,-U,_OBJC_CLASS_$_PSListController' '-Wl,-U,_OBJC_METACLASS_$_PSListController' '-Wl,-U,_OBJC_IVAR_$_PSListController._specifiers' '-Wl,-U,_OBJC_CLASS_$_PSSpecifier' -o "$OUT/prefs.$ARCH"
done
xcrun lipo -create "$OUT/tweak.arm64" "$OUT/tweak.arm64e" -output "$OUT/APSNoSuggestions.dylib"
xcrun lipo -create "$OUT/prefs.arm64" "$OUT/prefs.arm64e" -output "$OUT/APSNoSuggestionsPrefs"
cd "$OUT"
shasum -a 256 APSNoSuggestions.dylib APSNoSuggestionsPrefs > SHA256SUMS
zip "../${BOOTSTRAP}.zip" APSNoSuggestions.dylib APSNoSuggestionsPrefs SHA256SUMS
