#!/bin/zsh
set -euo pipefail

install_home="${TRACKIFY_INSTALL_HOME:-${HOME}}"
target_app="${install_home}/Applications/Trackify.app"
target_cli="${target_app}/Contents/SharedSupport/trackify"
link_root="${install_home}/.local/bin"
cli_link="${link_root}/trackify"

if [[ ! -d "${target_app}" || ! -x "${target_cli}" ]]; then
  echo "Trackify is not installed correctly at ${target_app}; reinstall from a verified bundle." >&2
  exit 1
fi
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${target_app}/Contents/Info.plist" 2>/dev/null || true)
if [[ "${bundle_id}" != "com.zoulabs.trackify" ]]; then
  echo "Refusing to repair a bundle with an unexpected identity." >&2
  exit 1
fi
if [[ -e "${cli_link}" || -L "${cli_link}" ]]; then
  if [[ ! -L "${cli_link}" || "$(/usr/bin/readlink "${cli_link}")" != */Trackify.app/Contents/SharedSupport/trackify ]]; then
    echo "Refusing to replace unrelated file at ${cli_link}." >&2
    exit 1
  fi
fi

/bin/mkdir -p "${link_root}"
/bin/ln -sfn "${target_cli}" "${cli_link}"
"${target_cli}" doctor
echo "Trackify application and CLI link are healthy."
