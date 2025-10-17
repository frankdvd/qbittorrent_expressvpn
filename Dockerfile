# Based on Ubuntu 24.04
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

ARG EXPRESSVPN_RUN_URL="https://www.expressvpn.works/clients/linux/expressvpn-linux-universal-4.1.1.10039.run"
ENV EXPRESSVPN_RUN_URL=${EXPRESSVPN_RUN_URL}

# Install dependencies, download and run the ExpressVPN installer, then clean up
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        wget sudo ca-certificates libxkbcommon-x11-0 libnl-3-200 libnl-route-3-200 iptables psmisc libatomic1 libopengl0 xterm libglib2.0-0 libglib2.0-bin iproute2; \
    wget -O /tmp/expressvpn.run "$EXPRESSVPN_RUN_URL"; \
    chmod +x /tmp/expressvpn.run; \
    /tmp/expressvpn.run --target /tmp/ --noexec --keep; \
    sed -i '/if \[\[ \$EUID -eq 0 \]\]/,/fi/d' /tmp/x64/install.sh; \
    echo "y" | /tmp/x64/install.sh --skip-service; \
    rm -f /tmp/expressvpn.run; \
    rm -rf /tmp/x64 /tmp/*expressvpn*; \
    apt-get purge -y --auto-remove; \
    rm -rf /var/lib/apt/lists/* /tmp/*

# Set entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]


# Healthcheck: ensure the socket reports Connected
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD /opt/expressvpn/bin/expressvpnctl status | grep -q "Connected" || exit 1
