# Vexor — all-in-one container image
#
# This image reuses the exact same RPMs as the production Rocky Linux 10 install
# (installed from the public Vexor yum repo) and runs the whole stack under
# systemd inside one container. It does NOT modify, depend on, or risk any host
# install — it is a completely separate distribution path.
#
# Stack pulled in by the `vexor-server` meta package:
#   vexor-api, vexor-ui, vexor-naemon, vexor-keycloak, vexor-logs,
#   nginx, mariadb-server, influxdb2, java-21-openjdk-headless  (+ valkey below)
FROM quay.io/rockylinux/rockylinux:10

# systemd-as-PID-1 plumbing
ENV container=docker
STOPSIGNAL SIGRTMIN+3

# --- Install the full Vexor stack from the public repo -----------------------
# vexor-release configures the yum repo + imports the GPG key.
# valkey (Redis-compatible cache) is an optional companion of vexor-api; we add
# it explicitly to match the production install.
ARG VEXOR_RELEASE_RPM="https://repo.vexormon.com/vexor-release-latest-el10.rpm"
RUN dnf -y install "$VEXOR_RELEASE_RPM" \
 && dnf -y install vexor-server valkey sudo curl \
 && dnf -y clean all \
 && rm -rf /var/cache/dnf

# --- Boot to multi-user (no display manager in a container) -------------------
RUN ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target

# --- Forward the full external Host (incl. non-default port) to Keycloak -------
# Keycloak runs with proxy-headers=xforwarded and builds its public URLs
# (discovery, issuer, authorization_endpoint) from the forwarded Host header.
# The stock vexor-ui nginx conf forwards `$host` (which strips the port) plus a
# fixed `X-Forwarded-Port 443`, so when the container is published on a
# non-default external port (e.g. 8453) Keycloak emits URLs without the port and
# rejects the login `redirect_uri`. Forward `$http_host` instead (it carries
# host:port exactly as the browser sent it) and drop the fixed X-Forwarded-Port.
# This is a Docker-image-only tweak; it does not touch the host RPM install.
RUN sed -i '/location \/auth\//,/^    }/{ \
      s/proxy_set_header Host .*/proxy_set_header Host $http_host;/; \
      s/proxy_set_header X-Forwarded-Host .*/proxy_set_header X-Forwarded-Host $http_host;/; \
      /proxy_set_header X-Forwarded-Port/d; \
    }' /etc/nginx/conf.d/vexor.conf

# --- Enable services -----------------------------------------------------------
# `systemctl enable` is ignored during `docker build` (no PID 1 systemd), and the
# RPM %post presets are skipped for the same reason — so we wire the wants
# symlinks up by hand. All these units are WantedBy=multi-user.target.
RUN mkdir -p /etc/systemd/system/multi-user.target.wants \
 && for u in mariadb postgresql influxdb valkey keycloak nginx naemon vexor-api vexor-vector; do \
      if [ -f "/usr/lib/systemd/system/$u.service" ]; then \
        ln -sf "/usr/lib/systemd/system/$u.service" \
               "/etc/systemd/system/multi-user.target.wants/$u.service"; \
      fi; \
    done

# --- First-boot bootstrap: runs `vexor-setup` exactly once -------------------
COPY firstboot.sh /usr/local/sbin/vexor-firstboot.sh
COPY vexor-firstboot.service /etc/systemd/system/vexor-firstboot.service
RUN sed -i 's/\r$//' /usr/local/sbin/vexor-firstboot.sh \
                     /etc/systemd/system/vexor-firstboot.service \
 && chmod 755 /usr/local/sbin/vexor-firstboot.sh \
 && chmod 644 /etc/systemd/system/vexor-firstboot.service \
 && ln -sf /etc/systemd/system/vexor-firstboot.service \
           /etc/systemd/system/multi-user.target.wants/vexor-firstboot.service

# --- Drop units that are meaningless / harmful inside a container ------------
RUN systemctl mask \
      systemd-machine-id-commit.service \
      systemd-remount-fs.service \
      dev-hugepages.mount \
      sys-fs-fuse-connections.mount \
    2>/dev/null || true

EXPOSE 80 443
# Persist state across container re-creation (see docker-compose.yml).
VOLUME ["/var/lib/mysql", "/var/lib/influxdb", "/var/lib/naemon", \
        "/var/lib/vexor", "/etc/vexor", "/opt/keycloak/data"]

# Readiness probe: vexor-api /healthz returns 503 when the database is down.
HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1

CMD ["/sbin/init"]
