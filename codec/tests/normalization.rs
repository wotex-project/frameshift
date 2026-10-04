use frameshift_codec::{Error, HEADER_BYTES, MAX_PIXELS, REVISION, header, normalize};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::process::{Command, Stdio};

fn png(
    width: u32,
    height: u32,
    color: png::ColorType,
    depth: png::BitDepth,
    pixels: &[u8],
) -> Vec<u8> {
    let mut bytes = Vec::new();
    let mut encoder = png::Encoder::new(&mut bytes, width, height);
    encoder.set_color(color);
    encoder.set_depth(depth);
    encoder
        .write_header()
        .unwrap()
        .write_image_data(pixels)
        .unwrap();
    bytes
}

fn chunk(tag: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut bytes = Vec::new();
    bytes.extend_from_slice(&(data.len() as u32).to_be_bytes());
    bytes.extend_from_slice(tag);
    bytes.extend_from_slice(data);
    bytes.extend_from_slice(&crc32fast::hash(&bytes[4..]).to_be_bytes());
    bytes
}

fn metadata(source: &[u8], tag: &[u8; 4], data: &[u8], trailing: bool) -> Vec<u8> {
    let split = if trailing { source.len() - 12 } else { 33 };
    [
        source[..split].to_vec(),
        chunk(tag, data),
        source[split..].to_vec(),
    ]
    .concat()
}

fn exif(values: &[u16], field_type: u16) -> Vec<u8> {
    let mut bytes = b"II\x2a\x00\x08\x00\x00\x00".to_vec();
    bytes.extend_from_slice(&(values.len() as u16).to_le_bytes());
    for value in values {
        bytes.extend_from_slice(&0x112u16.to_le_bytes());
        bytes.extend_from_slice(&field_type.to_le_bytes());
        bytes.extend_from_slice(&1u32.to_le_bytes());
        bytes.extend_from_slice(&value.to_le_bytes());
        bytes.extend_from_slice(&[0, 0]);
    }
    bytes.extend_from_slice(&[0; 4]);
    bytes
}

fn rgb_fixture() -> Vec<u8> {
    png(
        3,
        2,
        png::ColorType::Rgb,
        png::BitDepth::Eight,
        &[1, 0, 0, 2, 0, 0, 3, 0, 0, 4, 0, 0, 5, 0, 0, 6, 0, 0],
    )
}
fn reds(image: &frameshift_codec::Normalized) -> Vec<u8> {
    image.rgba.chunks_exact(4).map(|p| p[0]).collect()
}

#[test]
fn all_eight_orientations_include_trailing_exif_and_axis_exchange() {
    let vectors = [
        vec![1, 2, 3, 4, 5, 6],
        vec![3, 2, 1, 6, 5, 4],
        vec![6, 5, 4, 3, 2, 1],
        vec![4, 5, 6, 1, 2, 3],
        vec![1, 4, 2, 5, 3, 6],
        vec![4, 1, 5, 2, 6, 3],
        vec![6, 3, 5, 2, 4, 1],
        vec![3, 6, 2, 5, 1, 4],
    ];
    for (index, expected) in vectors.iter().enumerate() {
        for trailing in [false, true] {
            let image = normalize(&metadata(
                &rgb_fixture(),
                b"eXIf",
                &exif(&[index as u16 + 1], 3),
                trailing,
            ))
            .unwrap();
            assert_eq!(reds(&image), *expected);
            assert_eq!(
                (image.width, image.height),
                if index < 4 { (3, 2) } else { (2, 3) }
            );
            assert_eq!(image.orientation, index as u8 + 1);
        }
    }
}

#[test]
fn orientation_never_defaults_malformed_or_duplicate_primary_tags() {
    for data in [
        exif(&[0], 3),
        exif(&[9], 3),
        exif(&[6], 4),
        exif(&[1, 1], 3),
        exif(&[1, 6], 3),
        vec![0; 22],
    ] {
        assert!(matches!(
            normalize(&metadata(&rgb_fixture(), b"eXIf", &data, false)),
            Err(Error::Metadata)
        ));
    }
    let missing = normalize(&metadata(&rgb_fixture(), b"eXIf", &exif(&[], 3), false)).unwrap();
    assert_eq!(missing.orientation, 1);
}

#[test]
fn straight_alpha_gray_and_sixteen_bit_rounding() {
    let source = png(
        3,
        1,
        png::ColorType::Rgba,
        png::BitDepth::Eight,
        &[200, 100, 20, 128, 20, 40, 80, 0, 1, 2, 3, 255],
    );
    assert_eq!(
        normalize(&source).unwrap().rgba,
        [200, 100, 20, 128, 0, 0, 0, 0, 1, 2, 3, 255]
    );
    let source = png(
        2,
        1,
        png::ColorType::GrayscaleAlpha,
        png::BitDepth::Sixteen,
        &[0x80, 0x80, 0x7f, 0x7f, 0xab, 0xcd, 0, 0],
    );
    assert_eq!(
        normalize(&source).unwrap().rgba,
        [128, 128, 128, 127, 0, 0, 0, 0]
    );
    let source = png(
        1,
        1,
        png::ColorType::Rgb,
        png::BitDepth::Sixteen,
        &[0, 129, 0, 128, 0xff, 0xff],
    );
    assert_eq!(normalize(&source).unwrap().rgba, [1, 0, 255, 255]);
}

#[test]
fn palette_and_low_bit_gray_transparency_expand_before_color() {
    let mut source = Vec::new();
    let mut encoder = png::Encoder::new(&mut source, 3, 1);
    encoder.set_color(png::ColorType::Indexed);
    encoder.set_depth(png::BitDepth::Two);
    encoder.set_palette(vec![20, 40, 60, 100, 120, 140, 1, 2, 3]);
    encoder.set_trns(vec![0, 128, 255]);
    encoder
        .write_header()
        .unwrap()
        .write_image_data(&[0b00011000])
        .unwrap();
    assert_eq!(
        normalize(&source).unwrap().rgba,
        [0, 0, 0, 0, 100, 120, 140, 128, 1, 2, 3, 255]
    );
    let source = png(
        4,
        1,
        png::ColorType::Grayscale,
        png::BitDepth::Two,
        &[0b00011011],
    );
    assert_eq!(
        normalize(&source).unwrap().rgba,
        [
            0, 0, 0, 255, 85, 85, 85, 255, 170, 170, 170, 255, 255, 255, 255, 255
        ]
    );
}

#[test]
fn declared_and_assumed_srgb_are_distinct_provenance() {
    let source = rgb_fixture();
    let assumed = normalize(&source).unwrap();
    let declared = normalize(&metadata(&source, b"sRGB", &[0], false)).unwrap();
    assert_eq!(assumed.rgba, declared.rgba);
    assert_eq!(assumed.color, 1);
    assert_eq!(declared.color, 2);
    assert_eq!(declared.profile_digest, [0; 32]);
}

#[test]
fn gamma_conversion_uses_linear_source_and_keeps_alpha() {
    let source = png(
        1,
        1,
        png::ColorType::Rgba,
        png::BitDepth::Eight,
        &[128, 64, 32, 127],
    );
    let image = normalize(&metadata(
        &source,
        b"gAMA",
        &100_000u32.to_be_bytes(),
        false,
    ))
    .unwrap();
    // Independent standard sRGB transfer of linear 128/255, 64/255, 32/255.
    for (actual, sample) in image.rgba[..3].iter().zip([128f64, 64., 32.]) {
        let linear = sample / 255.;
        let expected = ((1.055 * linear.powf(1. / 2.4) - 0.055) * 255.).round() as i16;
        assert!((i16::from(*actual) - expected).abs() <= 1);
    }
    assert_eq!(image.rgba[3], 127);
    assert_eq!(image.color, 6);
    assert_ne!(image.profile_digest, [0; 32]);
}

fn iccp(profile: &[u8]) -> Vec<u8> {
    let mut compressed =
        flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    compressed.write_all(profile).unwrap();
    [b"Profile\0\0".to_vec(), compressed.finish().unwrap()].concat()
}

fn fixed_icc(profile: &moxcms::ColorProfile) -> Vec<u8> {
    let mut bytes = profile.encode().unwrap();
    // Upstream encoding uses current time, even for an explicit profile date.
    // Freeze source fixture bytes; source-color digests intentionally include it.
    bytes[24..36].copy_from_slice(&[0x07, 0xea, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0]);
    bytes[84..100].fill(0); // optional ICC profile ID is absent in this fixture.
    bytes
}

// moxcms' writer emits unaligned gray tag offsets. Build a conforming fixture
// by padding each independent tag to an ICC four-byte boundary. The decoder
// must keep refusing the producer's unaligned representation.
fn align_icc(bytes: &[u8]) -> Vec<u8> {
    let count = u32::from_be_bytes(bytes[128..132].try_into().unwrap()) as usize;
    let mut output = bytes[..132 + count * 12].to_vec();
    for index in 0..count {
        while !output.len().is_multiple_of(4) {
            output.push(0);
        }
        let start = 132 + index * 12;
        let offset = u32::from_be_bytes(bytes[start + 4..start + 8].try_into().unwrap()) as usize;
        let length = u32::from_be_bytes(bytes[start + 8..start + 12].try_into().unwrap()) as usize;
        let new_offset = output.len() as u32;
        output[start + 4..start + 8].copy_from_slice(&new_offset.to_be_bytes());
        output.extend_from_slice(&bytes[offset..offset + length]);
    }
    while !output.len().is_multiple_of(4) {
        output.push(0);
    }
    let length = output.len() as u32;
    output[..4].copy_from_slice(&length.to_be_bytes());
    output
}

#[test]
fn p3_cicp_and_actual_matrix_icc_convert_and_fingerprint() {
    let source = png(
        2,
        1,
        png::ColorType::Rgba,
        png::BitDepth::Eight,
        &[128, 64, 32, 127, 255, 0, 0, 255],
    );
    let cicp = normalize(&metadata(&source, b"cICP", &[12, 13, 0, 1], false)).unwrap();
    let mut profile = moxcms::ColorProfile::new_display_p3();
    profile.cicp = None;
    let raw = fixed_icc(&profile);
    let icc = normalize(&metadata(&source, b"iCCP", &iccp(&raw), false)).unwrap();
    assert_eq!(cicp.color, 4);
    assert_eq!(icc.color, 5);
    assert_ne!(icc.profile_digest, cicp.profile_digest);
    // D65 P3 -> sRGB linear matrix, then standard sRGB encoding; rounded cohort.
    let linear: Vec<f64> = [128f64, 64., 32.]
        .iter()
        .map(|v| {
            let value = v / 255.;
            if value <= 0.04045 {
                value / 12.92
            } else {
                ((value + 0.055) / 1.055).powf(2.4)
            }
        })
        .collect();
    // Independent D65 P3 -> sRGB matrix; no moxcms profile/evaluator is used.
    let matrix = [
        [1.224940176, -0.224940176, 0.0],
        [-0.042056955, 1.042056955, 0.0],
        [-0.019637554, -0.078636046, 1.098273600],
    ];
    for (index, row) in matrix.iter().enumerate() {
        let value: f64 = row.iter().zip(&linear).map(|(a, b)| a * b).sum();
        let encoded = if value <= 0.0031308 {
            value * 12.92
        } else {
            1.055 * value.powf(1. / 2.4) - 0.055
        };
        assert!((i16::from(cicp.rgba[index]) - (encoded * 255.).round() as i16).abs() <= 1);
    }
    assert_eq!(cicp.rgba[3], 127);
    assert_eq!(cicp.rgba[4..], [255, 0, 0, 255]);
    for (left, right) in cicp.rgba.iter().zip(&icc.rgba) {
        assert!((i16::from(*left) - i16::from(*right)).abs() <= 1);
    }
    assert_eq!(
        normalize(&metadata(&source, b"iCCP", &iccp(&raw), false))
            .unwrap()
            .rgba,
        icc.rgba
    );
}

#[test]
fn grayscale_icc_uses_gray_trc_before_rgb_expansion() {
    let source = png(
        1,
        1,
        png::ColorType::GrayscaleAlpha,
        png::BitDepth::Eight,
        &[128, 100],
    );
    let mut profile = moxcms::ColorProfile::new_gray_with_gamma(1.0);
    profile.pcs = moxcms::DataColorSpace::Xyz;
    let raw = fixed_icc(&profile);
    assert!(matches!(
        normalize(&metadata(&source, b"iCCP", &iccp(&raw), false)),
        Err(Error::Color)
    ));
    let image = normalize(&metadata(&source, b"iCCP", &iccp(&align_icc(&raw)), false)).unwrap();
    assert!((187..=189).contains(&image.rgba[0]));
    assert_eq!(image.rgba[3], 100);
}

#[test]
fn interlaced_adam7_fixture_and_large_thin_geometry() {
    let mut ihdr = [0; 13];
    ihdr[..4].copy_from_slice(&3u32.to_be_bytes());
    ihdr[4..8].copy_from_slice(&2u32.to_be_bytes());
    ihdr[8] = 8;
    ihdr[9] = 2;
    ihdr[12] = 1;
    let scanlines = [
        0, 1, 0, 0, 0, 3, 0, 0, 0, 2, 0, 0, 0, 4, 0, 0, 5, 0, 0, 6, 0, 0,
    ];
    let mut zlib = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    zlib.write_all(&scanlines).unwrap();
    let source = [
        b"\x89PNG\r\n\x1a\n".to_vec(),
        chunk(b"IHDR", &ihdr),
        chunk(b"IDAT", &zlib.finish().unwrap()),
        chunk(b"IEND", &[]),
    ]
    .concat();
    assert_eq!(reds(&normalize(&source).unwrap()), [1, 2, 3, 4, 5, 6]);
    let source = png(
        32_768,
        1,
        png::ColorType::Rgba,
        png::BitDepth::Eight,
        &[10, 20, 30, 40].repeat(32_768),
    );
    let image = normalize(&metadata(&source, b"eXIf", &exif(&[8], 3), false)).unwrap();
    assert_eq!((image.width, image.height), (1, 32_768));
    assert_eq!(image.rgba, [10, 20, 30, 40].repeat(32_768));
}

#[test]
fn compressed_data_checksum_is_checked_even_with_a_correct_chunk_crc() {
    let source = rgb_fixture();
    let mut offset = 8;
    let mut changed = Vec::new();
    changed.extend_from_slice(&source[..8]);
    while offset < source.len() {
        let length = u32::from_be_bytes(source[offset..offset + 4].try_into().unwrap()) as usize;
        if &source[offset + 4..offset + 8] == b"IDAT" {
            let mut data = source[offset + 8..offset + 8 + length].to_vec();
            let last = data.len() - 1;
            data[last] ^= 1;
            changed.extend_from_slice(&chunk(b"IDAT", &data));
        } else {
            changed.extend_from_slice(&source[offset..offset + 12 + length]);
        }
        offset += 12 + length;
    }
    assert!(matches!(normalize(&changed), Err(Error::Malformed)));
}

#[test]
fn image_stream_requires_exact_scanline_count_complete_checksum_and_no_second_stream() {
    let source = rgb_fixture();
    let length = u32::from_be_bytes(source[33..37].try_into().unwrap()) as usize;
    assert_eq!(&source[37..41], b"IDAT");
    let original = &source[41..41 + length];
    for data in [
        original[..original.len() - 4].to_vec(),
        [original, &[0][..]].concat(),
        [original, original].concat(),
    ] {
        let changed = [
            source[..33].to_vec(),
            chunk(b"IDAT", &data),
            chunk(b"IEND", &[]),
        ]
        .concat();
        assert!(matches!(normalize(&changed), Err(Error::Malformed)));
    }
    let fragmented = [
        source[..33].to_vec(),
        chunk(b"IDAT", &original[..1]),
        chunk(b"IDAT", &[]),
        chunk(b"IDAT", &original[1..]),
        chunk(b"IEND", &[]),
    ]
    .concat();
    assert_eq!(reds(&normalize(&fragmented).unwrap()), [1, 2, 3, 4, 5, 6]);
    let mut compressed =
        flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    compressed.write_all(&[0; 21]).unwrap(); // expected two RGB scanlines = 20 bytes
    let changed = [
        source[..33].to_vec(),
        chunk(b"IDAT", &compressed.finish().unwrap()),
        chunk(b"IEND", &[]),
    ]
    .concat();
    assert!(matches!(normalize(&changed), Err(Error::Malformed)));
}

#[test]
fn corrupt_and_unsupported_color_never_become_assumed_srgb() {
    let source = rgb_fixture();
    for (tag, data) in [
        (b"iCCP", vec![0; 20]),
        (b"iCCP", iccp(&[0; 200])),
        (b"cICP", vec![9, 16, 0, 1]),
        (b"cICP", vec![1, 13, 0, 2]),
        (b"sRGB", vec![4]),
        (b"gAMA", vec![0; 4]),
        (b"cHRM", vec![0; 32]),
        (b"mDCV", vec![0; 24]),
        (b"cLLI", vec![0; 8]),
    ] {
        assert!(matches!(
            normalize(&metadata(&source, tag, &data, false)),
            Err(Error::Color)
        ));
    }
    let contradictory = metadata(
        &metadata(&source, b"sRGB", &[0], false),
        b"gAMA",
        &100_000u32.to_be_bytes(),
        false,
    );
    assert!(matches!(normalize(&contradictory), Err(Error::Color)));
    let hidden_bad_icc = metadata(
        &metadata(&source, b"iCCP", &iccp(&[0; 200]), false),
        b"cICP",
        &[1, 13, 0, 1],
        false,
    );
    assert!(matches!(normalize(&hidden_bad_icc), Err(Error::Color)));
    let bomb = metadata(&source, b"iCCP", &iccp(&vec![0; 1024 * 1024 + 1]), false);
    assert!(matches!(normalize(&bomb), Err(Error::Bounds)));
    let mut bad = iccp(&[0; 200]);
    let last = bad.len() - 1;
    bad[last] ^= 1;
    assert!(matches!(
        normalize(&metadata(&source, b"iCCP", &bad, false)),
        Err(Error::Color)
    ));
}

#[test]
fn complete_container_checks_crc_truncation_trailing_animation_and_duplicates() {
    let source = rgb_fixture();
    for size in 0..source.len() {
        assert!(normalize(&source[..size]).is_err());
    }
    let mut trailing = source.clone();
    trailing.push(0);
    assert!(matches!(normalize(&trailing), Err(Error::Malformed)));
    for tag in [b"acTL", b"fcTL", b"fdAT"] {
        assert!(matches!(
            normalize(&metadata(&source, tag, &[0; 8], true)),
            Err(Error::Unsupported)
        ));
    }
    let duplicate = metadata(
        &metadata(&source, b"eXIf", &exif(&[1], 3), false),
        b"eXIf",
        &exif(&[1], 3),
        true,
    );
    assert!(matches!(normalize(&duplicate), Err(Error::Metadata)));
    let late = metadata(&source, b"sRGB", &[0], true);
    assert!(matches!(normalize(&late), Err(Error::Metadata)));
    let mut bad_crc = metadata(&source, b"tEXt", b"Ignored\0text", true);
    let offset = bad_crc.len() - 13;
    bad_crc[offset] ^= 1;
    assert!(matches!(normalize(&bad_crc), Err(Error::Malformed)));
}

#[test]
fn geometry_refuses_before_pixel_allocation_and_malformed_corpus_does_not_panic() {
    for (width, height) in [
        (0u32, 1u32),
        (32_769, 1),
        (4096, 4096),
        (1, MAX_PIXELS as u32 + 1),
    ] {
        let mut ihdr = [0; 13];
        ihdr[..4].copy_from_slice(&width.to_be_bytes());
        ihdr[4..8].copy_from_slice(&height.to_be_bytes());
        ihdr[8] = 8;
        ihdr[9] = 2;
        let source = [
            b"\x89PNG\r\n\x1a\n".to_vec(),
            chunk(b"IHDR", &ihdr),
            chunk(b"IDAT", &[]),
            chunk(b"IEND", &[]),
        ]
        .concat();
        assert!(matches!(normalize(&source), Err(Error::Bounds)));
    }
    let source = rgb_fixture();
    for offset in 0..source.len() {
        for byte in [0, 1, 127, 255] {
            let mut changed = source.clone();
            changed[offset] = byte;
            assert!(std::panic::catch_unwind(|| normalize(&changed)).is_ok());
        }
    }
}

fn worker(input: &[u8]) -> Vec<u8> {
    let mut child = Command::new(env!("CARGO_BIN_EXE_frameshift-codec"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    output.stdout
}

#[test]
fn real_process_frames_exact_bytes_and_refuses_framing_without_metadata_output() {
    let source = rgb_fixture();
    let image = normalize(&source).unwrap();
    let input = [&(source.len() as u32).to_be_bytes()[..], &source].concat();
    let response = worker(&input);
    assert_eq!(response[..HEADER_BYTES], header(&Ok(image)));
    assert_eq!(response.len(), HEADER_BYTES + 24);
    for bad in [
        vec![],
        vec![0; 4],
        vec![255; 4],
        [input.clone(), vec![0]].concat(),
        input[..input.len() - 1].to_vec(),
    ] {
        let output = worker(&bad);
        assert_eq!(output.len(), HEADER_BYTES);
        assert_ne!(output[6], 0);
        assert!(output[7..].iter().all(|b| *b == 0));
    }
    let output = Command::new(env!("CARGO_BIN_EXE_frameshift-codec"))
        .arg("--version")
        .output()
        .unwrap();
    assert_eq!(String::from_utf8(output.stdout).unwrap().trim(), REVISION);
    assert_eq!(
        Command::new(env!("CARGO_BIN_EXE_frameshift-codec"))
            .arg("/caller/file.png")
            .output()
            .unwrap()
            .status
            .code(),
        Some(64)
    );
}

#[test]
fn canonical_cohort_golden_digest() {
    let pixels: Vec<u8> = (0..1024)
        .flat_map(|i| {
            [
                (i % 256) as u8,
                ((i * 53) % 256) as u8,
                ((i * 97) % 256) as u8,
                ((i * 19) % 256) as u8,
            ]
        })
        .collect();
    let source = png(64, 16, png::ColorType::Rgba, png::BitDepth::Eight, &pixels);
    let mut digest = Sha256::new();
    let mut profile = moxcms::ColorProfile::new_display_p3();
    profile.cicp = None;
    let profiles = [
        (b"sRGB", vec![0]),
        (b"gAMA", 100_000u32.to_be_bytes().to_vec()),
        (b"cICP", vec![12, 13, 0, 1]),
        (b"iCCP", iccp(&fixed_icc(&profile))),
    ];
    for orientation in 1..=8 {
        let original = metadata(&source, b"eXIf", &exif(&[orientation], 3), true);
        for normalized in std::iter::once(normalize(&original)).chain(
            profiles
                .iter()
                .map(|(tag, data)| normalize(&metadata(&original, tag, data, false))),
        ) {
            digest.update(header(&normalized));
            let normalized = normalized.unwrap();
            digest.update(&normalized.rgba);
        }
    }
    let actual: String = digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    assert_eq!(
        actual,
        "12c3f441f4caf87542a9c75404510ffad3f585a772952f8b37e45c09610b6ade"
    );
}
