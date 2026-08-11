#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="${TRACKIFY_VERSION:-0.3.0-dev}"
build_number="${TRACKIFY_BUILD_NUMBER:-1}"
public_key="${TRACKIFY_SPARKLE_PUBLIC_KEY:-UNCONFIGURED}"
installation_origin="${TRACKIFY_INSTALLATION_ORIGIN:-development}"
architectures="${TRACKIFY_ARCHITECTURES:-universal}"
development_signing_identity="${TRACKIFY_DEVELOPMENT_SIGNING_IDENTITY:--}"
output_root="${1:-${project_root}/.build/bundle}"
app_path="${output_root}/Trackify.app"

if [[ -z "${output_root}" || "${output_root}" == "/" || "${output_root}" == "${HOME}" || "${app_path}" != */Trackify.app ]]; then
  echo "Refusing unsafe bundle output path: ${app_path}" >&2
  exit 2
fi
if [[ "${installation_origin}" != "direct" && "${installation_origin}" != "homebrew" && "${installation_origin}" != "managed" && "${installation_origin}" != "development" ]]; then
  echo "TRACKIFY_INSTALLATION_ORIGIN must be direct, homebrew, managed, or development." >&2
  exit 2
fi

cd "${project_root}"
if [[ "${architectures}" == "universal" ]]; then
  arm_scratch="${project_root}/.build/arm64"
  intel_scratch="${project_root}/.build/x86_64"
  swift build -c release --product TrackifyMac --triple arm64-apple-macosx14.0 --scratch-path "${arm_scratch}"
  swift build -c release --product trackify --triple arm64-apple-macosx14.0 --scratch-path "${arm_scratch}"
  swift build -c release --product TrackifyMac --triple x86_64-apple-macosx14.0 --scratch-path "${intel_scratch}"
  swift build -c release --product trackify --triple x86_64-apple-macosx14.0 --scratch-path "${intel_scratch}"
  arm_bin=$(swift build -c release --show-bin-path --triple arm64-apple-macosx14.0 --scratch-path "${arm_scratch}")
  intel_bin=$(swift build -c release --show-bin-path --triple x86_64-apple-macosx14.0 --scratch-path "${intel_scratch}")
elif [[ "${architectures}" == "native" ]]; then
  swift build -c release --product TrackifyMac
  swift build -c release --product trackify
  native_bin=$(swift build -c release --show-bin-path)
else
  echo "TRACKIFY_ARCHITECTURES must be 'universal' or 'native'." >&2
  exit 2
fi

mkdir -p "${output_root}"
staging_root=$(mktemp -d "${output_root}/.trackify-bundle.XXXXXX")
staging_app="${staging_root}/Trackify.app"
mkdir -p "${staging_app}/Contents/MacOS" "${staging_app}/Contents/Resources" "${staging_app}/Contents/SharedSupport" "${staging_app}/Contents/Frameworks"
if [[ "${architectures}" == "universal" ]]; then
  lipo -create "${arm_bin}/TrackifyMac" "${intel_bin}/TrackifyMac" -output "${staging_app}/Contents/MacOS/TrackifyMac"
  lipo -create "${arm_bin}/trackify" "${intel_bin}/trackify" -output "${staging_app}/Contents/SharedSupport/trackify"
  sparkle_framework="${arm_bin}/Sparkle.framework"
else
  cp "${native_bin}/TrackifyMac" "${staging_app}/Contents/MacOS/TrackifyMac"
  cp "${native_bin}/trackify" "${staging_app}/Contents/SharedSupport/trackify"
  sparkle_framework="${native_bin}/Sparkle.framework"
fi
cp "${project_root}/assets/branding/Trackify.icns" "${staging_app}/Contents/Resources/Trackify.icns"
ditto "${sparkle_framework}" "${staging_app}/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "${staging_app}/Contents/MacOS/TrackifyMac"

# SwiftPM may add a machine-specific compatibility rpath for binary artifacts.
# Release binaries use the system Swift runtime and bundled frameworks only.
for binary in "${staging_app}/Contents/MacOS/TrackifyMac" "${staging_app}/Contents/SharedSupport/trackify"; do
  while IFS= read -r rpath; do
    if [[ "${rpath}" == /*/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-*/* ]]; then
      install_name_tool -delete_rpath "${rpath}" "${binary}"
    fi
  done < <(otool -l "${binary}" | awk '/cmd LC_RPATH/{getline; getline; if (!seen[$2]++) print $2}')
done
sed \
  -e "s/__VERSION__/${version}/g" \
  -e "s/__BUILD__/${build_number}/g" \
  -e "s/__SPARKLE_PUBLIC_KEY__/${public_key}/g" \
  -e "s/__INSTALLATION_ORIGIN__/${installation_origin}/g" \
  "${project_root}/Apps/TrackifyMac/Info.plist.template" > "${staging_app}/Contents/Info.plist"
chmod 755 "${staging_app}/Contents/MacOS/TrackifyMac" "${staging_app}/Contents/SharedSupport/trackify"

if [[ "${installation_origin}" == "development" ]]; then
  codesign --force --sign "${development_signing_identity}" --identifier com.zoulabs.trackify.cli "${staging_app}/Contents/SharedSupport/trackify"
  codesign \
    --force \
    --sign "${development_signing_identity}" \
    --entitlements "${project_root}/Apps/TrackifyMac/Trackify.entitlements" \
    "${staging_app}"
  codesign --verify --deep --strict "${staging_app}"
fi

if [[ -e "${app_path}" ]]; then
  /bin/rm -rf "${app_path}"
fi
mv "${staging_app}" "${app_path}"

echo "Built ${app_path}"
