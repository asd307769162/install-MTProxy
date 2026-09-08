#!/usr/bin/env bash
set -Eeuo pipefail

# One-command entry point for the enhanced multi-user Telemt installer.
# Files are kept in /opt/telemt so rerunning the command updates the same install.

REPOSITORY_RAW_URL="${REPOSITORY_RAW_URL:-https://raw.githubusercontent.com/asd307769162/install-MTProxy/main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/telemt}"
INSTALLER_NAME="telemt-from-image-mu.sh"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "[ERROR] Please run this installer as root." >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || {
        echo "[ERROR] curl is required and apt-get is unavailable." >&2
        exit 1
    }
    apt-get update -y
    apt-get install -y curl ca-certificates
fi

mkdir -p "$INSTALL_DIR"
tmp_installer=$(mktemp "$INSTALL_DIR/.telemt-installer.XXXXXX")
trap 'rm -f "$tmp_installer"' EXIT

curl -fL --retry 3 --connect-timeout 10 \
    "$REPOSITORY_RAW_URL/$INSTALLER_NAME" \
    -o "$tmp_installer"

[ -s "$tmp_installer" ] || {
    echo "[ERROR] Downloaded installer is empty." >&2
    exit 1
}

if [ -f "$INSTALL_DIR/$INSTALLER_NAME" ]; then
    cp -a "$INSTALL_DIR/$INSTALLER_NAME" "$INSTALL_DIR/$INSTALLER_NAME.bak"
fi

install -m 0755 "$tmp_installer" "$INSTALL_DIR/$INSTALLER_NAME"
rm -f "$tmp_installer"
trap - EXIT
cd "$INSTALL_DIR"
exec "./$INSTALLER_NAME"
