import FrameshiftShell
import SwiftUI

/// Edits local intent while keeping the receiver-confirmed set visible.
struct PlaylistEditor: View {
  let model: ShellModel

  var body: some View {
    if let target = model.snapshot.selectedTarget, let draft = model.playlistDraft {
      VStack(alignment: .leading, spacing: 12) {
        Text("Playlist draft").font(.title2)
        Text("\(draft.items.count) stills · frame limit \(target.maximumPlaylistLength ?? 64)")
          .foregroundStyle(.secondary)
        HStack {
          Button("Use current pins") { model.usePinnedArtwork() }
            .disabled(model.snapshot.pinnedSetTooLarge == true)
          Button("Add selected artwork") { model.addSelectedToPlaylist() }
            .disabled(model.selectedItem == nil || draft.items.count >= 64)
          if target.playlist != nil {
            Button("Reload saved set") { model.reloadSavedPlaylist() }
          }
        }
        .buttonStyle(FlatActionButtonStyle())
        if model.snapshot.pinnedSetTooLarge == true {
          Text("The pin set exceeds 64 stills. Choose individual artwork or reduce the pins.")
            .foregroundStyle(.secondary)
        }
        if draft.items.isEmpty {
          Text("Add artwork or use pins, then review the order and interval.")
            .foregroundStyle(.secondary)
        }
        ForEach(Array(draft.items.enumerated()), id: \.element.id) { index, item in
          HStack {
            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
            Text(item.title).frame(maxWidth: .infinity, alignment: .leading)
            Button {
              model.movePlaylistItem(item.id, offset: -1)
            } label: {
              Image(systemName: "arrow.up")
            }
            .disabled(index == 0)
            .help("Move up")
            .accessibilityLabel("Move \(item.title) up")
            Button {
              model.movePlaylistItem(item.id, offset: 1)
            } label: {
              Image(systemName: "arrow.down")
            }
            .disabled(index == draft.items.count - 1)
            .help("Move down")
            .accessibilityLabel("Move \(item.title) down")
            Button {
              model.removePlaylistItem(item.id)
            } label: {
              Image(systemName: "minus.circle")
            }
            .help("Remove from draft")
            .accessibilityLabel("Remove \(item.title) from playlist draft")
          }
          .buttonStyle(.borderless)
          .accessibilityElement(children: .contain)
        }
        interval(target, draft: draft)
        Button("Queue this set", systemImage: "arrow.triangle.2.circlepath") {
          Task { await model.queuePlaylist() }
        }
        .disabled(!model.canQueuePlaylist || model.actionsUnavailable)
        .accessibilityIdentifier("queue-ordered-playlist")
        if let playlist = target.playlist { savedPlaylist(target, playlist: playlist) }
      }
      .accessibilityIdentifier("playlist-editor")
    }
  }

  private func interval(_ target: FrameTarget, draft: PlaylistDraft) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let recommendation = target.recommendedDwellMs {
        Toggle(
          "Use profile suggestion · \(intervalLabel(recommendation))\(target.recommendationBasis == "provisional-profile" ? " (provisional)" : "")",
          isOn: Binding(
            get: { draft.useProfileSuggestion },
            set: { model.setPlaylistProfileSuggestion($0) }))
        if let revision = target.recommendationRevision {
          Text("Suggestion revision: \(revision)").font(.caption).foregroundStyle(.secondary)
        }
      }
      HStack {
        TextField(
          "Interval",
          text: Binding(get: { draft.intervalInput }, set: { model.setPlaylistInterval($0) })
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 120)
        .accessibilityLabel("Playlist interval")
        Picker(
          "Unit",
          selection: Binding(
            get: { draft.intervalUnit }, set: { model.setPlaylistIntervalUnit($0) })
        ) {
          ForEach(LoopIntervalInput.Unit.allCases, id: \.self) { unit in
            Text(unit.rawValue.capitalized).tag(unit)
          }
        }
        .frame(maxWidth: 180)
      }
      .disabled(draft.useProfileSuggestion)
      Text("Minimum \(intervalLabel(target.minimumDwellMs ?? 1)); maximum one year.")
        .font(.caption).foregroundStyle(.secondary)
      if draft.effectiveDwell(for: target) == nil {
        Text("Enter a whole positive interval within the frame's limits.")
          .foregroundStyle(.secondary)
      }
      if target.loopInterval?.requiresReview == true {
        Text("Frame capabilities or the profile suggestion changed. Review the set and interval.")
          .foregroundStyle(.secondary)
      }
      if let requested = target.loopInterval?.requestedDwellMs,
        requested < target.minimumDwellMs ?? 1
      {
        Text("The saved override was shorter than the current minimum; the new default was raised.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func savedPlaylist(_ target: FrameTarget, playlist: FramePlaylist) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider()
      Label(statusLabel(playlist), systemImage: "info.circle")
      Text("Saved interval: \(intervalLabel(playlist.dwellMs))")
        .foregroundStyle(.secondary)
      DisclosureGroup("Saved set · \(playlist.entryCount) stills") {
        ForEach(Array((playlist.items ?? []).enumerated()), id: \.element.id) { index, item in
          Text("\(index + 1). \(item.title)")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if playlist.status == .suspended {
        Button("Resume saved loop", systemImage: "play") {
          Task { await model.resumePlaylist() }
        }
        .disabled(
          model.actionsUnavailable || target.hasQueuedDelivery == true
            || playlist.requiresRevalidation == true
            || target.directDelivery?.status == .pending
        )
        .accessibilityIdentifier("resume-saved-playlist")
        Text(
          "Resumes the saved order and interval, starting with its first still after confirmation."
        )
        .font(.caption).foregroundStyle(.secondary)
        if target.hasQueuedDelivery == true || target.directDelivery?.status == .pending {
          Text("A newer delivery is waiting for the frame. Confirm it before resuming.")
            .foregroundStyle(.secondary)
        }
      }
      if playlist.requiresRevalidation == true {
        Text("Saved capabilities changed. Review and queue a newly prepared set.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func intervalLabel(_ milliseconds: Int) -> String {
    let unit = LoopIntervalInput.exactUnit(for: milliseconds)
    return "\(milliseconds / unit.multiplier) \(unit.rawValue)"
  }

  private func statusLabel(_ playlist: FramePlaylist) -> String {
    switch playlist.status {
    case .pending:
      playlist.replacingActive == true
        ? "Replacement queued; current loop continues until confirmation"
        : "Set queued; waiting for frame confirmation"
    case .active: "Loop active; installation confirmed by frame"
    case .suspended: "Saved loop paused"
    }
  }
}
