# Software discovery fixture, not an Ubuntu application/release image.
FROM hexpm/elixir@sha256:4a42b164d952ef56c135c1626f2174ab1a2780cd6fafd65b04d6e1590dfbd516

# Retain archive signatures while disabling expiry only for this dated snapshot.
RUN printf '%s\n' 'deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian/20260930T000000Z trixie main' > /etc/apt/sources.list \
    && rm -f /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        avahi-utils=0.8-16 avahi-daemon=0.8-16 dbus=1.16.2-2 \
        libavahi-client3=0.8-16 libavahi-common3=0.8-16 \
    && rm -rf /var/lib/apt/lists/*
