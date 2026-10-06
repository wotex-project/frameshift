// Pure, cross-target decisions used by the host and installation guide.
import gleam/list
import gleam/order
import gleam/string

pub type Decision {
  Commit
  Already
  StillPending
}

pub type Refusal {
  InvalidInput
  Conflict
  StorageNotVerified
  CurrentAssetMismatch
  UnsupportedProfile
}

pub type RasterCandidate {
  RasterCandidate(
    id: String,
    width: Int,
    height: Int,
    maximum_asset_bytes: Int,
    channel_order: String,
    bit_depth: Int,
    compression: String,
    row_alignment: Int,
    byte_order: String,
  )
}

pub type PaletteEntry {
  PaletteEntry(wire_code: Int, red: Int, green: Int, blue: Int)
}

pub type Indexed4Candidate {
  Indexed4Candidate(
    raster: RasterCandidate,
    packing: String,
    palette_revision: String,
    color_profile_revision: String,
  )
}

pub fn select_dwell(
  minimum_ms: Int,
  requested_ms: Int,
) -> Result(Int, Refusal) {
  case safe_positive(minimum_ms) && safe_positive(requested_ms) {
    True ->
      case requested_ms >= minimum_ms {
        True -> Ok(requested_ms)
        False -> Ok(minimum_ms)
      }

    False -> Error(InvalidInput)
  }
}

pub fn select_rgb24_profile(
  candidates: List(RasterCandidate),
  requested_id: String,
  color_kind: String,
  color_spaces: List(String),
  transfer_function: String,
) -> Result(String, Refusal) {
  candidates
  |> list.map(fn(candidate) {
    #(
      candidate.id,
      compatible_rgb24(candidate, color_kind, color_spaces, transfer_function),
    )
  })
  |> select_profile_ids(requested_id, [], "")
}

pub fn select_indexed4_profile(
  candidates: List(Indexed4Candidate),
  requested_id: String,
  color_kind: String,
  color_revision: String,
  palette: List(PaletteEntry),
) -> Result(String, Refusal) {
  let color_valid =
    color_kind == "restricted-palette"
    && color_revision != ""
    && list.length(palette) >= 2
    && list.length(palette) <= 16
    && valid_palette(palette, [])
  candidates
  |> list.map(fn(candidate) {
    #(
      candidate.raster.id,
      color_valid && compatible_indexed4(candidate, color_revision),
    )
  })
  |> select_profile_ids(requested_id, [], "")
}

fn select_profile_ids(
  candidates: List(#(String, Bool)),
  requested_id: String,
  seen: List(String),
  best_id: String,
) -> Result(String, Refusal) {
  case candidates {
    [] ->
      case best_id {
        "" -> Error(UnsupportedProfile)
        _ -> Ok(best_id)
      }
    [#(id, compatible), ..rest] ->
      case contains_id(seen, id) {
        True -> Error(UnsupportedProfile)
        False -> {
          let better =
            compatible
            && id != ""
            && { requested_id == "" || id == requested_id }
            && { best_id == "" || string.compare(id, best_id) == order.Lt }
          let next_best = case better {
            True -> id
            False -> best_id
          }
          select_profile_ids(rest, requested_id, [id, ..seen], next_best)
        }
      }
  }
}

fn contains_id(ids: List(String), id: String) -> Bool {
  case ids {
    [] -> False
    [first, ..rest] -> first == id || contains_id(rest, id)
  }
}

fn valid_palette(entries: List(PaletteEntry), seen: List(Int)) -> Bool {
  case entries {
    [] -> True
    [entry, ..rest] ->
      entry.wire_code >= 0
      && entry.wire_code <= 15
      && !list.contains(seen, entry.wire_code)
      && byte(entry.red)
      && byte(entry.green)
      && byte(entry.blue)
      && valid_palette(rest, [entry.wire_code, ..seen])
  }
}

fn byte(value: Int) -> Bool {
  value >= 0 && value <= 255
}

fn compatible_indexed4(
  candidate: Indexed4Candidate,
  color_revision: String,
) -> Bool {
  let raster = candidate.raster
  let dimensions_valid =
    raster.width > 0
    && raster.width <= 32_768
    && raster.height > 0
    && raster.height <= 32_768
  case dimensions_valid {
    False -> False
    True -> {
      let pixels = raster.width * raster.height
      raster.width % 2 == 0
      && pixels <= 16_777_216
      && raster.maximum_asset_bytes >= pixels / 2
      && raster.maximum_asset_bytes <= 1_073_741_824
      && raster.channel_order == "palette-index"
      && raster.bit_depth == 4
      && raster.compression == "none"
      && raster.row_alignment == 1
      && raster.byte_order == "not-applicable"
      && candidate.packing == "indexed4-msb-row-major-v1"
      && candidate.palette_revision != ""
      && candidate.color_profile_revision == color_revision
    }
  }
}

fn compatible_rgb24(
  candidate: RasterCandidate,
  color_kind: String,
  color_spaces: List(String),
  transfer_function: String,
) -> Bool {
  let dimensions_valid =
    candidate.width > 0
    && candidate.width <= 32_768
    && candidate.height > 0
    && candidate.height <= 32_768

  case dimensions_valid {
    False -> False
    True -> {
      let pixels = candidate.width * candidate.height
      candidate.id != ""
      && pixels <= 16_777_216
      && candidate.maximum_asset_bytes >= pixels * 3
      && candidate.maximum_asset_bytes <= 1_073_741_824
      && candidate.channel_order == "rgb"
      && candidate.bit_depth == 8
      && candidate.compression == "none"
      && candidate.row_alignment == 1
      && candidate.byte_order == "not-applicable"
      && color_kind == "continuous"
      && contains_srgb(color_spaces)
      && transfer_function == "srgb"
    }
  }
}

fn contains_srgb(spaces: List(String)) -> Bool {
  case spaces {
    [] -> False
    ["srgb", ..] -> True
    [_, ..rest] -> contains_srgb(rest)
  }
}

pub fn direct_confirmation(
  intent_revision: Int,
  intent_request_id: String,
  intent_digest: String,
  intent_status: String,
  revision: Int,
  request_id: String,
  digest: String,
  outcome: String,
) -> Result(Decision, Refusal) {
  case
    safe_positive(intent_revision) && safe_positive(revision),
    valid_direct_status(intent_status) && valid_direct_status(outcome)
  {
    True, True ->
      direct_match(
        intent_revision,
        intent_request_id,
        intent_digest,
        intent_status,
        revision,
        request_id,
        digest,
        outcome,
      )

    _, _ -> Error(InvalidInput)
  }
}

fn direct_match(
  intent_revision: Int,
  intent_request_id: String,
  intent_digest: String,
  intent_status: String,
  revision: Int,
  request_id: String,
  digest: String,
  outcome: String,
) -> Result(Decision, Refusal) {
  case
    intent_revision == revision,
    intent_request_id == request_id,
    intent_digest == digest
  {
    True, True, True ->
      case intent_status, outcome {
        "displayed", _ -> Ok(Already)
        _, "pending" -> Ok(StillPending)
        _, "displayed" -> Ok(Commit)
        _, _ -> Error(InvalidInput)
      }

    _, _, _ -> Error(Conflict)
  }
}

pub fn pull_confirmation(
  manifest_revision: Int,
  desired_digest: String,
  acknowledgement_revision: Int,
  current_digest: String,
  storage: String,
  refresh: String,
) -> Result(Decision, Refusal) {
  case
    safe_positive(manifest_revision) && safe_positive(acknowledgement_revision),
    valid_storage(storage) && valid_refresh(refresh)
  {
    True, True ->
      pull_match(
        manifest_revision,
        desired_digest,
        acknowledgement_revision,
        current_digest,
        storage,
        refresh,
      )

    _, _ -> Error(InvalidInput)
  }
}

fn pull_match(
  manifest_revision: Int,
  desired_digest: String,
  acknowledgement_revision: Int,
  current_digest: String,
  storage: String,
  refresh: String,
) -> Result(Decision, Refusal) {
  case manifest_revision == acknowledgement_revision, refresh {
    False, _ -> Error(Conflict)
    True, "not-requested" -> Ok(StillPending)
    True, "failed" -> Ok(StillPending)
    True, "displayed" -> displayed_pull(desired_digest, current_digest, storage)
    _, _ -> Error(InvalidInput)
  }
}

fn displayed_pull(
  desired_digest: String,
  current_digest: String,
  storage: String,
) -> Result(Decision, Refusal) {
  case storage, desired_digest == current_digest {
    "failed", _ -> Error(StorageNotVerified)
    _, False -> Error(CurrentAssetMismatch)
    _, True -> Ok(Commit)
  }
}

fn safe_positive(value: Int) -> Bool {
  value > 0 && value <= 9_007_199_254_740_991
}

fn valid_direct_status(status: String) -> Bool {
  case status {
    "pending" | "displayed" -> True
    _ -> False
  }
}

fn valid_storage(storage: String) -> Bool {
  case storage {
    "verified" | "unchanged" | "failed" -> True
    _ -> False
  }
}

fn valid_refresh(refresh: String) -> Bool {
  case refresh {
    "not-requested" | "displayed" | "failed" -> True
    _ -> False
  }
}
