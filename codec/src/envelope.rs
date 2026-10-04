use crate::{Error, MAX_DIMENSION, MAX_PIXELS, MAX_SOURCE};
use std::collections::HashSet;
use std::io::Read;

pub struct Envelope {
    pub width: u32,
    pub height: u32,
    pub icc: Option<Vec<u8>>,
}

// This checks the bounded container envelope; png owns filtering/inflation/pixels.
// Full CRC and an exact IEND protect metadata that upstream deliberately ignores.
pub fn inspect(source: &[u8]) -> Result<Envelope, Error> {
    if source.is_empty() || source.len() > MAX_SOURCE {
        return Err(Error::Bounds);
    }
    if !source.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err(Error::Unsupported);
    }
    let mut offset = 8usize;
    let mut seen = HashSet::new();
    let mut chunks = 0;
    let mut ancillary = 0usize;
    let mut dimensions = None;
    let mut idat = false;
    let mut idat_ended = false;
    let mut icc = None;
    let mut image_data = Vec::new();
    let mut filtered_bytes = 0;
    while offset < source.len() {
        chunks += 1;
        if chunks > 65_536 {
            return Err(Error::Bounds);
        }
        let prefix = source.get(offset..offset + 8).ok_or(Error::Malformed)?;
        let length = u32::from_be_bytes(prefix[..4].try_into().unwrap()) as usize;
        let tag: [u8; 4] = prefix[4..8].try_into().unwrap();
        if !tag.iter().all(u8::is_ascii_alphabetic) || tag[2].is_ascii_lowercase() {
            return Err(Error::Malformed);
        }
        let end = offset
            .checked_add(length)
            .and_then(|n| n.checked_add(12))
            .ok_or(Error::Bounds)?;
        let chunk = source.get(offset..end).ok_or(Error::Malformed)?;
        let data = &chunk[8..8 + length];
        if crc32fast::hash(&chunk[4..8 + length])
            != u32::from_be_bytes(chunk[8 + length..].try_into().unwrap())
        {
            return Err(Error::Malformed);
        }
        if chunks == 1 && tag != *b"IHDR" {
            return Err(Error::Malformed);
        }
        if tag != *b"IDAT" && tag != *b"IEND" && idat {
            idat_ended = true;
        }
        if matches!(&tag, b"acTL" | b"fcTL" | b"fdAT") {
            return Err(Error::Unsupported);
        }
        if tag[0].is_ascii_lowercase() {
            ancillary = ancillary.checked_add(length).ok_or(Error::Bounds)?;
            if length > 1024 * 1024 || ancillary > 4 * 1024 * 1024 {
                return Err(Error::Bounds);
            }
        }
        if matches!(
            &tag,
            b"IHDR"
                | b"PLTE"
                | b"tRNS"
                | b"sRGB"
                | b"iCCP"
                | b"cICP"
                | b"cHRM"
                | b"gAMA"
                | b"eXIf"
                | b"mDCV"
                | b"cLLI"
        ) && !seen.insert(tag)
        {
            return Err(Error::Metadata);
        }
        if idat
            && matches!(
                &tag,
                b"PLTE"
                    | b"tRNS"
                    | b"sRGB"
                    | b"iCCP"
                    | b"cICP"
                    | b"cHRM"
                    | b"gAMA"
                    | b"mDCV"
                    | b"cLLI"
            )
        {
            return Err(Error::Metadata);
        }
        if seen.contains(b"PLTE") && matches!(&tag, b"sRGB" | b"iCCP" | b"cICP" | b"cHRM" | b"gAMA")
        {
            return Err(Error::Metadata);
        }
        match &tag {
            b"IHDR" => {
                if length != 13 {
                    return Err(Error::Malformed);
                }
                let width = u32::from_be_bytes(data[..4].try_into().unwrap());
                let height = u32::from_be_bytes(data[4..8].try_into().unwrap());
                if width == 0
                    || height == 0
                    || width > MAX_DIMENSION
                    || height > MAX_DIMENSION
                    || width as u64 * height as u64 > MAX_PIXELS as u64
                {
                    return Err(Error::Bounds);
                }
                dimensions = Some(Envelope {
                    width,
                    height,
                    icc: None,
                });
                filtered_bytes = expected_filtered_bytes(data, width, height)?;
            }
            b"IDAT" => {
                if idat_ended {
                    return Err(Error::Malformed);
                }
                idat = true;
                image_data.push(data);
            }
            b"IEND" => {
                if length != 0 || !idat || end != source.len() {
                    return Err(Error::Malformed);
                }
                let mut envelope = dimensions.ok_or(Error::Malformed)?;
                envelope.icc = icc;
                if seen.contains(b"iCCP") && seen.contains(b"sRGB") {
                    return Err(Error::Color);
                }
                validate_image_stream(&image_data, filtered_bytes)?;
                return Ok(envelope);
            }
            b"eXIf" => {
                if length > 64 * 1024 {
                    return Err(Error::Bounds);
                }
            }
            b"iCCP" => {
                icc = Some(inflate_icc(data)?);
            }
            b"sRGB" => {
                if length != 1 || data[0] > 3 {
                    return Err(Error::Color);
                }
            }
            b"gAMA" => {
                if length != 4 || data == [0; 4] {
                    return Err(Error::Color);
                }
            }
            b"cHRM" => {
                if length != 32 {
                    return Err(Error::Color);
                }
                for pair in data.chunks_exact(8) {
                    let x = u32::from_be_bytes(pair[..4].try_into().unwrap());
                    let y = u32::from_be_bytes(pair[4..].try_into().unwrap());
                    if y == 0 || x > 100_000 || y > 100_000 || x + y > 100_000 {
                        return Err(Error::Color);
                    }
                }
            }
            b"cICP" => {
                if !matches!(data, [1 | 12, 13, 0, 1]) {
                    return Err(Error::Color);
                }
            }
            b"mDCV" | b"cLLI" => return Err(Error::Color), // no tone-map contract
            b"PLTE" => {}
            _ if tag[0].is_ascii_uppercase() => return Err(Error::Unsupported),
            _ => {}
        }
        offset = end;
    }
    Err(Error::Malformed)
}

fn expected_filtered_bytes(ihdr: &[u8], width: u32, height: u32) -> Result<usize, Error> {
    let depth = ihdr[8] as usize;
    let samples = match ihdr[9] {
        0 if matches!(depth, 1 | 2 | 4 | 8 | 16) => 1,
        2 if matches!(depth, 8 | 16) => 3,
        3 if matches!(depth, 1 | 2 | 4 | 8) => 1,
        4 if matches!(depth, 8 | 16) => 2,
        6 if matches!(depth, 8 | 16) => 4,
        _ => return Err(Error::Malformed),
    };
    if ihdr[10] != 0 || ihdr[11] != 0 || ihdr[12] > 1 {
        return Err(Error::Malformed);
    }
    let width = width as usize;
    let height = height as usize;
    let row_size = |w: usize| (w * samples * depth).div_ceil(8) + 1;
    if ihdr[12] == 0 {
        return Ok(row_size(width) * height);
    }
    let mut size = 0;
    for (x, y, dx, dy) in [
        (0, 0, 8, 8),
        (4, 0, 8, 8),
        (0, 4, 4, 8),
        (2, 0, 4, 4),
        (0, 2, 2, 4),
        (1, 0, 2, 2),
        (0, 1, 1, 2),
    ] {
        if width > x && height > y {
            size += row_size((width - x).div_ceil(dx)) * (height - y).div_ceil(dy);
        }
    }
    Ok(size)
}

struct ImageChunks<'a> {
    chunks: &'a [&'a [u8]],
    index: usize,
    offset: usize,
}

impl Read for ImageChunks<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        while let Some(chunk) = self.chunks.get(self.index) {
            let remaining = &chunk[self.offset..];
            if remaining.is_empty() {
                self.index += 1;
                self.offset = 0;
                continue;
            }
            let count = buffer.len().min(remaining.len());
            buffer[..count].copy_from_slice(&remaining[..count]);
            self.offset += count;
            return Ok(count);
        }
        Ok(0)
    }
}

fn validate_image_stream(chunks: &[&[u8]], expected: usize) -> Result<(), Error> {
    let total: usize = chunks.iter().map(|s| s.len()).sum();
    let mut decoder = flate2::read::ZlibDecoder::new(ImageChunks {
        chunks,
        index: 0,
        offset: 0,
    });
    let mut buffer = [0; 32 * 1024];
    let mut received = 0;
    loop {
        let count = decoder.read(&mut buffer).map_err(|_| Error::Malformed)?;
        if count == 0 {
            break;
        }
        received += count;
        if received > expected {
            return Err(Error::Malformed);
        }
    }
    if received != expected || decoder.total_in() != total as u64 {
        return Err(Error::Malformed);
    }
    Ok(())
}

fn inflate_icc(data: &[u8]) -> Result<Vec<u8>, Error> {
    let end = data.iter().position(|b| *b == 0).ok_or(Error::Color)?;
    // PNG keyword: 1..79 Latin-1 bytes, no controls or repeated/edge spaces.
    if end == 0
        || end > 79
        || data[0] == 32
        || data[end - 1] == 32
        || data[..end].windows(2).any(|s| s == b"  ")
        || data[..end]
            .iter()
            .any(|b| !matches!(*b, 32..=126 | 161..=255))
        || data.get(end + 1) != Some(&0)
    {
        return Err(Error::Color);
    }
    let compressed = data.get(end + 2..).ok_or(Error::Color)?;
    let mut decoder = flate2::read::ZlibDecoder::new(compressed);
    let mut profile = Vec::new();
    decoder
        .by_ref()
        .take(1024 * 1024 + 1)
        .read_to_end(&mut profile)
        .map_err(|_| Error::Color)?;
    if profile.len() > 1024 * 1024 {
        return Err(Error::Bounds);
    }
    if decoder.total_in() != compressed.len() as u64 {
        return Err(Error::Color);
    }
    Ok(profile)
}

pub fn orientation(raw: Option<&[u8]>) -> Result<u8, Error> {
    let Some(raw) = raw else {
        return Ok(1);
    };
    let exif = exif::Reader::new()
        .read_raw(raw.to_vec())
        .map_err(|_| Error::Metadata)?;
    let fields: Vec<_> = exif
        .fields()
        .filter(|f| f.tag == exif::Tag::Orientation && f.ifd_num == exif::In::PRIMARY)
        .collect();
    match fields.as_slice() {
        [] => Ok(1),
        [field] => match &field.value {
            exif::Value::Short(values) if values.len() == 1 && (1..=8).contains(&values[0]) => {
                Ok(values[0] as u8)
            }
            _ => Err(Error::Metadata),
        },
        _ => Err(Error::Metadata),
    }
}
