# Canonical JPEG join fixture

`canonical-jpeg.jpg` was generated with pinned jpeg-encoder 0.7.1 from 32×24
RGB samples `((n * 37 + n / 17) % 256)` in byte order, quality 90, baseline DCT,
default 4:4:4 sampling and no restart markers. It is a generated software fixture,
not camera, display or physical measurement evidence.

`canonical-jpeg.rgba` is the exact opaque sRGB output of the qualified scalar
strict codec. `canonical-jpeg.json` records original and pixel SHA-256 digests
and the producer revision. Native, authenticated upload, clean CLI and restarted
Linux Library fixtures compare exact original/pixel readback. The enclosing
codec's positive/refusal corpus separately qualifies entropy completion, all
orientations, metadata and color; this join never substitutes for that corpus.

Source bytes are immutable. A codec update must preserve these exact bytes or
explicitly qualify and record a successor fixture. Old Library receipts retain
their admitted master and cannot silently renormalize it.
