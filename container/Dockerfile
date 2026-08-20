# syntax=docker/dockerfile:1

FROM docker.io/qemux/qemu:7.32

# ============================================
# Expose Web UI (noVNC)
# ============================================
ENV SUPPORT="https://github.com/gawindx/pfVEdge"
EXPOSE 8006

# ============================================
# Core runtime config
# ============================================
# Disable internal networking (we inject TAP later)
ENV NETWORK="N"

# Boot image
# may be overriden for newer version downloaded from pfSense account
ENV BOOT="https://repo.ialab.dsu.edu/pfsense/pfSense-CE-memstick-2.7.2-RELEASE-amd64.img.gz"

# VM resources (overridable)
ENV DISK_SIZE="10G"
ENV RAM_SIZE="4G"
ENV CPU_CORES="1"

# ============================================
# TAP INJECTION SUPPORT
# ============================================
# Custom TAP handling
COPY ./src/start.sh /run/start.sh

# ============================================
# HEALTHCHECK
# ============================================
RUN mkdir -p /healthcheck
COPY ./src/healthcheck/ /healthcheck/

# Optional: ensure scripts executable
RUN chmod +x /run/start.sh \
    && chmod +x /healthcheck/healthcheck.sh \
    && chmod +x /healthcheck/watchdog.sh

# ============================================
# Logging & debug (optional but useful)
# ============================================

#ENV QEMU_LOG=""

# ============================================
# Entrypoint (UPSTREAM PRESERVED)
# ============================================
ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]