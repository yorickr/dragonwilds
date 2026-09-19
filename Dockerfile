# Local build of the official RuneScape: Dragonwilds dedicated server (Steam app
# 4019830), installed at runtime via anonymous SteamCMD.
FROM debian:bookworm-slim

ARG STEAMCMD_URL=https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
ARG IMAGE_SOURCE=https://github.com/yorickr/dragonwilds

LABEL org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.description="Dedicated server for RuneScape: Dragonwilds, with idle auto-pause." \
      org.opencontainers.image.licenses="MIT"

# SteamCMD is a 32-bit binary; the server's crash reporter needs libcurl4.
# curl is also used by the auto-pause watcher's optional AUTO_PAUSE_PLAYERS_URL.
# hadolint ignore=DL3008
RUN dpkg --add-architecture i386 \
    && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl tar \
        libcurl4 lib32gcc-s1 libc6:i386 libstdc++6:i386 \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/steamcmd \
    && curl -fsSL -o /opt/steamcmd/steamcmd_linux.tar.gz "${STEAMCMD_URL}" \
    && tar -xzf /opt/steamcmd/steamcmd_linux.tar.gz -C /opt/steamcmd \
    && rm /opt/steamcmd/steamcmd_linux.tar.gz

# UID 1000 so bind-mounted data directories are owned by the usual first host user.
RUN useradd -m -u 1000 -U steam \
    && chown -R steam:steam /opt/steamcmd

# hadolint ignore=DL3066  # 'steam' is created above with a fixed uid 1000
USER steam
WORKDIR /home/steam

COPY --chown=steam:steam entrypoint.sh /home/steam/entrypoint.sh
RUN chmod +x /home/steam/entrypoint.sh

# Metadata only — SERVER_PORT is configurable and the published port is what matters.
EXPOSE 7777/udp
ENTRYPOINT ["/home/steam/entrypoint.sh"]
