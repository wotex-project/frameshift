use crate::{Error, allocate};
use moxcms::{
    ColorProfile, DataColorSpace, Layout, ParsingOptions, RenderingIntent, TransformOptions,
    curve_from_gamma,
};
use sha2::{Digest, Sha256};
use std::collections::HashSet;

const SRGB_CHRM: [u32; 8] = [31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000];
type Converted = (Vec<u8>, u8, [u8; 32]);

pub fn convert(
    data: &[u8],
    frame: &png::OutputInfo,
    info: &png::Info<'_>,
    icc: Option<&[u8]>,
) -> Result<Converted, Error> {
    let samples = Samples {
        width: frame.width,
        height: frame.height,
        channels: frame.color_type.samples(),
        depth: match frame.bit_depth {
            png::BitDepth::Eight => 1,
            png::BitDepth::Sixteen => 2,
            _ => return Err(Error::Malformed),
        },
        gray: matches!(
            frame.color_type,
            png::ColorType::Grayscale | png::ColorType::GrayscaleAlpha
        ),
        alpha: matches!(
            frame.color_type,
            png::ColorType::Rgba | png::ColorType::GrayscaleAlpha
        ),
    };
    convert_samples(data, samples, select_profile(info, icc)?)
}

pub fn select_jpeg_profile(
    icc: Option<&[u8]>,
    gray: bool,
    explicit_srgb: bool,
) -> Result<(Option<ColorProfile>, u8, [u8; 32]), Error> {
    let profile = icc.map(matrix_profile).transpose()?;
    if profile
        .as_ref()
        .is_some_and(|p| (p.color_space == DataColorSpace::Gray) != gray)
    {
        return Err(Error::Color);
    }
    Ok(match profile {
        Some(profile) => (Some(profile), 5, Sha256::digest(icc.unwrap()).into()),
        None => (None, if explicit_srgb { 7 } else { 1 }, [0; 32]),
    })
}

pub fn convert_jpeg(
    data: &[u8],
    width: u32,
    height: u32,
    gray: bool,
    selected: (Option<ColorProfile>, u8, [u8; 32]),
) -> Result<Converted, Error> {
    convert_samples(
        data,
        Samples {
            width,
            height,
            channels: if gray { 1 } else { 3 },
            depth: 1,
            gray,
            alpha: false,
        },
        selected,
    )
}

struct Samples {
    width: u32,
    height: u32,
    channels: usize,
    depth: usize,
    gray: bool,
    alpha: bool,
}

fn convert_samples(
    data: &[u8],
    samples: Samples,
    selected: (Option<ColorProfile>, u8, [u8; 32]),
) -> Result<Converted, Error> {
    let (profile, code, digest) = selected;
    let Samples {
        width,
        height,
        channels: input_channels,
        depth,
        gray,
        alpha,
    } = samples;
    let pixels = width as usize * height as usize;
    if data.len() != pixels * input_channels * depth {
        return Err(Error::Malformed);
    }
    let mut output = allocate(pixels * 4)?;
    let profile_gray = profile
        .as_ref()
        .is_some_and(|p| p.color_space == DataColorSpace::Gray);
    if profile_gray && !gray {
        return Err(Error::Color);
    }
    let layout = if profile_gray {
        Layout::Gray
    } else {
        Layout::Rgb
    };
    let channels = if profile_gray { 1 } else { 3 };
    let options = TransformOptions {
        rendering_intent: RenderingIntent::RelativeColorimetric,
        allow_use_cicp_transfer: false,
        prefer_fixed_point: true,
        ..TransformOptions::default()
    };
    let destination = ColorProfile::new_srgb();
    let transform = profile
        .as_ref()
        .map(|p| p.create_transform_16bit(layout, &destination, Layout::Rgb, options))
        .transpose()
        .map_err(|_| Error::Color)?;
    // One row at a time. Color conversion preserves 16-bit precision until final
    // round-to-nearest quantization. Source alpha bypasses the color transform.
    let mut row: Vec<u16> = vec![0; width as usize * channels];
    let mut converted: Vec<u16> = vec![0; width as usize * 3];
    for y in 0..height as usize {
        for x in 0..width as usize {
            let pixel = &data[(y * width as usize + x) * input_channels * depth..]
                [..input_channels * depth];
            let sample = |i| {
                if depth == 1 {
                    u16::from(pixel[i]) * 257
                } else {
                    u16::from_be_bytes([pixel[i * 2], pixel[i * 2 + 1]])
                }
            };
            if profile_gray {
                row[x] = sample(0);
            } else {
                for c in 0..3 {
                    row[x * 3 + c] = sample(if gray { 0 } else { c });
                }
            }
            let alpha = if alpha {
                sample(input_channels - 1)
            } else {
                u16::MAX
            };
            output[(y * width as usize + x) * 4 + 3] = quantize(alpha);
        }
        if let Some(transform) = &transform {
            transform
                .transform(&row, &mut converted)
                .map_err(|_| Error::Color)?;
        } else {
            converted.copy_from_slice(&row);
        }
        for x in 0..width as usize {
            for c in 0..3 {
                output[(y * width as usize + x) * 4 + c] = quantize(converted[x * 3 + c]);
            }
        }
    }
    Ok((output, code, digest))
}

fn quantize(value: u16) -> u8 {
    ((u32::from(value) + 128) / 257) as u8
}

fn select_profile(
    info: &png::Info<'_>,
    icc: Option<&[u8]>,
) -> Result<(Option<ColorProfile>, u8, [u8; 32]), Error> {
    // Malformed embedded profiles refuse even when a higher-priority cICP
    // description supplies the selected color interpretation.
    let embedded = icc.map(matrix_profile).transpose()?;
    if let Some(cicp) = info.coding_independent_code_points {
        let raw = [
            cicp.color_primaries,
            cicp.transfer_function,
            cicp.matrix_coefficients,
            u8::from(cicp.is_video_full_range_image),
        ];
        let profile = match raw {
            [1, 13, 0, 1] => None,
            [12, 13, 0, 1] => Some(ColorProfile::new_display_p3()),
            _ => return Err(Error::Color),
        };
        return Ok((
            profile,
            if raw[0] == 1 { 3 } else { 4 },
            Sha256::digest(raw).into(),
        ));
    }
    if let Some(profile) = embedded {
        return Ok((Some(profile), 5, Sha256::digest(icc.unwrap()).into()));
    }
    let srgb_chrm = info.chrm_chunk.is_none_or(|c| {
        c.to_be_bytes()
            .chunks_exact(4)
            .zip(SRGB_CHRM)
            .all(|(b, v)| b == v.to_be_bytes())
    });
    if info.srgb.is_some() {
        if !srgb_chrm || info.gama_chunk.is_some_and(|g| g.into_scaled() != 45455) {
            return Err(Error::Color);
        }
        return Ok((None, 2, [0; 32]));
    }
    if !srgb_chrm {
        return Err(Error::Color);
    }
    if let Some(gamma) = info.gama_chunk {
        let value = gamma.into_value();
        if !(0.1..=10.0).contains(&value) {
            return Err(Error::Color);
        }
        let mut profile = ColorProfile::new_srgb();
        let curve = curve_from_gamma(1.0 / value);
        profile.red_trc = Some(curve.clone());
        profile.green_trc = Some(curve.clone());
        profile.blue_trc = Some(curve);
        profile.cicp = None;
        let mut digest = Sha256::new();
        digest.update(b"frameshift-png-gamma-srgb-primaries-v1:");
        digest.update(gamma.into_scaled().to_be_bytes());
        return Ok((Some(profile), 6, digest.finalize().into()));
    }
    // Untagged PNG is an explicit interpretation, not a measured source profile.
    Ok((None, 1, [0; 32]))
}

fn matrix_profile(bytes: &[u8]) -> Result<ColorProfile, Error> {
    if bytes.len() < 132
        || bytes.len() > 1024 * 1024
        || u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize != bytes.len()
        || !matches!(bytes[8], 2 | 4)
        || &bytes[36..40] != b"acsp"
        || !matches!(&bytes[12..16], b"mntr" | b"scnr")
        || !matches!(&bytes[16..20], b"RGB " | b"GRAY")
        || &bytes[20..24] != b"XYZ "
    {
        return Err(Error::Color);
    }
    let count = u32::from_be_bytes(bytes[128..132].try_into().unwrap()) as usize;
    if count > 64 || 132 + count * 12 > bytes.len() {
        return Err(Error::Color);
    }
    let mut seen = HashSet::new();
    for entry in bytes[132..132 + count * 12].chunks_exact(12) {
        let tag: [u8; 4] = entry[..4].try_into().unwrap();
        if !seen.insert(tag)
            || matches!(
                &tag,
                b"A2B0"
                    | b"A2B1"
                    | b"A2B2"
                    | b"B2A0"
                    | b"B2A1"
                    | b"B2A2"
                    | b"D2B0"
                    | b"D2B1"
                    | b"D2B2"
                    | b"D2B3"
                    | b"B2D0"
                    | b"B2D1"
                    | b"B2D2"
                    | b"B2D3"
                    | b"gamt"
                    | b"cicp"
            )
        {
            return Err(Error::Color);
        }
        let offset = u32::from_be_bytes(entry[4..8].try_into().unwrap()) as usize;
        let length = u32::from_be_bytes(entry[8..12].try_into().unwrap()) as usize;
        if offset < 132 + count * 12
            || !offset.is_multiple_of(4)
            || length < 8
            || offset
                .checked_add(length)
                .is_none_or(|end| end > bytes.len())
        {
            return Err(Error::Color);
        }
    }
    let profile = ColorProfile::new_from_slice_with_options(
        bytes,
        ParsingOptions {
            max_profile_size: 1024 * 1024 + 1,
            max_allowed_clut_size: 0,
            max_allowed_trc_size: 4096,
        },
    )
    .map_err(|_| Error::Color)?;
    let complete = if profile.color_space == DataColorSpace::Gray {
        profile.gray_trc.is_some()
    } else {
        profile.red_trc.is_some()
            && profile.green_trc.is_some()
            && profile.blue_trc.is_some()
            && seen.contains(b"rXYZ")
            && seen.contains(b"gXYZ")
            && seen.contains(b"bXYZ")
    };
    if !complete || !seen.contains(b"wtpt") {
        return Err(Error::Color);
    }
    for curve in [
        &profile.red_trc,
        &profile.green_trc,
        &profile.blue_trc,
        &profile.gray_trc,
    ]
    .into_iter()
    .flatten()
    {
        validate_curve(curve)?;
    }
    if profile.color_space == DataColorSpace::Rgb {
        let r = profile.red_colorant;
        let g = profile.green_colorant;
        let b = profile.blue_colorant;
        let determinant = r.x * (g.y * b.z - b.y * g.z) - g.x * (r.y * b.z - b.y * r.z)
            + b.x * (r.y * g.z - g.y * r.z);
        if !determinant.is_finite() || determinant.abs() < 0.000001 {
            return Err(Error::Color);
        }
    }
    Ok(profile)
}

fn validate_curve(curve: &moxcms::ToneReprCurve) -> Result<(), Error> {
    match curve {
        moxcms::ToneReprCurve::Lut(values) => {
            if values.len() > 4096
                || values.windows(2).any(|v| v[0] > v[1])
                || (values.len() == 1 && values[0] == 0)
            {
                return Err(Error::Color);
            }
        }
        moxcms::ToneReprCurve::Parametric(values) => {
            if !matches!(values.len(), 1 | 3 | 4 | 5 | 7)
                || values.iter().any(|v| !v.is_finite())
                || !(0.1..=10.0).contains(&values[0])
            {
                return Err(Error::Color);
            }
            let p = moxcms::ParametricCurve::new(values).ok_or(Error::Color)?;
            if p.a <= 0.0 || p.c < 0.0 || p.a * p.d.max(0.0) + p.b < 0.0 {
                return Err(Error::Color);
            }
            if (0.0..=1.0).contains(&p.d) {
                let upper = (p.a * p.d + p.b).powf(p.g) + p.e;
                let lower = p.c * p.d + p.f;
                if !upper.is_finite() || upper + 0.0001 < lower {
                    return Err(Error::Color);
                }
            }
        }
    }
    let evaluator = curve.make_linear_evaluator().map_err(|_| Error::Color)?;
    let mut previous = -0.0001;
    for sample in 0..=4096 {
        let value = evaluator.evaluate_value(sample as f32 / 4096.0);
        if !value.is_finite() || !(-0.0001..=1.0001).contains(&value) || value + 0.00001 < previous
        {
            return Err(Error::Color);
        }
        previous = value;
    }
    if previous < 0.5 {
        return Err(Error::Color);
    }
    Ok(())
}
