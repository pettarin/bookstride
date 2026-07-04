#!/usr/bin/env bash
# install.sh — one-time setup for a Bookstride host.
#
# Builds the Rocket server from this checkout and runs it as a systemd
# *user* service behind an nginx TLS reverse proxy.
#
# User-level (no root needed):
#   1. Builds server/ in release mode.
#   2. Installs the binary + client/ assets into ~/.local/share/bookstride
#      (the service's working directory; the SQLite DB lives here too).
#   3. Installs ~/.config/bookstride/env from env.example (without
#      overwriting an existing one) and the systemd user unit.
#   4. Symlinks the update script to ~/.local/bin/bookstride-update.
#   5. Enables lingering + enables (but does not start) the service.
#
# System-level (uses sudo; skip with --no-nginx):
#   6. Installs nginx + certbot, issues a Let's Encrypt certificate for
#      whichever of the hostnames currently resolve to this box (webroot),
#      and installs the nginx site that proxies https://<host>/ to
#      http://127.0.0.1:8000. Also labels tcp/8000 for SELinux so nginx
#      (httpd_t) may proxy to it.
#
# Staged rollout: the cert uses a fixed lineage name (--cert-name,
# default 'bookstride'), so you can bring up beta first (only its DNS
# live) and later, once the apex DNS points here, re-run install.sh to
# expand the same cert to cover it — nginx's cert path never changes.
#
# There are no application secrets: the server forwards each user's
# libro.fm credentials at request time and stores none. The only secret
# on the host is the Let's Encrypt account key (managed by certbot).
#
# Prereqs on the host: rustup/cargo, a systemd user manager, and sudo
# for the nginx/certbot steps. See deploy/README.md.
#
# Usage:
#   ./install.sh --email you@example.org
#   ./install.sh --email you@example.org --domain bookstride.nettek.ca \
#                --beta-domain bookstride-beta.nettek.ca
#   ./install.sh --no-nginx            # build + service only, no proxy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_DIR="$REPO_ROOT/server"

CONFIG_DIR="${HOME}/.config/bookstride"
UNIT_DIR="${HOME}/.config/systemd/user"
APP_DIR="${HOME}/.local/share/bookstride"
LOCAL_BIN="${HOME}/.local/bin"

# --- args ---
DOMAIN="bookstride.nettek.ca"
BETA_DOMAIN="bookstride-beta.nettek.ca"
CERT_NAME="bookstride"
WEBROOT="/var/www/html"
EMAIL=""
INSTALL_NGINX=1
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2;;
    --beta-domain) BETA_DOMAIN="$2"; shift 2;;
    --cert-name) CERT_NAME="$2"; shift 2;;
    --webroot) WEBROOT="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --no-nginx) INSTALL_NGINX=0; shift;;
    -h|--help)
      sed -n '2,/^set -euo pipefail$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1;;
  esac
done

echo "==> Sanity-checking prerequisites"
command -v cargo >/dev/null || { echo "ERROR: cargo not found. Install rustup." >&2; exit 1; }
command -v systemctl >/dev/null || { echo "ERROR: systemctl not found." >&2; exit 1; }
if [ "$INSTALL_NGINX" -eq 1 ]; then
  command -v sudo >/dev/null || { echo "ERROR: sudo not found (needed for nginx/certbot)." >&2; exit 1; }
  if [ -z "$EMAIL" ] && [ -z "${CERTBOT_EMAIL:-}" ]; then
    echo "ERROR: --email (or \$CERTBOT_EMAIL) is required for Let's Encrypt." >&2
    echo "       Use --no-nginx to skip reverse-proxy setup." >&2
    exit 1
  fi
  EMAIL="${EMAIL:-$CERTBOT_EMAIL}"
fi

echo "==> Building the server (release)"
cargo build --release --manifest-path "$SERVER_DIR/Cargo.toml"

echo "==> Installing binary + client assets into $APP_DIR"
mkdir -p "$APP_DIR"
# Rename into place so an already-running binary (ETXTBSY) can't block
# the copy; the running process keeps the old inode until restart.
install -m 755 "$SERVER_DIR/target/release/server" "$APP_DIR/server.new"
mv -f "$APP_DIR/server.new" "$APP_DIR/server"
rm -rf "$APP_DIR/client"
cp -a "$SERVER_DIR/client" "$APP_DIR/client"

echo "==> Installing configuration, unit, and update command"
mkdir -p "$CONFIG_DIR" "$UNIT_DIR" "$LOCAL_BIN"
if [ ! -f "${CONFIG_DIR}/env" ]; then
  install -m 644 "${SCRIPT_DIR}/env.example" "${CONFIG_DIR}/env"
  echo "    wrote ${CONFIG_DIR}/env (from env.example)"
else
  echo "    ${CONFIG_DIR}/env already exists, not overwriting"
fi
install -m 644 "${SCRIPT_DIR}/bookstride.service" "${UNIT_DIR}/bookstride.service"
ln -sf "${SCRIPT_DIR}/update.sh" "${LOCAL_BIN}/bookstride-update"

echo "==> Enabling lingering so the user service runs at boot"
loginctl enable-linger "$USER" 2>/dev/null || loginctl enable-linger 2>/dev/null || {
  echo "WARN: could not enable lingering. Run: loginctl enable-linger \$USER" >&2
}

echo "==> Reloading the user manager and enabling the service"
systemctl --user daemon-reload
systemctl --user enable bookstride.service

if [ "$INSTALL_NGINX" -eq 1 ]; then
  echo "==> Installing nginx reverse proxy for ${DOMAIN} (+ ${BETA_DOMAIN})"
  NGINX_DIR="/etc/nginx/conf.d"
  CONF_NAME="bookstride.nettek.ca.conf"
  CERT_DIR="/etc/letsencrypt/live/${CERT_NAME}"

  echo "    installing nginx, certbot, and policycoreutils (for SELinux labels)"
  sudo dnf install -y nginx certbot policycoreutils-python-utils

  # SELinux: nginx runs as httpd_t and may only connect to ports labeled
  # http_port_t. tcp/8000 is not labeled by default, so
  # proxy_pass http://127.0.0.1:8000 would be silently denied under
  # enforcing mode. Label it.
  if command -v getenforce >/dev/null && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    echo "    SELinux enforcing: labeling tcp/8000 as http_port_t"
    sudo semanage port -a -t http_port_t -p tcp 8000 2>/dev/null \
      || sudo semanage port -m -t http_port_t -p tcp 8000 2>/dev/null \
      || echo "WARN: could not label port 8000 (already labeled? check: sudo semanage port -l | grep 8000)" >&2
  fi

  sudo mkdir -p "$WEBROOT"
  # nginx must be able to read the webroot for the ACME challenge.
  sudo chcon -R -t httpd_sys_content_t "$WEBROOT" 2>/dev/null || true

  render_conf() {  # $1 = template path, $2 = dest
    sed -e "s|@@DOMAIN@@|${DOMAIN}|g" \
        -e "s|@@BETA_DOMAIN@@|${BETA_DOMAIN}|g" \
        -e "s|@@CERT_NAME@@|${CERT_NAME}|g" "$1" \
      | sudo tee "$2" >/dev/null
  }

  # Request a cert only for the names that currently resolve to this box.
  # Let's Encrypt validates every name in a cert order and fails the whole
  # order if any one can't be reached, so including a not-yet-pointed name
  # (e.g. the apex during a staged rollout) would sink the beta cert too.
  # Skipping it now and re-running later — certbot expands the same
  # --cert-name lineage — keeps nginx's cert path stable throughout.
  echo "    checking which of ${DOMAIN}, ${BETA_DOMAIN} resolve to this box"
  box_ips="$( { hostname -I 2>/dev/null || true; \
                curl -fsS4 https://ifconfig.co 2>/dev/null || true; \
                curl -fsS6 https://ifconfig.co 2>/dev/null || true; } \
              | tr ' ' '\n' | sort -u | grep -v '^$' || true)"
  cert_domains=()
  for d in "$DOMAIN" "$BETA_DOMAIN"; do
    [ -n "$d" ] || continue
    resolved="$(getent ahosts "$d" | awk '{print $1}' | sort -u || true)"
    hit=0
    for ip in $resolved; do
      if grep -qx "$ip" <<<"$box_ips"; then hit=1; break; fi
    done
    if [ "$hit" -eq 1 ]; then
      echo "    ${d} -> $(echo "$resolved" | tr '\n' ' ') (including in the cert)"
      cert_domains+=("$d")
    else
      echo "WARN: ${d} does not resolve to this box yet — SKIPPING it in the cert." >&2
      echo "      Re-run install.sh once its DNS points here to add it." >&2
    fi
  done
  if [ "${#cert_domains[@]}" -eq 0 ]; then
    echo "ERROR: none of the requested names resolve to this box; cannot issue a cert." >&2
    echo "       Point at least one at this box (see deploy/README.md) and re-run," >&2
    echo "       or use --no-nginx to skip the reverse proxy for now." >&2
    exit 1
  fi

  # First issuance needs the HTTP-only site so certbot can validate over
  # port 80. On later runs the full config is already serving the ACME
  # challenge location, so validation works against it directly.
  if [ ! -d "$CERT_DIR" ]; then
    echo "    installing HTTP-only site so certbot can validate"
    render_conf "${SCRIPT_DIR}/nginx/bookstride.nettek.ca.http-only.conf" \
                "${NGINX_DIR}/${CONF_NAME}"
    sudo systemctl enable --now nginx
    sudo nginx -t
    sudo systemctl reload nginx
  fi

  d_args=()
  for d in "${cert_domains[@]}"; do d_args+=(-d "$d"); done
  echo "    issuing/expanding cert '${CERT_NAME}' for: ${cert_domains[*]}"
  # --cert-name pins the lineage (stable /etc/letsencrypt/live path);
  # --expand adds newly-resolving names to it. Idempotent: an unchanged,
  # not-yet-due cert is left alone (no wasted issuance / duplicate-cert
  # rate-limit hit).
  sudo certbot certonly --webroot -w "$WEBROOT" --cert-name "$CERT_NAME" "${d_args[@]}" \
    --expand --non-interactive --agree-tos --no-eff-email -m "$EMAIL" \
    --deploy-hook "systemctl reload nginx"

  echo "    installing full site config (HTTPS + proxy + redirect)"
  render_conf "${SCRIPT_DIR}/nginx/bookstride.nettek.ca.conf" \
              "${NGINX_DIR}/${CONF_NAME}"
  sudo nginx -t
  sudo systemctl enable --now nginx
  sudo systemctl reload nginx

  echo "    enabling certbot renewal timer"
  # Fedora ships it as certbot-renew.timer; Debian/Ubuntu as certbot.timer.
  if systemctl cat certbot-renew.timer >/dev/null 2>&1; then
    sudo systemctl enable --now certbot-renew.timer
    echo "    enabled certbot-renew.timer"
  elif systemctl cat certbot.timer >/dev/null 2>&1; then
    sudo systemctl enable --now certbot.timer
    echo "    enabled certbot.timer"
  else
    echo "WARN: no certbot renewal timer found (neither certbot-renew.timer" >&2
    echo "       nor certbot.timer). Schedule 'certbot renew' yourself." >&2
  fi
fi

cat <<EOF

==> All set. Next steps:

  1. (Optional) tweak the config:
       \$EDITOR ${CONFIG_DIR}/env

  2. Start the server now (auto-starts at boot from now on):
       systemctl --user start bookstride.service

  3. Watch the logs:
       journalctl --user -u bookstride.service -f

  4. Later, to rebuild from the repo and restart in one shot:
       bookstride-update
EOF
if [ "$INSTALL_NGINX" -eq 1 ]; then
  cat <<EOF

  5. Reverse proxy is up for the names now in the cert
     (${cert_domains[*]}), each -> 127.0.0.1:8000.
     Verify (from elsewhere, once the service is started), using a name
     whose DNS points here:
       curl -i https://${cert_domains[0]}/     # expect 200 (the login page)
       curl -i http://${cert_domains[0]}/      # expect 301 -> https
     Renewals are automatic via the certbot renewal timer; nginx reloads on renew.

     When you later point another name (e.g. ${DOMAIN}) at this box,
     just re-run install.sh — it expands the same '${CERT_NAME}' cert to
     cover it, with no nginx changes.

  6. Lock the box down (see deploy/README.md): expose only 22/80/443 and
     keep tcp/8000 loopback-only — the proxy reaches it over 127.0.0.1.
EOF
fi
