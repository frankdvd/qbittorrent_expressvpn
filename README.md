expressvpn_docker

This repository contains Docker artifacts to run ExpressVPN in a container and
route other containers (for example qBittorrent) through the VPN.

What this repo contains
- `Dockerfile` - builds an Ubuntu 24.04-based image, installs the ExpressVPN
  universal installer and provides an entrypoint script. The image also
  contains a HEALTHCHECK which verifies the `expressvpnctl status` shows
  "Connected".
- `entrypoint.sh` - starts and monitors the ExpressVPN daemon, performs
  activation (when `EXPRESSVPN_ACTIVATION_CODE` is provided), connects the VPN,
  and runs a background monitor that will attempt automatic reconnection. If
  the container cannot reconnect within a configurable timeout (default 240s),
  it will exit with a non-zero status so orchestrators can handle the failure.
- `docker-compose.yaml` - example compose configuration that runs `expressvpn`,
  `qbittorrent` (using `network_mode: service:expressvpn`) and a small socat
  proxy for the qBittorrent web UI.

License

This project is released under the MIT License. See `LICENSE` for details.

Important notes and next steps

- Remove or replace the placeholder for `EXPRESSVPN_ACTIVATION_CODE` in
  `docker-compose.yaml` before using. Do NOT commit private activation codes to
  a public repository; use environment variables or secret management instead.
- The default reconnect timeout is controlled by the `RECONNECT_TIMEOUT`
  environment variable (seconds). Default: 240 (4 minutes). You can increase or
  decrease it depending on your tolerance for connectivity interruptions.
