# Source-observed Rust 1.97.1 / Debian trixie multiarch fixture; not an installer.
FROM rust@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f
WORKDIR /codec
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY vendor ./vendor
COPY tests ./tests
RUN ./vendor/jpeg-decoder/check-source && test "$(rustc --version | cut -d ' ' -f 2)" = 1.97.1 && cargo fetch --locked
RUN cargo test --offline --locked --release
RUN cargo build --offline --locked --release
RUN find target/release/deps -maxdepth 1 -type f -name 'normalization-*' -executable \
    -exec cp '{}' /usr/local/bin/frameshift-codec-check ';'
RUN find target/release/deps -maxdepth 1 -type f -name 'jpeg-*' -executable \
    -exec cp '{}' /usr/local/bin/frameshift-jpeg-check ';'
USER 65534:65534

CMD ["/bin/sh", "-c", "/usr/local/bin/frameshift-codec-check && /usr/local/bin/frameshift-jpeg-check"]
