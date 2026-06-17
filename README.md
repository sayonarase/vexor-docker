# Vexor — Docker distribution (alternative install path)

This is a **separate, self-contained project**. It packages the full Vexor
monitoring stack as a Docker image so it can run on any Linux host with Docker
(Ubuntu, Debian, etc.), *in addition to* the officially supported Rocky Linux /
RHEL 10 RPM install.

> It does **not** touch, depend on, or risk any existing host install. The image
> simply installs the **same published RPMs** from the public Vexor yum repo
> inside a container and runs them under systemd.

## What's inside

One image runs the whole stack (same components as the Rocky 10 install):

| Component | Role |
|-----------|------|
| `vexor-api` (gunicorn) | REST API, writes Naemon config, licensing |
| `vexor-ui` + `nginx` | Web UI + TLS / reverse proxy (ports 80/443) |
| `naemon` | Monitoring engine |
| `keycloak` (java-21) | Authentication / OIDC (LDAP/AD connect) |
| `mariadb` | Config, state, SLA data |
| `influxdb2` | Performance data / graphs |
| `valkey` | Cache / sessions |

The components are installed by the `vexor-server` meta package and managed by
systemd inside the container — exactly as on a real install.

## Quick start

```bash
cp .env.example .env       # edit VEXOR_PUBLIC_URL if needed
docker compose up -d
docker compose logs -f vexor
```

First boot runs `vexor-setup --non-interactive` automatically (DB schema,
Keycloak realm, admin user, bundled trial license). Grab the initial admin
credentials:

```bash
docker compose exec vexor cat /etc/vexor/.initial-admin
```

Then open `https://<host>/`.

### Reaching it on a custom host / port (important)

Login goes through Keycloak, which only trusts redirect URLs it knows about. Set
**`VEXOR_PUBLIC_URL`** in `.env` to the exact URL testers use in the browser —
**including the port** if you publish on anything other than 443:

```bash
# .env
VEXOR_PUBLIC_URL=https://monitor.example.com        # default 443
# or
VEXOR_PUBLIC_URL=https://192.168.1.50:8453          # custom port
```

On first boot this URL is registered with Keycloak automatically, and nginx
forwards the real `Host` (with port) so Keycloak's discovery/redirects stay
correct. Without it you'll get `Invalid parameter: redirect_uri` at login.
If you change `VEXOR_PUBLIC_URL` after first boot, re-register it with:

```bash
docker compose exec vexor /usr/local/sbin/vexor-firstboot.sh   # no-op-safe
```
(or recreate with fresh volumes: `docker compose down -v && docker compose up -d`).

## Hosting the image

Images are published to **GitHub Container Registry (ghcr.io)** — free for
public images — via `.github/workflows/build-images.yml`:

```
ghcr.io/sayonarase/vexor:latest
```

No need to self-host a registry. (Docker Hub works too but has anonymous pull
rate limits; ghcr.io does not.)

## Notes & caveats

- **systemd in a container** requires `privileged: true` + `cgroup: host`
  (already set in `docker-compose.yml`). This is the price of reusing the exact
  same tested RPM/systemd stack rather than re-implementing each service.
- **ICMP checks** (ping / `check_icmp`) need `NET_RAW` (already granted). To
  monitor a whole LAN easily you can switch the service to `network_mode: host`.
- **Building inside a repo mirror's own LAN:** if you build the image on the
  same private network as a self-hosted repo that relies on hairpin NAT, you may
  need an `/etc/hosts` entry mapping the repo hostname to its internal IP. Builds
  from the internet (e.g. GitHub Actions) and plain image pulls are unaffected.
- **Data persistence:** MariaDB, InfluxDB, Naemon, `/etc/vexor` (incl. license)
  and Keycloak data are stored in named volumes; recreating the container keeps
  your data and skips the first-boot setup.

## Relationship to the RPM install

This project intentionally lives outside the `vexor-rpm` / `vexor-api` repos.
Changes here never affect the Rocky 10 packaging or any running install. The
image is a *consumer* of the public RPMs, nothing more.
