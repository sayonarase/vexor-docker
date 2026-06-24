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

# --- Make optional package-install steps fail fast on locked-down hosts -------
# Demo hosts often block external package mirrors (EPEL, InfluxData, Rocky).
# vexor-setup runs optional `dnf install` / `pip install` steps (polkit,
# nagios-plugins, impacket, jsonpath-ng) that would otherwise hang for minutes
# on metadata/PyPI timeouts before their `|| true` fallbacks kick in. Disable
# the external mirror repos at runtime (the image already bakes the packages it
# needs; updates ship as new images, not in-container dnf) and cap pip waits so
# those steps fail in seconds. Idempotent; re-applied every boot.
harden_network_failfast() {
    for f in /etc/yum.repos.d/*.repo; do
        case "$f" in
            *vexor*) ;;
            *) sed -i 's/^enabled=1/enabled=0/' "$f" 2>/dev/null || true ;;
        esac
    done
    export PIP_DEFAULT_TIMEOUT=5 PIP_RETRIES=0 PIP_NO_INPUT=1
}

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
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c48 > "$SKF" || true
        chmod 640 "$SKF"; chgrp vexor "$SKF" 2>/dev/null || true
    fi
    local SK; SK=$(cat "$SKF")
    local PUB; PUB=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^VEXOR_PUBLIC_URL=//p' | head -1) || true
    local CORS="${PUB:-https://localhost}"; CORS="${CORS%/}"
    sed -e "s|__DB_PASSWORD__|${VEXOR_DB_PASSWORD}|g" \
        -e "s|__SECRET_KEY__|${SK}|g" \
        -e "s|__CORS_ORIGINS__|${CORS}|g" \
        "$TPL" > "$ENVF"
    chown vexor:vexor "$ENVF" 2>/dev/null || true
    chmod 600 "$ENVF"
}

# --- Ensure Keycloak's Postgres DB is initialized + the realm is seeded -------
# PostgreSQL data now lives in a persisted volume (/var/lib/pgsql), but the
# container only enables/initializes postgres + seeds the Keycloak realm via
# vexor-setup, which is skipped on recreate. Initialize postgres (idempotent)
# and reseed the realm if it is missing (e.g. first boot on a fresh pg volume),
# so authentication survives image upgrades.
ensure_keycloak_db() {
    [ -x /usr/libexec/vexor/setup-postgres ] && /usr/libexec/vexor/setup-postgres >/dev/null 2>&1 || true
    # Force-align the keycloak Postgres role password with the persisted
    # /etc/vexor/keycloak.env value. On a fresh pg volume the role is recreated
    # and its password can diverge from the persisted KC_DB_PASSWORD, breaking
    # Keycloak's DB login ("password authentication failed for user keycloak").
    if [ -f /etc/vexor/keycloak.env ]; then
        local KP
        KP=$(grep '^KC_DB_PASSWORD=' /etc/vexor/keycloak.env | cut -d= -f2-)
        if [ -n "$KP" ]; then
            sudo -u postgres psql -tAc "ALTER ROLE keycloak WITH PASSWORD '$KP'" >/dev/null 2>&1 || true
            [ -f /opt/keycloak/conf/keycloak.conf ] && \
                sed -i "s|^db-password=.*|db-password=$KP|" /opt/keycloak/conf/keycloak.conf 2>/dev/null || true
        fi
    fi
    systemctl enable --now postgresql >/dev/null 2>&1 || true
    systemctl enable --now keycloak   >/dev/null 2>&1 || true
    [ -f /etc/vexor/keycloak.env ] || return 0
    local code=000 i
    for i in $(seq 1 45); do
        code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8180/auth/realms/master/.well-known/openid-configuration 2>/dev/null || echo 000)
        [ "$code" = "200" ] && break
        sleep 2
    done
    code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8180/auth/realms/vexor/.well-known/openid-configuration 2>/dev/null || echo 000)
    if [ "$code" != "200" ]; then
        echo "[vexor-firstboot] Keycloak realm 'vexor' missing (code=$code); reseeding via vexor-setup"
        rm -f /etc/vexor/.kc_realm_seeded
        vexor-setup --non-interactive || true
    fi
}


# --- Restore Naemon configs from the LKG mirror after a container recreate ----
# /etc/naemon (incl. the vexor-generated host/service .cfg files) is NOT a
# persisted volume, so a `docker compose pull && up -d` recreate wipes it. The
# DB still holds the hosts/services and vexor-api keeps a last-known-good mirror
# under /var/lib/vexor/naemon-lkg (which IS persisted). naemon's boot guard only
# restores the LKG when `naemon -v` FAILS, but an empty config dir verifies fine
# (0 objects), so the monitor would silently come up with no hosts/services.
# Detect that case and restore the persisted snapshot, then reload naemon.
ensure_naemon_configs() {
    local LIVE=/etc/naemon/vexor
    local TREE=/var/lib/vexor/naemon-lkg/tree
    local nlive nlkg
    nlive=$(find "$LIVE/hosts" -name '*.cfg' 2>/dev/null | wc -l)
    nlkg=$(find "$TREE$LIVE/hosts" -name '*.cfg' 2>/dev/null | wc -l)
    # Only act when the live dir is empty but the LKG mirror has a snapshot.
    if [ "$nlive" -gt 0 ] || [ "$nlkg" -eq 0 ]; then
        return 0
    fi
    echo "[vexor-firstboot] restoring $nlkg Naemon host configs from LKG mirror (live dir empty after recreate)"
    mkdir -p "$LIVE"/hosts "$LIVE"/services "$LIVE"/commands "$LIVE"/templates
    local sub f
    for sub in hosts services commands templates; do
        [ -d "$TREE$LIVE/$sub" ] && cp -f "$TREE$LIVE/$sub"/*.cfg "$LIVE/$sub"/ 2>/dev/null || true
    done
    for f in _servicedeps.cfg op5-commands.cfg; do
        [ -f "$TREE$LIVE/$f" ] && cp -f "$TREE$LIVE/$f" "$LIVE/$f" 2>/dev/null || true
    done
    [ -f "$TREE/etc/naemon/conf.d/vexor-custom-commands.cfg" ] && \
        cp -f "$TREE/etc/naemon/conf.d/vexor-custom-commands.cfg" /etc/naemon/conf.d/ 2>/dev/null || true
    [ -f "$TREE/etc/naemon/conf.d/vexor_timeperiods.cfg" ] && \
        cp -f "$TREE/etc/naemon/conf.d/vexor_timeperiods.cfg" /etc/naemon/conf.d/ 2>/dev/null || true
    chown -R vexor:naemon "$LIVE" 2>/dev/null || true
    systemctl reload naemon 2>/dev/null || systemctl restart naemon 2>/dev/null || true
}

# --- Provision the public-demo account + login hint (VEXOR_DEMO_MODE only) -----
# The Keycloak realm lives in Postgres (persisted volume), but a forced realm
# reseed drops the read-only `demo` user and the login-page credential hint.
# When the operator opts in via VEXOR_DEMO_MODE=1 (docker-compose .env), make
# both idempotent so the public demo keeps working across rebuilds/reseeds.
ensure_demo_account() {
    local DEMO
    DEMO=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^VEXOR_DEMO_MODE=//p' | head -1) || true
    case "${DEMO,,}" in 1|true|yes|on) ;; *) return 0 ;; esac
    [ -f /etc/vexor/keycloak.env ] || return 0
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8180/auth/realms/vexor/.well-known/openid-configuration 2>/dev/null || echo 000)
    [ "$code" = "200" ] || return 0
    echo "[vexor-firstboot] ensuring public demo account + login hint (VEXOR_DEMO_MODE)"
    python3 - <<'PYEOF' || true
import json, urllib.request, urllib.parse, urllib.error
BASE = "http://127.0.0.1:8180/auth"
def req(method, path, token=None, data=None, form=False):
    headers = {}; body = None
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode(); headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode(); headers["Content-Type"] = "application/json"
    if token: headers["Authorization"] = "Bearer " + token
    r = urllib.request.Request(BASE + path, data=body, headers=headers, method=method)
    try:
        resp = urllib.request.urlopen(r); return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
kc = {}
for l in open("/etc/vexor/keycloak.env"):
    l = l.strip()
    if "=" in l and not l.startswith("#"):
        k, v = l.split("=", 1); kc[k] = v
try:
    tok = json.loads(req("POST", "/realms/master/protocol/openid-connect/token", form=True, data={
        "grant_type": "password", "client_id": "admin-cli",
        "username": kc["KC_BOOTSTRAP_ADMIN_USERNAME"], "password": kc["KC_BOOTSTRAP_ADMIN_PASSWORD"]})[1])["access_token"]
except Exception as e:
    print("demo-account: admin auth failed:", e); raise SystemExit(0)
# login-page hint (theme uppercases #kc-header-wrapper -> override text-transform)
hint = ('<span style="text-transform:none;display:block;text-align:center;line-height:1.5">'
        '<b>Vexor Monitoring &mdash; Live Demo</b><br>'
        '<span style="font-size:13px;color:#888">Sign in with <b>demo</b> / <b>demo</b></span></span>')
print("realm:", req("PUT", "/admin/realms/vexor", token=tok, data={"realm": "vexor", "displayName": "Vexor", "displayNameHtml": hint})[0])
users = json.loads(req("GET", "/admin/realms/vexor/users?username=demo&exact=true", token=tok)[1])
if users:
    uid = users[0]["id"]
else:
    req("POST", "/admin/realms/vexor/users", token=tok, data={"username": "demo", "enabled": True,
        "emailVerified": True, "email": "demo@vexormon.com", "firstName": "Demo", "lastName": "User"})
    uid = json.loads(req("GET", "/admin/realms/vexor/users?username=demo&exact=true", token=tok)[1])[0]["id"]
print("password:", req("PUT", "/admin/realms/vexor/users/%s/reset-password" % uid, token=tok,
    data={"type": "password", "value": "demo", "temporary": False})[0])
have = {r["name"] for r in json.loads(req("GET", "/admin/realms/vexor/users/%s/role-mappings/realm" % uid, token=tok)[1])}
for bad in ("vexor-admin", "vexor-operator"):
    if bad in have:
        r = json.loads(req("GET", "/admin/realms/vexor/roles/%s" % bad, token=tok)[1])
        req("DELETE", "/admin/realms/vexor/users/%s/role-mappings/realm" % uid, token=tok, data=[{"id": r["id"], "name": r["name"]}])
if "vexor-viewer" not in have:
    viewer = json.loads(req("GET", "/admin/realms/vexor/roles/vexor-viewer", token=tok)[1])
    print("viewer:", req("POST", "/admin/realms/vexor/users/%s/role-mappings/realm" % uid, token=tok,
        data=[{"id": viewer["id"], "name": viewer["name"]}])[0])
print("demo-account: done")
PYEOF
}

SENTINEL=/etc/vexor/.docker-firstboot-done
mkdir -p /etc/vexor

# Always self-heal ephemeral runtime config (survives image upgrades).
harden_network_failfast
ensure_runtime_env
ensure_keycloak_db
ensure_naemon_configs
ensure_demo_account

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
    id=$($KC get clients -r vexor -q clientId=vexor-ui --fields id 2>/dev/null | grep -oE '[0-9a-f-]{36}' | head -1) || true
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
PUBLIC_URL=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^VEXOR_PUBLIC_URL=//p' | head -1) || true

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
