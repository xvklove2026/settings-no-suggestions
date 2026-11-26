#!/bin/sh
set -eu
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_PACKAGE_DIR:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}" "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}"
cd "${APELIN_PROJECT_ROOT:?}"
[ -s cloud-cache/expected-source.txt ] || { echo 'Cloud source commit is not configured' >&2; exit 1; }
icli probe apelin/fetch-cloud.js
stage="$(mktemp -d "${TMPDIR:?}cloud-stage.XXXXXX")"
trap 'rm -rf -- "${stage:?}"' EXIT
mkdir -p "${stage}/input"
unzip -q "cloud-cache/${APELIN_BOOTSTRAP}.zip" -d "${stage}/input"
(cd "${stage}/input" && sha256sum -c SHA256SUMS)
DEST="${stage}${APELIN_PREFIX}"
TWEAK=APSNoSuggestions
BUNDLE=APSNoSuggestionsPrefs
PKG_ID="$(sed -n 's/^Package:[[:space:]]*//p' control)"
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' control)"
[ -n "$PKG_ID" ] && [ -n "$VERSION" ]
mkdir -p "${DEST}/Library/MobileSubstrate/DynamicLibraries" "${DEST}/Library/PreferenceBundles/${BUNDLE}.bundle" "${DEST}/Library/PreferenceLoader/Preferences" "${stage}/DEBIAN"
ldid -S "${stage}/input/${TWEAK}.dylib"
ldid -S "${stage}/input/${BUNDLE}"
cp "${stage}/input/${TWEAK}.dylib" "${DEST}/Library/MobileSubstrate/DynamicLibraries/${TWEAK}.dylib"
cp "Resources/${TWEAK}.plist" "${DEST}/Library/MobileSubstrate/DynamicLibraries/${TWEAK}.plist"
printf '%s\n' "$APELIN_BUILD_ID" > "${DEST}/Library/MobileSubstrate/DynamicLibraries/${TWEAK}.build-id"
BD="${DEST}/Library/PreferenceBundles/${BUNDLE}.bundle"
cp "${stage}/input/${BUNDLE}" "${BD}/${BUNDLE}"
for plist in Root Info; do
  sed -e "s|@PACKAGE_ID@|${PKG_ID}|g" -e "s|@VERSION@|${VERSION}|g" "Resources/Bundle/${plist}.plist" > "${BD}/${plist}.plist"
done
cp Resources/Bundle/icon.png Resources/Bundle/icon@2x.png Resources/Bundle/icon@3x.png "${BD}/"
cp Resources/Bundle/Entry.plist "${DEST}/Library/PreferenceLoader/Preferences/${BUNDLE}.plist"
sed "s|@ARCH@|${APELIN_ARCHITECTURE}|" control > "${stage}/DEBIAN/control"
rm -rf -- "${stage:?}/input"
dpkg-deb -b --root-owner-group "${stage:?}" "${APELIN_PACKAGE_DIR:?}/"
