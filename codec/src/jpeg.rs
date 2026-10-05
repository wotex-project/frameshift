use crate::{Error, MAX_DIMENSION, MAX_PIXELS, Normalized, color, envelope, orient};
use jpeg_decoder::ColorTransform;
use std::io::Cursor;

struct Frame {
    width: u32,
    height: u32,
    progressive: bool,
    ids: Vec<u8>,
    sampling: Vec<u8>,
    approximation: [[Option<u8>; 64]; 3],
}

struct Envelope<'a> {
    frame: Frame,
    exif: Option<&'a [u8]>,
    icc: Option<Vec<u8>>,
    transform: ColorTransform,
}

pub fn normalize(source: &[u8]) -> Result<Normalized, Error> {
    let envelope = inspect(source)?;
    let (orientation, explicit_srgb) = metadata(envelope.exif, envelope.icc.is_some())?;
    let gray = envelope.frame.ids.len() == 1;
    let selected = color::select_jpeg_profile(envelope.icc.as_deref(), gray, explicit_srgb)?;
    let mut decoder = jpeg_decoder::Decoder::new(Cursor::new(source));
    decoder.set_max_decoding_buffer_size(MAX_PIXELS * 3);
    decoder.set_color_transform(envelope.transform);
    let decoded = decoder.decode().map_err(|_| Error::Malformed)?;
    let info = decoder.info().ok_or(Error::Malformed)?;
    let frame = envelope.frame;
    if u32::from(info.width) != frame.width || u32::from(info.height) != frame.height {
        return Err(Error::Malformed);
    }

    if info.pixel_format
        != if gray {
            jpeg_decoder::PixelFormat::L8
        } else {
            jpeg_decoder::PixelFormat::RGB24
        }
    {
        return Err(Error::Malformed);
    }
    let (rgba, color, profile_digest) =
        color::convert_jpeg(&decoded, frame.width, frame.height, gray, selected)?;
    let (width, height, rgba) = orient(rgba, frame.width, frame.height, orientation)?;
    Ok(Normalized {
        media: 2,
        width,
        height,
        orientation,
        color,
        profile_digest,
        rgba,
    })
}

fn inspect(source: &[u8]) -> Result<Envelope<'_>, Error> {
    let mut offset = 2;
    let mut markers = 1;
    let mut metadata_bytes = 0usize;
    let mut frame: Option<Frame> = None;
    let mut exif = None;
    let mut jfif = false;
    let mut adobe = None;
    let mut icc_chunks: [Option<&[u8]>; 256] = [None; 256];
    let mut icc_count = None;
    let mut icc_bytes = 0usize;
    let mut scans = 0;
    let mut restart_interval = 0;
    while offset < source.len() {
        marker_bound(&mut markers)?;
        if source.get(offset) != Some(&255) {
            return Err(Error::Malformed);
        }
        while source.get(offset) == Some(&255) {
            offset += 1;
        }
        let marker = *source.get(offset).ok_or(Error::Malformed)?;
        offset += 1;
        match marker {
            0xd9 => {
                let frame = frame.ok_or(Error::Malformed)?;
                if offset != source.len() || scans == 0 {
                    return Err(Error::Malformed);
                }
                if frame.approximation[..frame.ids.len()]
                    .iter()
                    .flatten()
                    .any(|v| *v != Some(0))
                {
                    return Err(Error::Unsupported);
                }
                let transform = interpretation(&frame, jfif, adobe)?;
                let icc = if let Some(count) = icc_count {
                    let mut bytes = crate::allocate(icc_bytes)?;
                    let mut at = 0;
                    for chunk in &icc_chunks[1..=count as usize] {
                        let chunk = chunk.ok_or(Error::Color)?;
                        bytes[at..at + chunk.len()].copy_from_slice(chunk);
                        at += chunk.len();
                    }
                    Some(bytes)
                } else {
                    None
                };
                return Ok(Envelope {
                    frame,
                    exif,
                    icc,
                    transform,
                });
            }
            0x00 | 0xd8 | 0xd0..=0xd7 => return Err(Error::Malformed),
            _ => {}
        }
        let length = source.get(offset..offset + 2).ok_or(Error::Malformed)?;
        let length = u16::from_be_bytes(length.try_into().unwrap()) as usize;
        if length < 2 {
            return Err(Error::Malformed);
        }
        let end = offset.checked_add(length).ok_or(Error::Bounds)?;
        let data = source.get(offset + 2..end).ok_or(Error::Malformed)?;
        metadata_bytes = metadata_bytes
            .checked_add(data.len())
            .ok_or(Error::Bounds)?;
        if metadata_bytes > 4 * 1024 * 1024 {
            return Err(Error::Bounds);
        }
        offset = end;
        match marker {
            0xc0 | 0xc2 => {
                if frame.is_some() || scans != 0 {
                    return Err(Error::Malformed);
                }
                frame = Some(parse_frame(data, marker == 0xc2)?);
            }
            0xda => {
                scans += 1;
                if scans > 64 {
                    return Err(Error::Bounds);
                }
                parse_scan(data, frame.as_mut().ok_or(Error::Malformed)?)?;
                offset = entropy_end(source, offset, restart_interval, &mut markers)?;
            }
            0xdb => quantization(data)?,
            0xc4 => huffman(data)?,
            0xdd if data.len() == 2 => {
                restart_interval = u16::from_be_bytes(data.try_into().unwrap());
            }
            0xe0 => {
                if jfif {
                    return Err(Error::Metadata);
                }
                if data.len() < 14 || &data[..5] != b"JFIF\0" {
                    return Err(Error::Unsupported);
                }
                let x = u16::from_be_bytes(data[8..10].try_into().unwrap());
                let y = u16::from_be_bytes(data[10..12].try_into().unwrap());
                if data[5] != 1
                    || data[6] > 2
                    || data[7] > 2
                    || x == 0
                    || x != y
                    || data.len() != 14 + 3 * data[12] as usize * data[13] as usize
                {
                    return Err(Error::Metadata);
                }
                jfif = true;
            }
            0xe1 => {
                if !data.starts_with(b"Exif\0\0") {
                    return Err(Error::Unsupported);
                }
                if exif.is_some() {
                    return Err(Error::Metadata);
                }
                let raw = &data[6..];
                if raw.len() > 64 * 1024 {
                    return Err(Error::Bounds);
                }
                exif = Some(raw);
            }
            0xe2 => {
                if !data.starts_with(b"ICC_PROFILE\0") {
                    return Err(Error::Unsupported);
                }
                if data.len() <= 14 {
                    return Err(Error::Color);
                }
                let sequence = data[12];
                let count = data[13];
                if count == 0
                    || sequence == 0
                    || sequence > count
                    || icc_count.is_some_and(|n| n != count)
                    || icc_chunks[sequence as usize].is_some()
                {
                    return Err(Error::Color);
                }
                icc_count = Some(count);
                icc_bytes += data.len() - 14;
                if icc_bytes > 1024 * 1024 {
                    return Err(Error::Bounds);
                }
                icc_chunks[sequence as usize] = Some(&data[14..]);
            }
            0xee => {
                if adobe.is_some() {
                    return Err(Error::Metadata);
                }
                if data.len() != 12 || &data[..5] != b"Adobe" {
                    return Err(Error::Unsupported);
                }
                if data[5..7] != [0, 100] || data[7..11] != [0; 4] || data[11] > 1 {
                    return Err(Error::Unsupported);
                }
                adobe = Some(data[11]);
            }
            0xfe => {}
            _ => return Err(Error::Unsupported),
        }
    }
    Err(Error::Malformed)
}

fn marker_bound(markers: &mut usize) -> Result<(), Error> {
    *markers += 1;
    if *markers > 65_536 {
        Err(Error::Bounds)
    } else {
        Ok(())
    }
}

fn parse_frame(data: &[u8], progressive: bool) -> Result<Frame, Error> {
    if data.len() < 6 {
        return Err(Error::Malformed);
    }
    if data[0] != 8 || !matches!(data[5], 1 | 3) {
        return Err(Error::Unsupported);
    }
    let height = u16::from_be_bytes(data[1..3].try_into().unwrap()) as u32;
    let width = u16::from_be_bytes(data[3..5].try_into().unwrap()) as u32;
    if width == 0
        || height == 0
        || width > MAX_DIMENSION
        || height > MAX_DIMENSION
        || width as usize * height as usize > MAX_PIXELS
    {
        return Err(Error::Bounds);
    }
    if data.len() != 6 + data[5] as usize * 3 {
        return Err(Error::Malformed);
    }
    let mut ids = Vec::new();
    let mut sampling = Vec::new();
    for component in data[6..].chunks_exact(3) {
        if ids.contains(&component[0]) || component[2] > 3 {
            return Err(Error::Malformed);
        }
        ids.push(component[0]);
        sampling.push(component[1]);
    }
    if sampling.len() == 1 && sampling != [0x11]
        || sampling.len() == 3
            && (sampling[1..] != [0x11, 0x11] || !matches!(sampling[0], 0x11 | 0x12 | 0x21 | 0x22))
    {
        return Err(Error::Unsupported);
    }
    // Checked admitted h/v <= 2 makes every padded coefficient dimension finite.
    let h = (sampling[0] >> 4) as usize;
    let v = (sampling[0] & 15) as usize;
    let mcus = (width as usize).div_ceil(h * 8) * (height as usize).div_ceil(v * 8);
    let coefficient_bytes = mcus
        * sampling
            .iter()
            .map(|s| (s >> 4) as usize * (s & 15) as usize)
            .sum::<usize>()
        * 64
        * 2;
    if coefficient_bytes > 192 * 1024 * 1024 {
        return Err(Error::Bounds);
    }
    Ok(Frame {
        width,
        height,
        progressive,
        ids,
        sampling,
        approximation: [[None; 64]; 3],
    })
}

fn parse_scan(data: &[u8], frame: &mut Frame) -> Result<(), Error> {
    let count = *data.first().ok_or(Error::Malformed)? as usize;
    if count == 0 || count > frame.ids.len() || data.len() != 4 + count * 2 {
        return Err(Error::Malformed);
    }
    let start = data[1 + count * 2] as usize;
    let end = data[2 + count * 2] as usize;
    let high = data[3 + count * 2] >> 4;
    let low = data[3 + count * 2] & 15;
    if start > end
        || end > 63
        || high > 13
        || low > 13
        || !frame.progressive && (start != 0 || end != 63 || high != 0 || low != 0)
        || frame.progressive
            && (start == 0 && end != 0 || start != 0 && count != 1 || high != 0 && high != low + 1)
    {
        return Err(Error::Malformed);
    }
    let mut previous = None;
    for component in data[1..1 + count * 2].chunks_exact(2) {
        let index = frame
            .ids
            .iter()
            .position(|id| *id == component[0])
            .ok_or(Error::Malformed)?;
        if previous.is_some_and(|p| index <= p) || component[1] >> 4 > 3 || component[1] & 15 > 3 {
            return Err(Error::Malformed);
        }
        previous = Some(index);
        if start > 0 && frame.approximation[index][0].is_none() {
            return Err(Error::Malformed);
        }
        for value in &mut frame.approximation[index][start..=end] {
            if high == 0 && value.is_some() || high != 0 && *value != Some(high) {
                return Err(Error::Malformed);
            }
            *value = Some(low);
        }
    }
    Ok(())
}

fn entropy_end(
    source: &[u8],
    mut offset: usize,
    interval: u16,
    markers: &mut usize,
) -> Result<usize, Error> {
    let mut expected = 0;
    loop {
        let byte = *source.get(offset).ok_or(Error::Malformed)?;
        if byte != 255 {
            offset += 1;
            continue;
        }
        let start = offset;
        offset += 1;
        let mut next = *source.get(offset).ok_or(Error::Malformed)?;
        if next == 0 {
            offset += 1;
            continue;
        }
        while next == 255 {
            offset += 1;
            next = *source.get(offset).ok_or(Error::Malformed)?;
        }
        if next == 0 {
            return Err(Error::Malformed);
        }
        if (0xd0..=0xd7).contains(&next) {
            marker_bound(markers)?;
            if interval == 0 || next != 0xd0 + expected {
                return Err(Error::Malformed);
            }
            expected = (expected + 1) % 8;
            offset += 1;
        } else {
            return Ok(start);
        }
    }
}

fn interpretation(frame: &Frame, jfif: bool, adobe: Option<u8>) -> Result<ColorTransform, Error> {
    if frame.ids.len() == 1 {
        if adobe.is_some() {
            return Err(Error::Color);
        }
        return Ok(ColorTransform::Grayscale);
    }
    if frame.ids == b"RGB" && frame.sampling == [0x11; 3] {
        if jfif || adobe == Some(1) {
            return Err(Error::Color);
        }
        Ok(ColorTransform::RGB)
    } else if frame.ids == [1, 2, 3] || frame.ids == [0, 1, 2] && (jfif || adobe == Some(1)) {
        if adobe == Some(0) {
            return Err(Error::Color);
        }
        Ok(ColorTransform::YCbCr)
    } else {
        Err(Error::Unsupported)
    }
}

fn quantization(mut data: &[u8]) -> Result<(), Error> {
    if data.is_empty() {
        return Err(Error::Malformed);
    }
    while !data.is_empty() {
        if data[0] >> 4 != 0 {
            return Err(Error::Unsupported);
        }
        if data[0] & 15 > 3 || data.len() < 65 || data[1..65].contains(&0) {
            return Err(Error::Malformed);
        }
        data = &data[65..];
    }
    Ok(())
}

fn huffman(mut data: &[u8]) -> Result<(), Error> {
    if data.is_empty() {
        return Err(Error::Malformed);
    }
    while !data.is_empty() {
        if data.len() < 17 || data[0] >> 4 > 1 || data[0] & 15 > 3 {
            return Err(Error::Malformed);
        }
        let count = data[1..17].iter().map(|n| *n as usize).sum::<usize>();
        if count == 0 || count > 256 || data.len() < 17 + count {
            return Err(Error::Malformed);
        }
        let mut remaining = 1i32;
        for count in &data[1..17] {
            remaining = remaining * 2 - *count as i32;
            if remaining <= 0 {
                return Err(Error::Malformed);
            }
        }
        let dc = data[0] >> 4 == 0;
        let mut seen = [false; 256];
        for value in &data[17..17 + count] {
            if seen[*value as usize] || dc && *value > 11 || !dc && value & 15 > 10 {
                return Err(Error::Malformed);
            }
            seen[*value as usize] = true;
        }
        data = &data[17 + count..];
    }
    Ok(())
}

fn metadata(raw: Option<&[u8]>, has_icc: bool) -> Result<(u8, bool), Error> {
    let orientation = envelope::orientation(raw)?;
    let Some(raw) = raw else {
        return Ok((orientation, false));
    };
    let exif = exif::Reader::new()
        .read_raw(raw.to_vec())
        .map_err(|_| Error::Metadata)?;
    let mut space = None;
    let mut version = false;
    for field in exif.fields().filter(|f| f.ifd_num == exif::In::PRIMARY) {
        match field.tag {
            exif::Tag::ColorSpace => {
                if space.is_some() {
                    return Err(Error::Metadata);
                }
                space = match &field.value {
                    exif::Value::Short(values)
                        if values.len() == 1 && matches!(values[0], 1 | 65535) =>
                    {
                        Some(values[0])
                    }
                    _ => return Err(Error::Color),
                };
            }
            exif::Tag::ExifVersion => {
                if version {
                    return Err(Error::Metadata);
                }
                version = true;
                match &field.value {
                    exif::Value::Undefined(values, _)
                        if values.len() == 4
                            && &values[..2] == b"02"
                            && values.iter().all(u8::is_ascii_digit) => {}
                    _ => return Err(Error::Unsupported),
                }
            }
            exif::Tag::Gamma
            | exif::Tag::WhitePoint
            | exif::Tag::PrimaryChromaticities
            | exif::Tag::TransferFunction
            | exif::Tag::InteroperabilityIndex => return Err(Error::Color),
            _ => {}
        }
    }
    if space == Some(1) && has_icc || space == Some(65535) && !has_icc {
        return Err(Error::Color);
    }
    Ok((orientation, space == Some(1)))
}
