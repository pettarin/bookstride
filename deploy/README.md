# Deploying the Bookstride server with systemd

This directory packages the Bookstride server for production as a
**systemd user service** behind an **nginx TLS reverse proxy**. The
server is the Rocket app in [`../server`](../server): it proxies the
libro.fm API for the Connect IQ watch app, listening on plain HTTP at
`127.0.0.1:8000` while nginx terminates TLS on 443 and forwards to it.

Both hostnames are served by the same instance:

- `https://bookstride.nettek.ca/` — production (what the watch app points at)
- `https://bookstride-beta.nettek.ca/` — also accepted, same backend

Files:

| file | purpose |
| --- | --- |
| `bookstride.service` | systemd *user* unit |
| `env.example` | tunables, copied to `~/.config/bookstride/env` |
| `install.sh` | one-time install: build, app dir, unit, lingering, **and the nginx reverse proxy + Let's Encrypt cert** |
| `update.sh` | rebuild from the repo and restart (installed as `bookstride-update`) |
| `nginx/bookstride.nettek.ca.conf` | nginx site: `https://…/` -> `http://127.0.0.1:8000`, http -> https |
| `nginx/bookstride.nettek.ca.http-only.conf` | temporary HTTP-only site for the initial Let's Encrypt challenge |

Unlike a registry-published service, Bookstride is **built from source
on the host** from this checkout. `install.sh` and `update.sh` run
`cargo build --release` and copy the binary plus the `client/` assets
into the app directory.

## What goes where

| path | contents |
| --- | --- |
| `~/.local/share/bookstride/server` | the built binary (the unit's `ExecStart`) |
| `~/.local/share/bookstride/client/` | static assets served by the app |
| `~/.local/share/bookstride/bookstride_srv.sqlite` | the app's SQLite DB (auto-created; the unit's `WorkingDirectory` is this folder) |
| `~/.config/bookstride/env` | tunables (`ROCKET_ADDRESS`, log level) |
| `~/.config/systemd/user/bookstride.service` | the unit |
| `~/.local/bin/bookstride-update` | symlink to `deploy/update.sh` |

## No secrets on the host

The server holds **no application secrets**: it forwards each user's
libro.fm username/password at request time (the OAuth password grant)
and stores none — there is no libro.fm client ID/secret to keep. The
only secret on the box is the Let's Encrypt account key, managed by
certbot under `/etc/letsencrypt`. That's why `env.example` is installed
world-readable and contains only tunables.

## Prerequisites on the host

- **Rust** (rustup) and **cargo**, for the release build.
- **systemd** with a user manager (default on most distros).
- **sudo**, for the nginx + certbot steps (skip with `--no-nginx`).
- At least one of the hostnames (`bookstride.nettek.ca`,
  `bookstride-beta.nettek.ca`) pointing at this box **before** running
  install with nginx — certbot validates over HTTP. install.sh includes
  in the cert only the names that currently resolve here and skips the
  rest (see [Staged rollout](#staged-rollout-beta-first-apex-later)).

## Install

```sh
# From the checkout on the host:
cd bookstride/deploy
./install.sh --email you@example.org
```

This builds the server, installs it, sets up the nginx proxy, and issues
one certificate covering both names. It **enables** the service but does
not start it, so you can review the config first:

```sh
$EDITOR ~/.config/bookstride/env      # optional
systemctl --user start bookstride.service
journalctl --user -u bookstride.service -f
```

Flags:

- `--no-nginx` — build + service only (e.g. you run your own proxy).
- `--domain` / `--beta-domain` — override the two hostnames.
- `--email` (or `$CERTBOT_EMAIL`) — Let's Encrypt registration address.

## Staged rollout (beta first, apex later)

You can bring the box up on `bookstride-beta.nettek.ca` while
`bookstride.nettek.ca` still points at the old host, then cut the apex
over once you're happy.

A Let's Encrypt certificate is **all-or-nothing**: every name in the
cert must pass its own HTTP-01 challenge, so bundling a name that
doesn't yet point here would fail the *whole* request. install.sh avoids
that by requesting a cert only for the names that currently resolve to
this box, under a **fixed lineage** (`--cert-name bookstride`, so the
path is always `/etc/letsencrypt/live/bookstride/`).

1. **Now** — with only beta's DNS pointing here:
   ```sh
   ./install.sh --email you@example.org
   ```
   It warns that `bookstride.nettek.ca` doesn't resolve here, skips it,
   and issues a cert for `bookstride-beta.nettek.ca` only. nginx serves
   both `server_name`s; the apex one just gets no traffic yet. Test away
   at `https://bookstride-beta.nettek.ca/`.

2. **Later** — point `bookstride.nettek.ca` at this box, wait for
   propagation, then re-run the same command:
   ```sh
   ./install.sh --email you@example.org
   ```
   Now both resolve, so certbot **expands** the same `bookstride` cert to
   cover the apex. nginx's cert path is unchanged. (Equivalently, by
   hand: `sudo certbot certonly --webroot -w /var/www/html --cert-name
   bookstride -d bookstride-beta.nettek.ca -d bookstride.nettek.ca
   --expand && sudo systemctl reload nginx`.)

Re-running with an unchanged, not-yet-due cert is a no-op, so it won't
burn the duplicate-certificate rate limit. If a challenge does fail
repeatedly (e.g. DNS not propagated), Let's Encrypt's *failed
validation* limit is per-hostname-per-hour and resets on its own — just
wait it out rather than hammering.

## Firewall (external reach)

The app binds `127.0.0.1:8000`, so it isn't directly reachable from the
network — but still lock the box down to only the ports you expose. The
intended external surface is **ssh (22/tcp), http (80/tcp), https
(443/tcp)**; the app's `8000/tcp` stays loopback-only (nginx reaches it
over 127.0.0.1, which firewalld does not filter).

On Fedora (firewalld):

```sh
sudo systemctl enable --now firewalld
ZONE=$(firewall-cmd --get-default-zone)

# Apply to runtime first (reversible), test a FRESH ssh session, then commit.
sudo firewall-cmd --zone=$ZONE --add-service=ssh
sudo firewall-cmd --zone=$ZONE --add-service=http
sudo firewall-cmd --zone=$ZONE --add-service=https
sudo firewall-cmd --zone=$ZONE --remove-port=8000/tcp   # if it ever leaked

# Verify from ANOTHER machine: 8000 refuses, 443/80/22 open.
sudo firewall-cmd --runtime-to-permanent
sudo firewall-cmd --reload
```

If the host is a VPS, check the provider's network firewall / security
group too — that's often the real boundary.

## Updating

After pulling new code (or letting the script pull for you):

```sh
bookstride-update            # git pull --ff-only, rebuild, reinstall, restart
bookstride-update --no-pull  # build exactly what's checked out
```

A plain `systemctl --user restart bookstride.service` just re-runs the
already-installed binary; only `bookstride-update` rebuilds.

## Notes

- **Binding.** Rocket defaults to `127.0.0.1`, and `env` pins
  `ROCKET_ADDRESS=127.0.0.1` explicitly so it can't drift. The listen
  port is fixed at 8000 by the app itself.
- **Audio cache.** The server extracts downloaded tracks to
  `/tmp/bookstride_cache_*.mp3`. The unit sets uses a private tmp
  so restarting wipes everything.
- **SELinux.** `install.sh` labels `tcp/8000` as `http_port_t` so nginx
  (running as `httpd_t`) is allowed to proxy to it under enforcing mode.
- **A single instance serves both hostnames.** If you later want the
  beta name to run a *separate* build, split it into its own service on
  another port with its own `server` block; today they share one
  backend.
