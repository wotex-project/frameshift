FROM ubuntu@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
ARG TARGETARCH
ARG FIXTURE_ERL_FLAGS
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libtinfo6 libstdc++6 libgcc-s1 libssl3t64 libsctp1 netbase zlib1g util-linux systemd binutils && rm -rf /var/lib/apt/lists/*
COPY root/ /
COPY fixtures/ /fixtures/
RUN groupadd frameshift && groupadd frameshift-control && groupadd frameshift-observer && useradd --system --gid frameshift --groups frameshift-control,frameshift-observer --home-dir /var/lib/frameshift --shell /usr/sbin/nologin frameshift && useradd --system --user-group --groups frameshift-control,frameshift-observer --shell /usr/sbin/nologin frame-control && useradd --system --user-group --groups frameshift-observer --shell /usr/sbin/nologin frame-observer && useradd --system --user-group --shell /usr/sbin/nologin frame-denied
RUN chmod 646 /usr/lib/frameshift/policy.sh; /usr/lib/frameshift/provision-runtime; test "$?" = 69 && test "$(stat -c '%a' /usr/lib/frameshift/policy.sh)" = 646 && chmod 644 /usr/lib/frameshift/policy.sh
# This switch changes only disposable emulation fixtures, never the staged artifact.
RUN case "$FIXTURE_ERL_FLAGS" in ''|'+JMsingle true') ;; *) exit 64 ;; esac; if [ -n "$FIXTURE_ERL_FLAGS" ]; then sed -i "s/ERL_FLAGS='/ERL_FLAGS='$FIXTURE_ERL_FLAGS /" /usr/lib/frameshift/launch-service /usr/bin/frameshiftctl /usr/bin/frameshift-identity; fi
RUN systemd-analyze verify /usr/lib/systemd/system/frameshift.service
ENV ERL_FLAGS=${FIXTURE_ERL_FLAGS} LANG=C.UTF-8
CMD ["/fixtures/check-closure"]
