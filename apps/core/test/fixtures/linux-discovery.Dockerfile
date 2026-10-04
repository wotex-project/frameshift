# Software discovery fixture, not an Ubuntu application/release image.
FROM elixir@sha256:3898ffe18d695e770239e4b342dc6b83136f52da0a37df2298083c03068cfd4e

# Retain archive signatures while disabling expiry only for this dated snapshot.
RUN printf '%s\n' 'deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian/20260930T000000Z trixie main' > /etc/apt/sources.list \
    && rm -f /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        avahi-utils=0.8-16 avahi-daemon=0.8-16 dbus=1.16.2-2 \
        libavahi-client3=0.8-16 libavahi-common3=0.8-16 \
    && rm -rf /var/lib/apt/lists/*
