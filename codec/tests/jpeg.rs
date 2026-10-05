use frameshift_codec::{Error, HEADER_BYTES, header, normalize};
use jpeg_encoder::{ColorType, Encoder, SamplingFactor};
use moxcms::ColorProfile;
use sha2::{Digest, Sha256};
use std::io::Write;
use std::process::{Command, Stdio};

fn image(progressive: bool, sampling: SamplingFactor, gray: bool, restart: u16) -> Vec<u8> {
    let pixels: Vec<u8> = (0..19 * 17 * if gray { 1 } else { 3 })
        .map(|n| ((n * 37 + n / 17) % 256) as u8)
        .collect();
    let mut source = Vec::new();
    let mut encoder = Encoder::new(&mut source, 90);
    encoder.set_sampling_factor(sampling);
    encoder.set_progressive(progressive);
    encoder.set_restart_interval(restart);
    encoder
        .encode(
            &pixels,
            19,
            17,
            if gray {
                ColorType::Luma
            } else {
                ColorType::Rgb
            },
        )
        .unwrap();
    source
}

fn segment(marker: u8, data: &[u8]) -> Vec<u8> {
    [
        vec![255, marker],
        ((data.len() + 2) as u16).to_be_bytes().to_vec(),
        data.to_vec(),
    ]
    .concat()
}
fn insert(source: &[u8], marker: u8, data: &[u8], trailing: bool) -> Vec<u8> {
    let at = if trailing { source.len() - 2 } else { 2 };
    [
        source[..at].to_vec(),
        segment(marker, data),
        source[at..].to_vec(),
    ]
    .concat()
}
fn exif(orientation: &[u16], space: &[u16]) -> Vec<u8> {
    let mut raw = b"Exif\0\0II\x2a\0\x08\0\0\0".to_vec();
    raw.extend_from_slice(
        &((orientation.len() + usize::from(!space.is_empty())) as u16).to_le_bytes(),
    );
    for value in orientation {
        raw.extend_from_slice(&[0x12, 0x01, 3, 0, 1, 0, 0, 0]);
        raw.extend_from_slice(&value.to_le_bytes());
        raw.extend_from_slice(&[0; 2]);
    }
    if !space.is_empty() {
        // Exif sub-IFD pointer in the primary TIFF directory.
        let offset = 8 + 2 + 12 * (orientation.len() + 1) + 4;
        raw.extend_from_slice(&[0x69, 0x87, 4, 0, 1, 0, 0, 0]);
        raw.extend_from_slice(&(offset as u32).to_le_bytes());
        raw.extend_from_slice(&[0; 4]);
        raw.extend_from_slice(&(space.len() as u16).to_le_bytes());
        for value in space {
            raw.extend_from_slice(&[0x01, 0xa0, 3, 0, 1, 0, 0, 0]);
            raw.extend_from_slice(&value.to_le_bytes());
            raw.extend_from_slice(&[0; 2]);
        }
    }
    raw.extend_from_slice(&[0; 4]);
    raw
}
fn icc(source: &[u8], profile: &[u8], trailing: bool) -> Vec<u8> {
    let split = profile.len() / 2;
    let mut result = source.to_vec();
    // Out-of-order chunks are legal; neither decoder ordering nor early metadata wins.
    for (seq, bytes) in [(2, &profile[split..]), (1, &profile[..split])] {
        let data = [b"ICC_PROFILE\0".as_slice(), &[seq, 2], bytes].concat();
        result = insert(&result, 0xe2, &data, trailing);
    }
    result
}
fn profile() -> Vec<u8> {
    let mut profile = ColorProfile::new_display_p3();
    profile.cicp = None;
    let bytes = profile.encode().unwrap();
    // Generated header date is not part of this fixture's identity.
    let mut bytes = bytes.to_vec();
    bytes[24..36].copy_from_slice(&[0x07, 0xea, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0]);
    bytes[84..100].fill(0);
    bytes
}
fn scan_ranges(source: &[u8]) -> Vec<(usize, usize, usize)> {
    let mut ranges = Vec::new();
    let mut offset = 2;
    while offset < source.len() {
        assert_eq!(source[offset], 255);
        let marker = source[offset + 1];
        if marker == 0xd9 {
            break;
        }
        let end = offset
            + 2
            + u16::from_be_bytes(source[offset + 2..offset + 4].try_into().unwrap()) as usize;
        if marker == 0xda {
            let mut scan_end = end;
            loop {
                if source[scan_end] == 255
                    && source[scan_end + 1] != 0
                    && !(0xd0..=0xd7).contains(&source[scan_end + 1])
                {
                    break;
                }
                scan_end += if source[scan_end] == 255 { 2 } else { 1 };
            }
            ranges.push((offset, end, scan_end));
            offset = scan_end;
        } else {
            offset = end;
        }
    }
    ranges
}

#[test]
fn baseline_progressive_gray_common_sampling_and_restart_decode_every_block() {
    for progressive in [false, true] {
        for gray in [false, true] {
            for sampling in [
                SamplingFactor::F_1_1,
                SamplingFactor::F_2_1,
                SamplingFactor::F_1_2,
                SamplingFactor::F_2_2,
            ] {
                for restart in [0, 1, 3] {
                    let source = image(progressive, sampling, gray, restart);
                    let normalized = normalize(&source).unwrap_or_else(|e| panic!("{e:?} progressive={progressive} gray={gray} sampling={sampling:?} restart={restart}"));
                    assert_eq!(
                        (
                            normalized.width,
                            normalized.height,
                            normalized.media,
                            normalized.orientation,
                            normalized.color
                        ),
                        (19, 17, 2, 1, 1)
                    );
                    assert_eq!(normalized.rgba.len(), 19 * 17 * 4);
                    assert!(normalized.rgba.chunks_exact(4).all(|p| p[3] == 255));
                    if gray {
                        assert!(
                            normalized
                                .rgba
                                .chunks_exact(4)
                                .all(|p| p[0] == p[1] && p[1] == p[2])
                        );
                    }
                }
            }
        }
    }
}

#[test]
fn every_scan_entropy_deletion_and_forged_eoi_refuse() {
    for progressive in [false, true] {
        let source = image(progressive, SamplingFactor::F_2_2, false, 0);
        normalize(&source).unwrap();
        for (marker, start, end) in scan_ranges(&source) {
            for keep in start..end {
                let forged = [source[..keep].to_vec(), vec![255, 217]].concat();
                assert!(
                    normalize(&forged).is_err(),
                    "forged EOI progressive={progressive} scan={marker} offset={keep}"
                );
                let deletion = [source[..keep].to_vec(), source[end..].to_vec()].concat();
                assert!(
                    normalize(&deletion).is_err(),
                    "deleted entropy progressive={progressive} scan={marker} offset={keep}"
                );
            }
        }
        for cutoff in 0..source.len() {
            assert!(normalize(&source[..cutoff]).is_err());
        }
    }
}

#[test]
fn complete_container_refuses_extra_bytes_images_entropy_and_invalid_padding() {
    let source = image(false, SamplingFactor::F_1_1, false, 0);
    for suffix in [vec![0], source.clone(), vec![255, 217]] {
        assert!(normalize(&[source.clone(), suffix].concat()).is_err());
    }
    for extra in [
        vec![0],
        vec![0xff, 0],
        vec![0xff, 0xd0],
        vec![0xff, 0xff, 0],
    ] {
        let at = source.len() - 2;
        let changed = [source[..at].to_vec(), extra, source[at..].to_vec()].concat();
        assert!(normalize(&changed).is_err());
    }
    // Gray constant DC/AC stream has terminal padding; a zero padding bit is invalid.
    let mut bytes = Vec::new();
    Encoder::new(&mut bytes, 90)
        .encode(&[128; 64], 8, 8, ColorType::Luma)
        .unwrap();
    let (_, _, end) = scan_ranges(&bytes)[0];
    bytes[end - 1] &= 0xfe;
    assert!(normalize(&bytes).is_err());
}

#[test]
fn all_orientations_match_exact_pixel_permutations_with_late_metadata() {
    let source = image(true, SamplingFactor::F_1_1, false, 0);
    let original = normalize(&source).unwrap();
    for orientation in 1..=8 {
        for trailing in [false, true] {
            let normalized =
                normalize(&insert(&source, 0xe1, &exif(&[orientation], &[]), trailing)).unwrap();
            assert_eq!(normalized.orientation, orientation as u8);
            let (w, h) = if orientation < 5 { (19, 17) } else { (17, 19) };
            assert_eq!((normalized.width, normalized.height), (w, h));
            for y in 0..17 {
                for x in 0..19 {
                    let (ox, oy) = match orientation {
                        1 => (x, y),
                        2 => (18 - x, y),
                        3 => (18 - x, 16 - y),
                        4 => (x, 16 - y),
                        5 => (y, x),
                        6 => (16 - y, x),
                        7 => (16 - y, 18 - x),
                        8 => (y, 18 - x),
                        _ => unreachable!(),
                    };
                    let a = ((y * 19 + x) * 4) as usize;
                    let b = ((oy * w + ox) * 4) as usize;
                    assert_eq!(&original.rgba[a..a + 4], &normalized.rgba[b..b + 4]);
                }
            }
        }
    }
}

#[test]
fn primary_exif_color_and_orientation_never_hide_malformed_or_duplicate_fields() {
    let source = image(false, SamplingFactor::F_1_1, false, 0);
    for values in [vec![0], vec![9], vec![1, 1], vec![1, 6]] {
        assert!(normalize(&insert(&source, 0xe1, &exif(&values, &[]), false)).is_err());
    }
    for values in [vec![2], vec![65535], vec![1, 1], vec![1, 65535]] {
        assert!(normalize(&insert(&source, 0xe1, &exif(&[1], &values), false)).is_err());
    }
    let bytes = insert(&source, 0xe1, &exif(&[6], &[1]), true);
    let normalized = normalize(&bytes).unwrap();
    assert_eq!((normalized.color, normalized.orientation), (7, 6));
    assert!(normalize(&insert(&bytes, 0xe1, &exif(&[6], &[1]), false)).is_err());
    assert!(normalize(&insert(&source, 0xe1, b"Exif\0\0invalid", false)).is_err());
}

#[test]
fn complete_out_of_order_late_icc_converts_and_binds_exact_profile() {
    let source = image(false, SamplingFactor::F_1_1, false, 0);
    let original = normalize(&source).unwrap();
    let profile = profile();
    for trailing in [false, true] {
        let source = icc(&source, &profile, trailing);
        let normalized = normalize(&source).unwrap();
        assert_eq!(normalized.color, 5);
        assert_eq!(
            normalized.profile_digest,
            <[u8; 32]>::from(Sha256::digest(&profile))
        );
        assert_ne!(normalized.rgba, original.rgba);
        assert!(normalize(&insert(&source, 0xe1, &exif(&[1], &[1]), false)).is_err());
        assert_eq!(
            normalize(&insert(&source, 0xe1, &exif(&[1], &[65535]), false))
                .unwrap()
                .rgba,
            normalized.rgba
        );
    }
}

#[test]
fn incomplete_duplicate_conflicting_or_malformed_icc_never_becomes_assumed_srgb() {
    let source = image(false, SamplingFactor::F_1_1, false, 0);
    let profile = profile();
    let first = [b"ICC_PROFILE\0".as_slice(), &[1, 2], &profile[..100]].concat();
    let source = insert(&source, 0xe2, &first, true);
    assert!(normalize(&source).is_err());
    assert!(normalize(&insert(&source, 0xe2, &first, false)).is_err());
    for count in [0, 1, 3, 255] {
        let chunk = [b"ICC_PROFILE\0".as_slice(), &[2, count], &profile[100..]].concat();
        assert!(normalize(&insert(&source, 0xe2, &chunk, false)).is_err());
    }
    for data in [
        b"ICC_PROFILE\0".to_vec(),
        [b"ICC_PROFILE\0".as_slice(), &[1, 1], b"invalid"].concat(),
    ] {
        assert!(
            normalize(&insert(
                &image(false, SamplingFactor::F_1_1, false, 0),
                0xe2,
                &data,
                false
            ))
            .is_err()
        );
    }
    let mut lut = profile.clone();
    lut[132..136].copy_from_slice(b"A2B0");
    assert!(
        normalize(&icc(
            &image(false, SamplingFactor::F_1_1, false, 0),
            &lut,
            false
        ))
        .is_err()
    );
    assert!(
        normalize(&icc(
            &image(false, SamplingFactor::F_1_1, true, 0),
            &profile,
            false
        ))
        .is_err()
    );
}

#[test]
fn extensions_and_metadata_between_scans_or_after_last_scan_refuse() {
    let source = image(true, SamplingFactor::F_1_1, false, 0);
    for (marker, data) in [
        (0xe1, b"http://ns.adobe.com/xap/1.0/\0hdr".as_slice()),
        (0xe2, b"MPF\0multiple"),
        (0xeb, b"JP\0hdr"),
        (0xe8, b"SPIFF\0"),
        (0xed, b"Photoshop 3.0\0"),
        (0xe0, b"JFXX\0"),
    ] {
        for trailing in [false, true] {
            assert!(normalize(&insert(&source, marker, data, trailing)).is_err());
        }
        let (_, _, end) = scan_ranges(&source)[0];
        let altered = [
            source[..end].to_vec(),
            segment(marker, data),
            source[end..].to_vec(),
        ]
        .concat();
        assert!(normalize(&altered).is_err());
    }
}

#[test]
fn unsupported_coding_sampling_and_bad_geometry_refuse_before_allocation() {
    let source = image(false, SamplingFactor::F_1_1, false, 0);
    let at = source.windows(2).position(|b| b == [255, 192]).unwrap();
    for marker in [0xc1, 0xc3, 0xc9, 0xca, 0xcc, 0xdc, 0xde] {
        let mut changed = source.clone();
        changed[at + 1] = marker;
        assert!(normalize(&changed).is_err());
    }
    for field in [4, 9] {
        let mut changed = source.clone();
        changed[at + field] = 12;
        assert!(normalize(&changed).is_err());
    }
    for (width, height) in [(0u16, 1u16), (1, 0), (32769, 1), (8192, 8192)] {
        let mut changed = source.clone();
        changed[at + 5..at + 7].copy_from_slice(&height.to_be_bytes());
        changed[at + 7..at + 9].copy_from_slice(&width.to_be_bytes());
        assert!(matches!(normalize(&changed), Err(Error::Bounds)));
    }
    assert!(matches!(
        normalize(&image(false, SamplingFactor::F_4_1, false, 0)),
        Err(Error::Unsupported)
    ));
}

#[test]
fn scan_progression_restart_sequence_and_metadata_bounds_refuse() {
    let source = image(true, SamplingFactor::F_1_1, false, 0);
    let ranges = scan_ranges(&source);
    let (at, start, end) = ranges[1];
    let changed = [
        source[..end].to_vec(),
        source[at..end].to_vec(),
        source[end..].to_vec(),
    ]
    .concat();
    assert!(normalize(&changed).is_err());
    let mut changed = source.clone();
    changed[start - 1] = 0x31;
    assert!(normalize(&changed).is_err());
    let source = image(false, SamplingFactor::F_1_1, false, 1);
    let at = source.windows(2).position(|b| b == [255, 208]).unwrap();
    let mut changed = source.clone();
    changed[at + 1] = 210;
    assert!(normalize(&changed).is_err());
    let comment = segment(0xfe, &[0; 65530]);
    let source = image(false, SamplingFactor::F_1_1, false, 0);
    let mut huge = source[..2].to_vec();
    for _ in 0..65 {
        huge.extend_from_slice(&comment);
    }
    huge.extend_from_slice(&source[2..]);
    assert!(matches!(normalize(&huge), Err(Error::Bounds)));
}

#[test]
fn original_mutation_corpus_never_panics() {
    for progressive in [false, true] {
        let source = image(progressive, SamplingFactor::F_2_2, false, 0);
        for offset in 0..source.len() {
            for value in [0, 1, 127, 255] {
                let mut changed = source.clone();
                changed[offset] = value;
                assert!(
                    std::panic::catch_unwind(|| normalize(&changed)).is_ok(),
                    "offset {offset}"
                );
            }
        }
    }
}

#[test]
fn process_result_has_exact_jpeg_media_and_no_error_payload_or_diagnostic() {
    let source = image(true, SamplingFactor::F_2_2, false, 1);
    let normalized = normalize(&source).unwrap();
    let expected = [
        header(&Ok(normalized)).to_vec(),
        normalize(&source).unwrap().rgba,
    ]
    .concat();
    for (source, success) in [(source, true), (vec![255, 216, 255, 217], false)] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_frameshift-codec"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(&[(source.len() as u32).to_be_bytes().as_slice(), &source].concat())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert!(output.stderr.is_empty());
        if success {
            assert_eq!(output.stdout, expected);
            assert_eq!(output.stdout[17], 2);
        } else {
            assert_eq!(output.stdout.len(), HEADER_BYTES);
            assert_ne!(output.stdout[6], 0);
            assert!(output.stdout[7..].iter().all(|v| *v == 0));
        }
    }
}

#[test]
fn jpeg_cohort_golden_digest() {
    let mut digest = Sha256::new();
    let profile = profile();
    for progressive in [false, true] {
        for gray in [false, true] {
            for sampling in [
                SamplingFactor::F_1_1,
                SamplingFactor::F_2_1,
                SamplingFactor::F_1_2,
                SamplingFactor::F_2_2,
            ] {
                for restart in [0, 1, 3] {
                    let source = image(progressive, sampling, gray, restart);
                    for orientation in [1, 6] {
                        let source = insert(&source, 0xe1, &exif(&[orientation], &[]), true);
                        let normalized = normalize(&source);
                        digest.update(header(&normalized));
                        digest.update(normalized.unwrap().rgba);
                    }
                }
            }
        }
    }
    let source = image(false, SamplingFactor::F_1_1, false, 0);
    for trailing in [false, true] {
        let normalized = normalize(&icc(&source, &profile, trailing));
        digest.update(header(&normalized));
        digest.update(normalized.unwrap().rgba);
    }
    let actual = digest
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    assert_eq!(
        actual,
        "8b65e9848b51bc0b213f59f9d7482fe1e6962235c766a8b3397763465d4ef593"
    );
}

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
        let next = output.len() as u32;
        output[start + 4..start + 8].copy_from_slice(&next.to_be_bytes());
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
fn grayscale_icc_transforms_known_linear_samples_and_rejects_rgb_source() {
    let mut bytes = Vec::new();
    Encoder::new(&mut bytes, 100)
        .encode(&[128; 64], 8, 8, ColorType::Luma)
        .unwrap();
    let original = normalize(&bytes).unwrap();
    assert_eq!(original.rgba[0], 128);
    let mut profile = ColorProfile::new_gray_with_gamma(1.0);
    profile.cicp = None;
    let profile = align_icc(&profile.encode().unwrap());
    let normalized = normalize(&icc(&bytes, &profile, true)).unwrap();
    assert_eq!(normalized.color, 5);
    // Independent standard sRGB encoding of the decoded linear sample.
    let expected = ((1.055 * (128.0f64 / 255.0).powf(1.0 / 2.4) - 0.055) * 255.0).round() as u8;
    assert!(
        normalized
            .rgba
            .chunks_exact(4)
            .all(|p| p[..3].iter().all(|v| v.abs_diff(expected) <= 1) && p[3] == 255)
    );
    assert!(
        normalize(&icc(
            &image(false, SamplingFactor::F_1_1, false, 0),
            &profile,
            false
        ))
        .is_err()
    );
}

fn rgb_components(source: &[u8]) -> Vec<u8> {
    let mut bytes = source.to_vec();
    let mut offset = 2;
    while offset < bytes.len() {
        let marker = bytes[offset + 1];
        if marker == 0xd9 {
            break;
        }
        let end = offset
            + 2
            + u16::from_be_bytes(bytes[offset + 2..offset + 4].try_into().unwrap()) as usize;
        if marker == 0xe0 {
            bytes.drain(offset..end);
            continue;
        }
        if marker == 0xc0 {
            for i in 0..3 {
                bytes[offset + 10 + i * 3] = b"RGB"[i];
            }
        }
        if marker == 0xda {
            for i in 0..3 {
                bytes[offset + 5 + i * 2] = b"RGB"[i];
            }
            break;
        }
        offset = end;
    }
    bytes
}

#[test]
fn rgb_component_ids_and_adobe_transform_agree_without_color_guessing() {
    // The encoder produces three component DCT planes. Retagging the fixture
    // explicitly changes their interpretation; it never claims the old colors.
    let source = image(false, SamplingFactor::F_1_1, false, 0);
    let rgb = rgb_components(&source);
    let normalized = normalize(&rgb).unwrap();
    assert_eq!(normalized.media, 2);
    assert_ne!(normalized.rgba, normalize(&source).unwrap().rgba);
    let adobe = b"Adobe\0\x64\0\0\0\0\0";
    assert_eq!(
        normalize(&insert(&rgb, 0xee, adobe, false)).unwrap().rgba,
        normalized.rgba
    );
    let mut conflict = adobe.to_vec();
    conflict[11] = 1;
    assert!(normalize(&insert(&rgb, 0xee, &conflict, false)).is_err());
    assert!(normalize(&insert(&source, 0xee, adobe, false)).is_err());
    assert!(
        normalize(&insert(
            &image(false, SamplingFactor::F_1_1, true, 0),
            0xee,
            adobe,
            false
        ))
        .is_err()
    );
}

fn excessive_eob(restart: bool) -> Vec<u8> {
    let mut bytes = vec![255, 216];
    bytes.extend(segment(
        0xc2,
        &[8, 0, 8, 0, if restart { 16 } else { 8 }, 1, 1, 0x11, 0],
    ));
    let mut q = vec![0];
    q.extend([1; 64]);
    bytes.extend(segment(0xdb, &q));
    for (class, symbol) in [(0, 0), (0x10, 0x10)] {
        let mut table = vec![class, 1];
        table.extend([0; 15]);
        table.push(symbol);
        bytes.extend(segment(0xc4, &table));
    }
    if restart {
        bytes.extend(segment(0xdd, &[0, 1]));
    }
    bytes.extend(segment(0xda, &[1, 1, 0, 0, 0, 0]));
    bytes.push(0x7f);
    if restart {
        bytes.extend([255, 208, 0x7f]);
    }
    bytes.extend(segment(0xda, &[1, 1, 0, 1, 63, 0]));
    bytes.push(0x3f);
    if restart {
        bytes.extend([255, 208, 0x3f]);
    }
    bytes.extend([255, 217]);
    bytes
}

#[test]
fn progressive_eob_run_cannot_cross_scan_or_restart_boundary() {
    for restart in [false, true] {
        assert!(matches!(
            normalize(&excessive_eob(restart)),
            Err(Error::Malformed)
        ));
    }
}

fn exif_field(tag: u16, kind: u16, count: u32, value: [u8; 4]) -> Vec<u8> {
    let mut bytes =
        b"Exif\0\0II\x2a\0\x08\0\0\0\x01\0\x69\x87\x04\0\x01\0\0\0\x1a\0\0\0\0\0\0\0\x01\0"
            .to_vec();
    bytes.extend(tag.to_le_bytes());
    bytes.extend(kind.to_le_bytes());
    bytes.extend(count.to_le_bytes());
    bytes.extend(value);
    bytes.extend([0; 4]);
    bytes
}

#[test]
fn unqualified_exif_versions_gamma_and_invalid_color_field_types_refuse() {
    let source = image(false, SamplingFactor::F_1_1, false, 0);
    assert!(
        normalize(&insert(
            &source,
            0xe1,
            &exif_field(0x9000, 7, 4, *b"0232"),
            false
        ))
        .is_ok()
    );
    for data in [
        exif_field(0x9000, 7, 4, *b"0310"),
        exif_field(0x9000, 2, 4, *b"0232"),
        exif_field(0xa500, 4, 1, [1, 0, 0, 0]),
        exif_field(0xa001, 4, 1, [1, 0, 0, 0]),
        exif_field(0xa001, 3, 2, [1, 0, 1, 0]),
    ] {
        assert!(normalize(&insert(&source, 0xe1, &data, false)).is_err());
    }
    let last = [b"ICC_PROFILE\0".as_slice(), &[255, 255], &[1]].concat();
    assert!(normalize(&insert(&source, 0xe2, &last, false)).is_err());
}

fn sixty_four_scans() -> Vec<u8> {
    let mut bytes = vec![255, 216];
    bytes.extend(segment(0xc2, &[8, 0, 8, 0, 8, 1, 1, 0x11, 0]));
    let mut q = vec![0];
    q.extend([1; 64]);
    bytes.extend(segment(0xdb, &q));
    for class in [0, 0x10] {
        let mut table = vec![class, 1];
        table.extend([0; 15]);
        table.push(0);
        bytes.extend(segment(0xc4, &table));
    }
    for coefficient in 0..64 {
        bytes.extend(segment(0xda, &[1, 1, 0, coefficient, coefficient, 0]));
        bytes.push(0x7f);
    }
    bytes.extend([255, 217]);
    bytes
}

#[test]
fn exact_scan_marker_and_assembled_icc_resource_limits_refuse() {
    let source = sixty_four_scans();
    let normalized = normalize(&source).unwrap();
    assert_eq!(&normalized.rgba[..4], &[128, 128, 128, 255]);
    let at = source.len() - 2;
    let extra = segment(0xda, &[1, 1, 0, 63, 63, 0]);
    let changed = [
        source[..at].to_vec(),
        extra,
        vec![0x7f],
        source[at..].to_vec(),
    ]
    .concat();
    assert!(matches!(normalize(&changed), Err(Error::Bounds)));
    let source = image(false, SamplingFactor::F_1_1, false, 0);
    let mut many = source[..2].to_vec();
    for _ in 0..65536 {
        many.extend(segment(0xfe, &[]));
    }
    many.extend(&source[2..]);
    assert!(matches!(normalize(&many), Err(Error::Bounds)));
    let mut huge = source[..2].to_vec();
    for sequence in 1..=17 {
        let chunk = [b"ICC_PROFILE\0".as_slice(), &[sequence, 17], &[0; 65500]].concat();
        huge.extend(segment(0xe2, &chunk));
    }
    huge.extend(&source[2..]);
    assert!(matches!(normalize(&huge), Err(Error::Bounds)));
}
