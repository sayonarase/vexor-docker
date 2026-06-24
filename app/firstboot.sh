#!/bin/bash
# Vexor container first-boot bootstrap.
#
# Runs once per persistent volume set. Waits for MariaDB to come up, then runs
# the standard non-interactive setup (DB schema, Keycloak realm, admin user,
# bundled trial license). A sentinel in the persisted /etc/vexor prevents it
# from running again on subsequent boots.
set -euo pipefail

# systemd oneshot units start with no HOME; vexor-setup reads $HOME under
# `set -u`. Define it defensively so the script works regardless of caller.
export HOME="${HOME:-/root}"

# --- Self-heal ephemeral runtime config on EVERY boot ------------------------
# /opt/vexor/api/.env and /var/backups live in the container's writable layer
# (NOT in a persisted volume). When the container is recreated on a newer image
# (docker compose pull && up -d), they are lost, while the firstboot sentinel in
# the /etc/vexor volume makes vexor-setup skip regenerating them -> vexor-api
# fails (missing DATABASE_URL/SECRET_KEY, or ReadWritePaths=/var/backups mount
# error). Rebuild them idempotently from the persisted /etc/vexor secrets so the
# stack survives image upgrades. SECRET_KEY is persisted in /etc/vexor (volume)
# so tokens stay valid across recreations.
ensure_runtime_env() {
    # 1) backup target dir referenced by vexor-api.service ReadWritePaths
    mkdir -p /var/backups/vexor/keycloak
    chown -R vexor:vexor /var/backups 2>/dev/null || true
    chmod 0750 /var/backups /var/backups/vexor 2>/dev/null || true

    # 2) /opt/vexor/api/.env — regenerate if missing or incomplete
    local ENVF=/opt/vexor/api/.env
    local TPL=/opt/vexor/api/.env.template
    [ -f /etc/vexor/db.env ] || return 0
    [ -f "$TPL" ] || return 0
    if [ -f "$ENVF" ] && grep -q '^DATABASE_URL=' "$ENVF" && grep -q '^SECRET_KEY=' "$ENVF"; then
        return 0
    fi
    echo "[vexor-firstboot] regenerating $ENVF from persisted secrets"
    . /etc/vexor/db.env
    local SKF=/etc/vexor/secret_key
    if [ ! -s "$SKF" ]; then
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c48 > "$SKF"
        chmod 640 "$SKF"; chgrp vexor "$SKF" 2>/dev/null || true
    fi
    local SK; SK=$(cat "$SKF")
    local PUB; PUB=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^VEXOR_PUBLIC_URL=//p' | head -1)
    local CORS="${PUB:-https://localhost}"; CORS="${CORS%/}"
    sed -e "s|__DB_PASSWORD__|${VEXOR_DB_PASSWORD}|g" \
        -e "s|__SECRET_KEY__|${SK}|g" \
        -e "s|__CORS_ORIGINS__|${CORS}|g" \
        "$TPL" > "$ENVF"
    chown vexor:vexor "$ENVF" 2>/dev/null || true
    chmod 600 "$ENVF"
}


SENTINEL=/etc/vexor/.docker-firstboot-done
mkdir -p /etc/vexor

# Always self-heal ephemeral runtime config (survives image upgrades).
ensure_runtime_env

# --- Register the operator's external URL with Keycloak ----------------------
# vexor-setup only registers internal hostnames/IPs (vexor, localhost, the
# container IP) as valid vexor-ui redirect URIs. When testers reach the
# container through some other host:port, the browser sends a redirect_uri that
# Keycloak doesn't recognise ("Invalid parameter: redirect_uri"). The operator
# declares the externally reachable URL via VEXOR_PUBLIC_URL (docker-compose
# .env); add it to the vexor-ui client so login works out of the box.
#
# This is idempotent and runs on every invocation (even after the one-shot
# setup), so changing VEXOR_PUBLIC_URL and re-running this script re-registers.
register_public_url() {
    local url="${1%/}"
    [ -n "$url" ] || return 0
    # localhost is already covered by the stock setup; nothing to add.
    case "$url" in
        https://localhost|http://localhost) return 0 ;;
    esac
    [ -f /etc/vexor/keycloak.env ] || return 0
    . /etc/vexor/keycloak.env
    local KC="sudo -u keycloak HOME=/opt/keycloak /opt/keycloak/bin/kcadm.sh"
    if ! $KC config credentials --server http://127.0.0.1:8180/auth --realm master \
            --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1; then
        echo "[vexor-firstboot] WARN: could not authenticate to Keycloak; skipping redirect-URI registration"
        return 0
    fi
    local id
    id=$($KC get clients -r vexor -q clientId=vexor-ui --fields id 2>/dev/null | grep -oE '[0-9a-f-]{36}' | head -1)
    if [ -z "$id" ]; then
        echo "[vexor-firstboot] WARN: vexor-ui client not found; skipping redirect-URI registration"
        return 0
    fi
    $KC get clients/"$id" -r vexor --fields redirectUris,webOrigins > /tmp/vexor-kc-cur.json 2>/dev/null || return 0
    VEXOR_PUBLIC_URL="$url" python3 - <<'PY'
import json, os
cur = json.load(open('/tmp/vexor-kc-cur.json'))
u = os.environ['VEXOR_PUBLIC_URL'].rstrip('/')
ru = set(cur.get('redirectUris') or [])
wo = set(cur.get('webOrigins') or [])
ru.add(u + '/*')
wo.add(u)
json.dump({'redirectUris': sorted(ru), 'webOrigins': sorted(wo)},
          open('/tmp/vexor-kc-new.json', 'w'))
PY
    if $KC update clients/"$id" -r vexor -f /tmp/vexor-kc-new.json; then
        echo "[vexor-firstboot] registered $url with the Keycloak vexor-ui client"
    fi
    rm -f /tmp/vexor-kc-cur.json /tmp/vexor-kc-new.json
}

# systemd oneshot units start with an empty environment, so read the value the
# operator set in docker-compose (.env) straight from PID 1's (systemd's) env.
PUBLIC_URL=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^VEXOR_PUBLIC_URL=//p' | head -1)

if [ -f "$SENTINEL" ]; then
    echo "[vexor-firstboot] setup already completed; re-checking external URL only."
    [ -n "$PUBLIC_URL" ] && register_public_url "$PUBLIC_URL"
    exit 0
fi

echo "[vexor-firstboot] waiting for MariaDB ..."
for _ in $(seq 1 60); do
    if mysqladmin --protocol=socket ping >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

echo "[vexor-firstboot] running vexor-setup --non-interactive ..."
vexor-setup --non-interactive

if [ -n "$PUBLIC_URL" ]; then
    echo "[vexor-firstboot] external URL: $PUBLIC_URL"
    register_public_url "$PUBLIC_URL"
fi

touch "$SENTINEL"
echo "[vexor-firstboot] done. Initial admin credentials: /etc/vexor/.initial-admin"
