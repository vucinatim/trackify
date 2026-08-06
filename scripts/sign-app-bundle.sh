#!/bin/zsh
set -euo pipefail

if [[ "$#" -ne 1 || ! -d "$1" ]]; then
  echo "usage: TRACKIFY_SIGNING_IDENTITY='Developer ID Application: …' scripts/sign-app-bundle.sh /path/to/Trackify.app" >&2
  exit 2
fi
if [[ -z "${TRACKIFY_SIGNING_IDENTITY:-}" ]]; then
  echo "TRACKIFY_SIGNING_IDENTITY is required." >&2
  exit 2
fi

app="${1:A}"
project_root="${0:A:h:h}"
framework="${app}/Contents/Frameworks/Sparkle.framework"
sparkle_version="${framework}/Versions/B"
cli="${app}/Contents/SharedSupport/trackify"

if [[ "${app:t}" != "Trackify.app" || ! -d "${framework}" || ! -x "${cli}" ]]; then
  echo "The bundle is missing its expected Trackify or Sparkle components." >&2
  exit 1
fi

sign_nested() {
  /usr/bin/codesign \
    --force \
    --sign "${TRACKIFY_SIGNING_IDENTITY}" \
    --timestamp \
    --options runtime \
    --preserve-metadata=identifier,entitlements,requirements,flags \
    "$1"
}

sign_nested "${sparkle_version}/XPCServices/Downloader.xpc"
sign_nested "${sparkle_version}/XPCServices/Installer.xpc"
sign_nested "${sparkle_version}/Updater.app"
sign_nested "${sparkle_version}/Autoupdate"
sign_nested "${framework}"

/usr/bin/codesign \
  --force \
  --sign "${TRACKIFY_SIGNING_IDENTITY}" \
  --timestamp \
  --options runtime \
  --identifier com.zoulabs.trackify.cli \
  "${cli}"

/usr/bin/codesign \
  --force \
  --sign "${TRACKIFY_SIGNING_IDENTITY}" \
  --timestamp \
  --options runtime \
  --entitlements "${project_root}/Apps/TrackifyMac/Trackify.entitlements" \
  "${app}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${app}"
