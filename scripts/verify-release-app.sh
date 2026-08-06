#!/bin/zsh
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: scripts/verify-release-app.sh /path/to/Trackify.app <version> <build>" >&2
  exit 2
fi

app="${1:A}"
expected_version="$2"
expected_build="$3"
info="${app}/Contents/Info.plist"
app_binary="${app}/Contents/MacOS/TrackifyMac"
cli="${app}/Contents/SharedSupport/trackify"

if [[ "${app:t}" != "Trackify.app" || ! -f "${info}" || ! -x "${app_binary}" || ! -x "${cli}" ]]; then
  echo "The release app bundle is incomplete." >&2
  exit 1
fi

value() { /usr/libexec/PlistBuddy -c "Print :$1" "${info}"; }
[[ "$(value CFBundleIdentifier)" == "com.zoulabs.trackify" ]]
[[ "$(value CFBundleShortVersionString)" == "${expected_version}" ]]
[[ "$(value CFBundleVersion)" == "${expected_build}" ]]
[[ "$(value TrackifyInstallationOrigin)" == "direct" ]]
[[ "$(value SUPublicEDKey)" != "UNCONFIGURED" ]]

for binary in "${app_binary}" "${cli}"; do
  architectures=$(/usr/bin/lipo -archs "${binary}")
  [[ " ${architectures} " == *" arm64 "* && " ${architectures} " == *" x86_64 "* ]]
done

/usr/bin/codesign --verify --deep --strict --verbose=2 "${app}"
team_id=$(/usr/bin/codesign -dvv "${app}" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2}')
[[ "${team_id}" == "PNTJNS22UU" ]]
/usr/sbin/spctl --assess --type execute --verbose=2 "${app}"
/usr/bin/xcrun stapler validate "${app}"
[[ "$("${cli}" --version)" == "${expected_version}" ]]
[[ "$("${cli}" update status --json | /usr/bin/plutil -extract origin raw -o - -)" == "direct" ]]
