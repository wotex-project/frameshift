FROM ubuntu@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55 AS package
ARG PACKAGE_REVISION
RUN apt-get update && apt-get install -y --no-install-recommends dpkg-dev binutils libtinfo6 libstdc++6 libgcc-s1 libssl3t64 libsctp1 zlib1g && rm -rf /var/lib/apt/lists/*
COPY root /runtime/root
COPY linux /linux
COPY packaging-inputs.json /packaging-inputs.json
RUN /linux/make-deb "$PACKAGE_REVISION"
FROM scratch AS artifact
COPY --from=package /out/ /
