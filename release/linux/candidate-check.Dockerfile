FROM ubuntu@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
ARG EXPECTED_VERSION
ARG FIXTURE_ERL_FLAGS
COPY archive/ /archive/
RUN apt-get update && apt-get install -y --no-install-recommends /archive/*.deb util-linux binutils && rm -rf /var/lib/apt/lists/*
# Reset only this disposable image's empty lower-layer state; product purge retains it.
RUN dpkg --purge frameshift && rm -rf /var/lib/frameshift /run/frameshift /var/backups/frameshift
COPY fixtures/ /fixtures/
RUN useradd --system --user-group --groups frameshift-control,frameshift-observer --shell /usr/sbin/nologin frame-control && useradd --system --user-group --groups frameshift-observer --shell /usr/sbin/nologin frame-observer && useradd --system --user-group --shell /usr/sbin/nologin frame-denied
RUN case "$FIXTURE_ERL_FLAGS" in ''|'+JMsingle true') ;; *) exit 64 ;; esac
ENV ERL_FLAGS=${FIXTURE_ERL_FLAGS} FRAMESHIFT_FIXTURE_VERSION=${EXPECTED_VERSION} LANG=C.UTF-8
CMD ["/fixtures/check-candidate"]
