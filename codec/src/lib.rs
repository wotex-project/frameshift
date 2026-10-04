//! Bounded still-image normalization; no paths, network, library or frame authority.
//!
//! This cohort accepts static PNG, applies the primary Exif orientation and
//! converts admitted SDR color descriptions to straight-alpha RGBA8 sRGB.
//! Original bytes remain the host's immutable source. Other formats and color
//! profiles require their own admission fixtures before this worker enables them.

mod color;
mod envelope;

use std::io::Cursor;

pub const MAX_SOURCE: usize = 128 * 1024 * 1024;
pub const MAX_PIXELS: usize = 16_777_011;
pub const MAX_DIMENSION: u32 = 32_768;
pub const HEADER_BYTES: usize = 64;
pub const REVISION: &str = "frameshift-codec/1 png/0.18.1 moxcms/0.9.1 exif/0.6.1 scalar-sdr/1";

/// Finite wire errors. No producer diagnostic or source metadata is disclosed.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
#[repr(u8)]
pub enum Error {
    Malformed = 1,
    Unsupported = 2,
    Bounds = 3,
    Color = 4,
    Metadata = 5,
    Allocation = 6,
    Internal = 7,
}

/// Normalized pixels and the exact source-color interpretation used by this cohort.
pub struct Normalized {
    pub width: u32,
    pub height: u32,
    pub orientation: u8,
    pub color: u8,
    pub profile_digest: [u8; 32],
    pub rgba: Vec<u8>,
}

/// Decode one complete source, rejecting animation, malformed metadata and overflow.
pub fn normalize(source: &[u8]) -> Result<Normalized, Error> {
    let envelope = envelope::inspect(source)?;
    let mut decoder = png::Decoder::new_with_limits(
        Cursor::new(source),
        png::Limits {
            bytes: 192 * 1024 * 1024,
        },
    );
    decoder.ignore_checksums(false);
    decoder.set_ignore_text_chunk(true);
    decoder.set_ignore_iccp_chunk(true);
    decoder.set_transformations(png::Transformations::EXPAND);
    let mut reader = decoder.read_info().map_err(|_| Error::Malformed)?;
    let count = reader.output_buffer_size().ok_or(Error::Bounds)?;
    if count > MAX_PIXELS * 8 {
        return Err(Error::Bounds);
    }
    let mut decoded = allocate(count)?;
    let frame = reader
        .next_frame(&mut decoded)
        .map_err(|_| Error::Malformed)?;
    reader.finish().map_err(|_| Error::Malformed)?;
    if frame.width != envelope.width || frame.height != envelope.height {
        return Err(Error::Malformed);
    }
    decoded.truncate(frame.buffer_size());
    // Read metadata after finish: trailing eXIf is legal and must not be missed.
    let info = reader.info();
    let orientation = envelope::orientation(info.exif_metadata.as_deref())?;
    let (mut rgba, color, profile_digest) =
        color::convert(&decoded, &frame, info, envelope.icc.as_deref())?;
    // Color transforms never own alpha. Canonical zero-alpha RGB is always zero.
    for pixel in rgba.chunks_exact_mut(4) {
        if pixel[3] == 0 {
            pixel[..3].fill(0);
        }
    }
    let (width, height, rgba) = orient(rgba, frame.width, frame.height, orientation)?;
    Ok(Normalized {
        width,
        height,
        orientation,
        color,
        profile_digest,
        rgba,
    })
}

pub(crate) fn allocate(size: usize) -> Result<Vec<u8>, Error> {
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(size)
        .map_err(|_| Error::Allocation)?;
    bytes.resize(size, 0);
    Ok(bytes)
}

fn orient(
    bytes: Vec<u8>,
    width: u32,
    height: u32,
    orientation: u8,
) -> Result<(u32, u32, Vec<u8>), Error> {
    if orientation == 1 {
        return Ok((width, height, bytes));
    }
    let (out_w, out_h) = if orientation >= 5 {
        (height, width)
    } else {
        (width, height)
    };
    let mut output = allocate(bytes.len())?;
    for y in 0..height {
        for x in 0..width {
            let (ox, oy) = match orientation {
                2 => (width - 1 - x, y),
                3 => (width - 1 - x, height - 1 - y),
                4 => (x, height - 1 - y),
                5 => (y, x),
                6 => (height - 1 - y, x),
                7 => (height - 1 - y, width - 1 - x),
                8 => (y, width - 1 - x),
                _ => return Err(Error::Metadata),
            };
            let from = ((y as usize * width as usize) + x as usize) * 4;
            let to = ((oy as usize * out_w as usize) + ox as usize) * 4;
            output[to..to + 4].copy_from_slice(&bytes[from..from + 4]);
        }
    }
    Ok((out_w, out_h, output))
}

/// Fixed 64-byte FSN1 header, followed by exactly the declared RGBA bytes.
pub fn header(result: &Result<Normalized, Error>) -> [u8; HEADER_BYTES] {
    let mut h = [0; HEADER_BYTES];
    h[..4].copy_from_slice(b"FSN1");
    h[4..6].copy_from_slice(&1u16.to_be_bytes());
    match result {
        Err(error) => h[6] = *error as u8,
        Ok(image) => {
            h[7] = image.color;
            h[8..12].copy_from_slice(&image.width.to_be_bytes());
            h[12..16].copy_from_slice(&image.height.to_be_bytes());
            h[16] = image.orientation;
            h[17] = 1; // image/png; no caller-supplied media label.
            h[24..32].copy_from_slice(&(image.rgba.len() as u64).to_be_bytes());
            h[32..64].copy_from_slice(&image.profile_digest);
        }
    }
    h
}
