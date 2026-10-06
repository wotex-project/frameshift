import frameshift_decisions as decisions
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn dwell_bounds_test() {
  assert decisions.select_dwell(180_000, 60_000) == Ok(180_000)
  assert decisions.select_dwell(180_000, 360_000) == Ok(360_000)
  assert decisions.select_dwell(0, 360_000) == Error(decisions.InvalidInput)
  let outside_safe_range = 9_007_199_254_740_991 + 1
  assert decisions.select_dwell(180_000, outside_safe_range)
    == Error(decisions.InvalidInput)
}

pub fn rgb24_profile_choice_test() {
  let photo = rgb_profile("photo", 1600, 1200, 5_760_000)
  let paper = rgb_profile("paper", 800, 600, 1_440_000)
  let profiles = [photo, paper]

  assert decisions.select_rgb24_profile(
      profiles,
      "",
      "continuous",
      ["srgb"],
      "srgb",
    )
    == Ok("paper")
  assert decisions.select_rgb24_profile(
      profiles,
      "photo",
      "continuous",
      ["srgb"],
      "srgb",
    )
    == Ok("photo")
  assert decisions.select_rgb24_profile(
      profiles,
      "pixel",
      "continuous",
      ["srgb"],
      "srgb",
    )
    == Error(decisions.UnsupportedProfile)
}

pub fn rgb24_profile_refusal_test() {
  let too_small = rgb_profile("small", 1600, 1200, 5_759_999)
  let compatible = rgb_profile("good", 1600, 1200, 5_760_000)
  let profiles = [too_small, compatible]

  assert decisions.select_rgb24_profile(
      profiles,
      "",
      "continuous",
      ["srgb"],
      "srgb",
    )
    == Ok("good")
  assert decisions.select_rgb24_profile(
      profiles,
      "small",
      "continuous",
      ["srgb"],
      "srgb",
    )
    == Error(decisions.UnsupportedProfile)
  assert decisions.select_rgb24_profile(
      profiles,
      "",
      "continuous",
      ["display-p3"],
      "srgb",
    )
    == Error(decisions.UnsupportedProfile)
  assert decisions.select_rgb24_profile(
      profiles,
      "",
      "indexed",
      ["srgb"],
      "srgb",
    )
    == Error(decisions.UnsupportedProfile)
}

pub fn rgb24_duplicate_refusal_test() {
  let profile = rgb_profile("same", 800, 600, 1_440_000)
  assert decisions.select_rgb24_profile(
      [profile, profile],
      "",
      "continuous",
      ["srgb"],
      "srgb",
    )
    == Error(decisions.UnsupportedProfile)
}

fn rgb_profile(id: String, width: Int, height: Int, maximum_asset_bytes: Int) {
  decisions.RasterCandidate(
    id: id,
    width: width,
    height: height,
    maximum_asset_bytes: maximum_asset_bytes,
    channel_order: "rgb",
    bit_depth: 8,
    compression: "none",
    row_alignment: 1,
    byte_order: "not-applicable",
  )
}

pub fn direct_confirmation_test() {
  assert decisions.direct_confirmation(
      3,
      "request",
      "digest",
      "pending",
      3,
      "request",
      "digest",
      "displayed",
    )
    == Ok(decisions.Commit)

  assert decisions.direct_confirmation(
      3,
      "request",
      "digest",
      "pending",
      3,
      "request",
      "digest",
      "pending",
    )
    == Ok(decisions.StillPending)

  assert decisions.direct_confirmation(
      3,
      "request",
      "digest",
      "displayed",
      3,
      "request",
      "digest",
      "displayed",
    )
    == Ok(decisions.Already)

  assert decisions.direct_confirmation(
      3,
      "request",
      "digest",
      "pending",
      4,
      "request",
      "digest",
      "displayed",
    )
    == Error(decisions.Conflict)

  assert decisions.direct_confirmation(
      3,
      "request",
      "digest",
      "pending",
      3,
      "other",
      "digest",
      "displayed",
    )
    == Error(decisions.Conflict)

  assert decisions.direct_confirmation(
      3,
      "request",
      "digest",
      "unknown",
      3,
      "request",
      "digest",
      "displayed",
    )
    == Error(decisions.InvalidInput)
}

pub fn pull_confirmation_test() {
  assert decisions.pull_confirmation(
      3,
      "digest",
      3,
      "digest",
      "verified",
      "displayed",
    )
    == Ok(decisions.Commit)

  assert decisions.pull_confirmation(3, "digest", 3, "", "verified", "failed")
    == Ok(decisions.StillPending)

  assert decisions.pull_confirmation(
      3,
      "digest",
      3,
      "digest",
      "unchanged",
      "displayed",
    )
    == Ok(decisions.Commit)

  assert decisions.pull_confirmation(
      3,
      "digest",
      3,
      "digest",
      "verified",
      "not-requested",
    )
    == Ok(decisions.StillPending)

  assert decisions.pull_confirmation(
      3,
      "digest",
      4,
      "digest",
      "verified",
      "displayed",
    )
    == Error(decisions.Conflict)

  assert decisions.pull_confirmation(
      3,
      "digest",
      3,
      "digest",
      "failed",
      "displayed",
    )
    == Error(decisions.StorageNotVerified)

  assert decisions.pull_confirmation(
      3,
      "digest",
      3,
      "other",
      "verified",
      "displayed",
    )
    == Error(decisions.CurrentAssetMismatch)
}

fn indexed4_profile(id: String) {
  decisions.Indexed4Candidate(
    raster: decisions.RasterCandidate(
      id,
      8,
      4,
      16,
      "palette-index",
      4,
      "none",
      1,
      "not-applicable",
    ),
    packing: "indexed4-msb-row-major-v1",
    palette_revision: "test-palette-v1",
    color_profile_revision: "test-color-v1",
  )
}

pub fn indexed4_selection_and_refusal_test() {
  let palette = [
    decisions.PaletteEntry(5, 0, 0, 255),
    decisions.PaletteEntry(6, 0, 255, 0),
  ]
  let first = indexed4_profile("a")
  let later = indexed4_profile("z")
  assert decisions.select_indexed4_profile(
      [later, first],
      "",
      "restricted-palette",
      "test-color-v1",
      palette,
    )
    == Ok("a")
  assert decisions.select_indexed4_profile(
      [first, later],
      "z",
      "restricted-palette",
      "test-color-v1",
      palette,
    )
    == Ok("z")
  assert decisions.select_indexed4_profile(
      [first, first],
      "a",
      "restricted-palette",
      "test-color-v1",
      palette,
    )
    == Error(decisions.UnsupportedProfile)
  let small =
    decisions.Indexed4Candidate(
      ..first,
      raster: decisions.RasterCandidate(..first.raster, maximum_asset_bytes: 15),
    )
  let odd =
    decisions.Indexed4Candidate(
      ..first,
      raster: decisions.RasterCandidate(..first.raster, width: 7),
    )
  let unknown = decisions.Indexed4Candidate(..first, packing: "indexed4-lsb")
  let stale =
    decisions.Indexed4Candidate(..first, color_profile_revision: "stale")
  let unversioned = decisions.Indexed4Candidate(..first, palette_revision: "")
  assert decisions.select_indexed4_profile(
      [small, odd, unknown, stale, unversioned],
      "",
      "restricted-palette",
      "test-color-v1",
      palette,
    )
    == Error(decisions.UnsupportedProfile)
  assert decisions.select_indexed4_profile(
      [first],
      "",
      "continuous",
      "test-color-v1",
      palette,
    )
    == Error(decisions.UnsupportedProfile)
  assert decisions.select_indexed4_profile(
      [first],
      "",
      "restricted-palette",
      "",
      palette,
    )
    == Error(decisions.UnsupportedProfile)
  assert decisions.select_indexed4_profile(
      [first],
      "missing",
      "restricted-palette",
      "test-color-v1",
      palette,
    )
    == Error(decisions.UnsupportedProfile)
}

pub fn indexed4_palette_contract_test() {
  let first = indexed4_profile("a")
  let duplicate = [
    decisions.PaletteEntry(5, 0, 0, 255),
    decisions.PaletteEntry(5, 0, 255, 0),
  ]
  let large_code = [
    decisions.PaletteEntry(16, 0, 0, 255),
    decisions.PaletteEntry(6, 0, 255, 0),
  ]
  let bad_rgb = [
    decisions.PaletteEntry(5, -1, 0, 255),
    decisions.PaletteEntry(6, 0, 255, 0),
  ]
  assert decisions.select_indexed4_profile(
      [first],
      "",
      "restricted-palette",
      "test-color-v1",
      duplicate,
    )
    == Error(decisions.UnsupportedProfile)
  assert decisions.select_indexed4_profile(
      [first],
      "",
      "restricted-palette",
      "test-color-v1",
      large_code,
    )
    == Error(decisions.UnsupportedProfile)
  assert decisions.select_indexed4_profile(
      [first],
      "",
      "restricted-palette",
      "test-color-v1",
      bad_rgb,
    )
    == Error(decisions.UnsupportedProfile)
  assert decisions.select_indexed4_profile(
      [first],
      "",
      "restricted-palette",
      "test-color-v1",
      [],
    )
    == Error(decisions.UnsupportedProfile)
}
