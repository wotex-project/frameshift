# Portable locked BEAM code joined to freshly compiled Linux native closure.
ARG CODEC_IMAGE=frameshift-codec-arm64:fixture
FROM elixir@sha256:3898ffe18d695e770239e4b342dc6b83136f52da0a37df2298083c03068cfd4e AS runtime
FROM ${CODEC_IMAGE} AS native
USER 0
COPY --from=runtime /usr/local/lib/erlang/usr/include /otp-include
COPY exile /transport/exile
COPY native-codec-worker.c /transport/native-codec-worker.c
RUN make -C /transport/exile all ERL_INTERFACE_INCLUDE_DIR=/otp-include \
    && cc -std=c99 -Wall -Wextra -Werror /transport/native-codec-worker.c -o /transport/codec-fixture
FROM runtime
COPY --from=native /codec/target/release/frameshift-codec /usr/local/bin/frameshift-codec
COPY --from=native /transport/exile/ebin /opt/exile/ebin
COPY --from=native /transport/exile/priv /opt/exile/priv
COPY --from=native /transport/codec-fixture /usr/local/bin/codec-fixture
ENV TMPDIR=/tmp/codec-service
USER 65534:65534
CMD ["elixir", "/src/test/frameshift/native_codec/linux_owner_join.exs"]
