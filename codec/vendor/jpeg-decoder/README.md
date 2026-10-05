# Pinned strict JPEG decoder

This is image-rs/jpeg-decoder 0.3.2 at
`eb2d7c0f6a2d0298aba7a7f8b9ca1440353e8f8c`, with the bounded Frameshift
strict-entropy patch. All upstream Rust source and both license texts are
retained. `Cargo.toml.upstream`, `UPSTREAM-README.md` and `CHANGELOG.md` preserve
published context. The original registry checksum is
`00810f1d8b74be64b13dbf3db89ac67740615d6c891f0e7b6179326533011a07`.

`frameshift.patch` records every source difference from that exact revision.
The patch tracks real bits independently of padded lookahead, rejects consuming
fabricated bits, checks terminal all-one padding, rejects excessive EOB runs and
unexpected final restarts, and uses the immediate scalar worker. Unsupported
feature combinations fail compilation. Cargo metadata removes unused upstream
test/benchmark dependencies; fixture tests belong to the enclosing codec.

This is not an independent general-purpose decoder or a released upstream fix.
The enclosing codec owns bounded full-container/scan/color admission and the
process boundary. Read its [requirements](../../../docs/architecture/content-pipeline.md#linux-native-normalization)
and [source review](../../../docs/research/software-stack.md#jpeg-admission-source-review).
Any update must reproduce source provenance, patch review, complete positive and
negative fixtures, unchanged PNG vectors and cross-target golden bytes. Do not
replace the patch with an untested strictness setting.
