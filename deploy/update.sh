#!/usr/bin/env bash
# bookstride-update — rebuild the Bookstride server from this checkout
# and restart the service so it picks up the new binary and client
# assets. Safe to re-run.
#
# install.sh symlinks this to ~/.local/bin/bookstride-update, so the
# command always operates on the repo it was installed from. You can
# also run it directly: deploy/update.sh
#
# By default it first fast-forwards the checkout (git pull --ff-only);
# pass --no-pull to build exactly what's checked out.
set -euo pipefail

# Resolve through the symlink so we find the real repo, not ~/.local/bin.
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_DIR="$REPO_ROOT/server"
APP_DIR="${HOME}/.local/share/bookstride"
SERVICE=bookstride.service

PULL=1
[ "${1:-}" = "--no-pull" ] && PULL=0

if [ "$PULL" -eq 1 ] && [ -d "$REPO_ROOT/.git" ]; then
  echo "==> Updating the checkout (git pull --ff-only)"
  git -C "$REPO_ROOT" pull --ff-only \
    || echo "WARN: git pull --ff-only failed; building the current checkout" >&2
fi

echo "==> Building the server (release)"
cargo build --release --manifest-path "$SERVER_DIR/Cargo.toml"

echo "==> Installing binary + client assets into $APP_DIR"
mkdir -p "$APP_DIR"
# Rename into place: you can't overwrite a running executable in-place
# (ETXTBSY), but renaming over it is fine — the old inode lives on in the
# running process until the restart below.
install -m 755 "$SERVER_DIR/target/release/server" "$APP_DIR/server.new"
mv -f "$APP_DIR/server.new" "$APP_DIR/server"
rm -rf "$APP_DIR/client"
cp -a "$SERVER_DIR/client" "$APP_DIR/client"

echo "==> Restarting ${SERVICE}"
systemctl --user restart "$SERVICE"

echo "==> Done. Status:"
systemctl --user status --no-pager "$SERVICE" || true
