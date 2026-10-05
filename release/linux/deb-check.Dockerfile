FROM ubuntu@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
ARG FIXTURE_ERL_FLAGS
COPY archives/ /archives/
# Install actual declared dependency alternatives/ranges; no caller language toolchain.
RUN apt-get update && apt-get install -y --no-install-recommends /archives/*fixture1*.deb util-linux binutils && rm -rf /var/lib/apt/lists/*
# Only this disposable image is reset after qualifying first-install dependencies
# and account creation. Install again at runtime so state is not an overlay lower
# directory (which forbids the fixture's directory-rename refusal probe).
RUN dpkg --purge frameshift && rm -rf /var/lib/frameshift /run/frameshift /var/backups/frameshift
COPY fixtures/ /fixtures/
RUN useradd --system --user-group --groups frameshift-control,frameshift-observer --shell /usr/sbin/nologin frame-control && useradd --system --user-group --groups frameshift-observer --shell /usr/sbin/nologin frame-observer && useradd --system --user-group --shell /usr/sbin/nologin frame-denied
# Change only this disposable emulation fixture, not any DEB bytes.
RUN case "$FIXTURE_ERL_FLAGS" in ''|'+JMsingle true') ;; *) exit 64 ;; esac
ENV ERL_FLAGS=${FIXTURE_ERL_FLAGS} LANG=C.UTF-8
CMD ["/fixtures/check-deb"]
