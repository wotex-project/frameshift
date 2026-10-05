# Development closure fixture; all production release gates remain independent.
FROM rust@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f AS rust_tools
FROM hexpm/elixir@sha256:5b77ba2dec41d6d1716b354bbca92cd9359ed02b273f92eeabd0c92f9c9bdeee AS build
ARG TARGETARCH
ARG FIXTURE_ERL_FLAGS
ENV ERL_FLAGS=${FIXTURE_ERL_FLAGS} MIX_ENV=prod MIX_HOME=/build-tools/mix HEX_HOME=/build-tools/hex HEX_OFFLINE=1
ENV PATH=/usr/local/cargo/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git binutils file ca-certificates libssl-dev libsctp1 netbase systemd dpkg-dev && rm -rf /var/lib/apt/lists/*
COPY --from=rust_tools /usr/local/rustup /usr/local/rustup
COPY --from=rust_tools /usr/local/cargo/bin /usr/local/cargo/bin
COPY gleam /usr/local/bin/gleam
COPY mix-archives /build-tools/mix/archives
COPY apps /src/apps
COPY packages /src/packages
COPY protocol /src/protocol
COPY codec /src/codec
RUN test "$(. /etc/os-release; echo "$ID:$VERSION_ID")" = ubuntu:24.04 && test "$(dpkg --print-architecture)" = "$TARGETARCH" && test "$(cat /usr/local/lib/erlang/releases/29/OTP_VERSION)" = 29.1 && test "$(elixir --short-version)" = 1.20.4 && test "$(gleam --version)" = 'gleam 1.18.1' && test "$(rustc --version | cut -d ' ' -f2)" = 1.97.1
WORKDIR /src/apps/core
RUN mix deps.compile && mix compile --warnings-as-errors && mix release --overwrite
WORKDIR /src/codec
RUN ./vendor/jpeg-decoder/check-source && cargo test --release --locked && cargo build --release --locked
COPY linux /src/release/linux
COPY frameshift-raster /src/frameshift-raster
COPY inputs.json /src/inputs.json
RUN /src/release/linux/build-tree
FROM scratch AS artifact
COPY --from=build /out/ /
