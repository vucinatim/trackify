#!/bin/zsh
set -euo pipefail

if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--delete-data" ) ]]; then
  echo "usage: scripts/uninstall-local.sh [--delete-data]" >&2
  exit 2
fi

delete_data="${1:-}"
install_home="${TRACKIFY_INSTALL_HOME:-${HOME}}"
target_app="${install_home}/Applications/Trackify.app"
cli_link="${install_home}/.local/bin/trackify"
data_root="${install_home}/Library/Application Support/Trackify"
trash_root="${install_home}/.Trash"
stamp=$(/bin/date +%Y%m%d%H%M%S)

/usr/bin/open 'trackify://uninstall/prepare' >/dev/null 2>&1 || \
  /usr/bin/osascript -e 'tell application id "com.zoulabs.trackify" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  /usr/bin/pgrep -x TrackifyMac >/dev/null 2>&1 || break
  /bin/sleep 0.25
done
if /usr/bin/pgrep -x TrackifyMac >/dev/null 2>&1; then
  echo "Trackify did not quit; uninstall was not changed." >&2
  exit 1
fi

/bin/mkdir -p "${trash_root}"
if [[ -d "${target_app}" ]]; then
  /bin/mv "${target_app}" "${trash_root}/Trackify.app.uninstalled.${stamp}"
fi
if [[ -L "${cli_link}" && "$(/usr/bin/readlink "${cli_link}")" == */Trackify.app/Contents/SharedSupport/trackify ]]; then
  /bin/mv "${cli_link}" "${trash_root}/trackify-cli-link.uninstalled.${stamp}"
elif [[ -e "${cli_link}" || -L "${cli_link}" ]]; then
  echo "Left unrelated file at ${cli_link} untouched." >&2
fi

if [[ "${delete_data}" == "--delete-data" && -d "${data_root}" ]]; then
  /bin/mv "${data_root}" "${trash_root}/Trackify-data.uninstalled.${stamp}"
  echo "Application data was moved to Trash and remains recoverable until Trash is emptied."
else
  echo "Application data was preserved at ${data_root}."
fi
echo "Trackify was moved to Trash."
