# Portable locked BEAM code joined to freshly compiled Linux native closure.
ARG CODEC_IMAGE=frameshift-codec-arm64:fixture
FROM hexpm/elixir@sha256:4a42b164d952ef56c135c1626f2174ab1a2780cd6fafd65b04d6e1590dfbd516 AS runtime
FROM ${CODEC_IMAGE} AS native
USER 0
COPY --from=runtime /usr/local/lib/erlang/usr/include /otp-include
COPY exile /transport/exile
COPY exqlite /transport/exqlite
COPY native-codec-worker.c /transport/native-codec-worker.c
RUN make -C /transport/exile all ERL_INTERFACE_INCLUDE_DIR=/otp-include \
    && make -C /transport/exqlite all MIX_APP_PATH=/transport/exqlite ERTS_INCLUDE_DIR=/otp-include ERL_EI_INCLUDE_DIR=/otp-include \
    && cc -std=c99 -Wall -Wextra -Werror /transport/native-codec-worker.c -o /transport/codec-fixture
FROM runtime
COPY --from=native /codec/target/release/frameshift-codec /usr/local/bin/frameshift-codec
COPY --from=native /transport/exile/ebin /opt/exile/ebin
COPY --from=native /transport/exile/priv /opt/exile/priv
COPY --from=native /transport/exqlite/ebin /opt/exqlite/ebin
COPY --from=native /transport/exqlite/priv /opt/exqlite/priv
COPY --from=native /transport/codec-fixture /usr/local/bin/codec-fixture
ENV TMPDIR=/tmp/codec-service
# Root drives runuser fixtures; every host/codec/SQLite operation runs under
# explicit nonroot service/client identities in private service directories.
CMD ["elixir", "/src/test/frameshift/import/linux_upload_contract.exs"]
