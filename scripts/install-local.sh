#!/bin/zsh
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  echo "usage: scripts/install-local.sh /path/to/Trackify.app [--launch]" >&2
  exit 2
fi

source_app="${1:A}"
launch="${2:-}"
install_home="${TRACKIFY_INSTALL_HOME:-${HOME}}"
target_root="${install_home}/Applications"
target_app="${target_root}/Trackify.app"
link_root="${install_home}/.local/bin"
cli_link="${link_root}/trackify"
expected_cli="${target_app}/Contents/SharedSupport/trackify"

if [[ ! -d "${source_app}" || "${source_app:t}" != "Trackify.app" ]]; then
  echo "The source must be a Trackify.app bundle." >&2
  exit 2
fi
if [[ "${launch}" != "" && "${launch}" != "--launch" ]]; then
  echo "The only optional argument is --launch." >&2
  exit 2
fi
if [[ "$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)" -lt 14 ]]; then
  echo "Trackify requires macOS 14 or later." >&2
  exit 1
fi

info="${source_app}/Contents/Info.plist"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info}" 2>/dev/null || true)
origin=$(/usr/libexec/PlistBuddy -c 'Print :TrackifyInstallationOrigin' "${info}" 2>/dev/null || true)
if [[ "${bundle_id}" != "com.zoulabs.trackify" || ! -x "${source_app}/Contents/SharedSupport/trackify" ]]; then
  echo "The bundle identity or bundled CLI is invalid." >&2
  exit 1
fi

if [[ "${origin}" == "direct" ]]; then
  /usr/bin/codesign --verify --deep --strict --verbose=2 "${source_app}"
  public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${info}" 2>/dev/null || true)
  if [[ -z "${public_key}" || "${public_key}" == "UNCONFIGURED" ]]; then
    echo "The direct release does not contain a configured Sparkle update key." >&2
    exit 1
  fi
elif [[ "${origin}" != "development" || "${TRACKIFY_ALLOW_UNSIGNED:-0}" != "1" ]]; then
  echo "Only verified direct releases are installable. Set TRACKIFY_ALLOW_UNSIGNED=1 only for a local development build." >&2
  exit 1
fi

if [[ -e "${cli_link}" || -L "${cli_link}" ]]; then
  if [[ ! -L "${cli_link}" || "$(/usr/bin/readlink "${cli_link}")" != */Trackify.app/Contents/SharedSupport/trackify ]]; then
    echo "Refusing to replace unrelated file at ${cli_link}." >&2
    exit 1
  fi
fi

/bin/mkdir -p "${target_root}" "${link_root}"
staging_root=$(/usr/bin/mktemp -d "${target_root}/.trackify-install.XXXXXX")
trap '[[ "${staging_root}" == "${target_root}/.trackify-install."* ]] && /bin/rm -rf "${staging_root}"' EXIT
staging_app="${staging_root}/Trackify.app"
/usr/bin/ditto "${source_app}" "${staging_app}"

/usr/bin/osascript -e 'tell application id "com.zoulabs.trackify" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  /usr/bin/pgrep -x TrackifyMac >/dev/null 2>&1 || break
  /bin/sleep 0.25
done
if /usr/bin/pgrep -x TrackifyMac >/dev/null 2>&1; then
  echo "Trackify did not quit; installation was not changed." >&2
  exit 1
fi

if [[ -e "${target_app}" ]]; then
  backup="${target_root}/Trackify.app.previous"
  if [[ -e "${backup}" ]]; then
    /bin/rm -rf "${backup}"
  fi
  /bin/mv "${target_app}" "${backup}"
  echo "Previous app preserved at ${backup}."
fi
/bin/mv "${staging_app}" "${target_app}"
/bin/ln -sfn "${expected_cli}" "${cli_link}"

"${expected_cli}" doctor
echo "Installed Trackify at ${target_app}."
echo "CLI: ${cli_link}"
if [[ ":${PATH}:" != *":${link_root}:"* ]]; then
  echo "Add ${link_root} to PATH if your shell does not already include it. No shell file was changed."
fi
if [[ "${launch}" == "--launch" ]]; then
  /usr/bin/open "${target_app}"
fi
