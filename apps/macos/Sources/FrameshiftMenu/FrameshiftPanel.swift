import AppKit
import FrameshiftShell
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct FrameshiftPanel: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow
  let model: ShellModel
  let panelState: PanelState

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      targetPicker
      if model.guideHandoff != nil {
        guideHandoff
      } else {
        instructionEditor
        actionRow
      }
      status
      loopControls
      searchField
      library
    }
    .padding(16)
    .frame(width: 420, height: 560)
    .background(MenuBackdrop())
    .task { await model.refresh() }
    .alert(
      "Frameshift could not complete that action",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.dismissError() } }
      )
    ) {
      Button("OK") { model.dismissError() }
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      if let icon = AppIcon.image(for: colorScheme) {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .frame(width: 38, height: 38)
          .offset(y: -3)
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text("Frameshift")
          .font(.title2.weight(.semibold))
        Text("Still artwork, prepared for one frame")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        openWindow(id: "library")
      } label: {
        Image(systemName: "books.vertical")
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help("Open Library")
      .accessibilityLabel("Open Library")
      .accessibilityIdentifier("open-library")

      Button {
        openSettings()
      } label: {
        Image(systemName: "gearshape")
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Open Frameshift Settings")
      .accessibilityLabel("Open Frameshift Settings")
      .accessibilityIdentifier("open-settings")

      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Image(systemName: "power")
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Quit Frameshift")
      .accessibilityLabel("Quit Frameshift")
      .accessibilityIdentifier("quit-app")
      .keyboardShortcut("q", modifiers: .command)
    }
  }

  private var targetPicker: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Target")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      if let selectedTargetID = model.snapshot.selectedTargetID {
        Picker(
          "Target frame",
          selection: Binding(
            get: { selectedTargetID },
            set: { targetID in Task { await model.selectTarget(targetID) } }
          )
        ) {
          ForEach(model.snapshot.targets) { target in
            Text("\(target.medium.label) — \(target.name)").tag(target.id)
          }
        }
        .labelsHidden()
        .accessibilityIdentifier("target-picker")
      } else {
        Text("No frame paired")
          .foregroundStyle(.secondary)
      }
      if model.snapshot.selectedTarget?.directDelivery?.status == .pending {
        HStack {
          Label("Direct delivery pending confirmation", systemImage: "clock.arrow.circlepath")
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("direct-delivery-pending")
          Spacer()
          Button("Check frame") { Task { await model.reconcileDelivery() } }
            .disabled(model.isBusy)
        }
      }
    }
  }

  private var guideHandoff: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Guide choice", systemImage: "square.on.square")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          model.dismissGuideHandoff()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss guide choice")
      }

      if let choice = model.guideHandoff {
        Text(choice.medium.label)
          .font(.headline)
        if let profile = choice.profileID {
          Text(profile)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
        }
      }

      if model.guideMatchingTargets.isEmpty {
        Text(
          "No paired frame matches this hint. Pairing requires the frame's physical pair mode in the installed app."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else {
        Menu("Select a matching paired frame") {
          ForEach(model.guideMatchingTargets) { target in
            Button(target.name) {
              Task {
                await model.selectTarget(target.id)
                if model.snapshot.selectedTargetID == target.id {
                  model.dismissGuideHandoff()
                }
              }
            }
          }
        }
        .disabled(model.isBusy)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    .accessibilityIdentifier("guide-handoff")
  }

  private var instructionEditor: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text("Instruction")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Spacer()
        if model.snapshot.generationAvailability == .notConfigured {
          Text("No generator configured")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      ZStack(alignment: .topLeading) {
        TextEditor(
          text: Binding(
            get: { model.draftInstruction },
            set: { model.draftInstruction = $0 }
          )
        )
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .accessibilityLabel("Instruction")
        .accessibilityIdentifier("instruction-editor")

        if model.draftInstruction.isEmpty {
          Text("Describe the still image you want to prepare")
            .font(.body)
            .foregroundStyle(.tertiary)
            .padding(.leading, 10)
            .padding(.top, 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      .frame(height: 104)
      .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(.quaternary, lineWidth: 1)
      }
    }
  }

  private var actionRow: some View {
    HStack {
      Button {
        chooseImage()
      } label: {
        Label("Import image", systemImage: "photo.badge.plus")
      }
      .buttonStyle(FlatActionButtonStyle())
      .keyboardShortcut("i", modifiers: .command)

      Button {
        Task { await model.saveInstruction() }
      } label: {
        Label("Save instruction", systemImage: "checkmark")
      }
      .buttonStyle(FlatActionButtonStyle())
      .disabled(model.isBusy)

      Spacer()

      if model.isBusy {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Working")
      }
    }
  }

  private func chooseImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true

    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await model.importFile(url) }
  }

  private var status: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(.orange)
        .frame(width: 7, height: 7)
      Text(model.snapshot.statusMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("core-status")
  }

  @ViewBuilder
  private var loopControls: some View {
    if let target = model.snapshot.selectedTarget {
      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Menu {
            if let suggested = target.recommendedDwellMs {
              Button(suggestedLabel(for: target, milliseconds: suggested)) {
                Task { await model.loopPinned(dwellMs: nil) }
              }
            }

            ForEach(intervalChoices(for: target), id: \.milliseconds) { choice in
              Button("Every \(choice.label)") {
                Task { await model.loopPinned(dwellMs: choice.milliseconds) }
              }
            }

            Divider()
            Button("Custom interval…") {
              panelState.customIntervalShown = true
            }
          } label: {
            Label("Loop pins", systemImage: "arrow.triangle.2.circlepath")
          }
          .buttonStyle(FlatActionButtonStyle())
          .disabled(model.isBusy)
          .help("Cycle the current pinned artwork on \(target.name)")
          .accessibilityIdentifier("loop-pinned-menu")

          Spacer()

          if let playlist = target.playlist {
            VStack(alignment: .trailing, spacing: 1) {
              Text(playlistStatus(playlist))
                .font(.caption)
              Text(
                "\(playlist.entryCount) \(playlist.entryCount == 1 ? "still" : "stills") · every \(intervalLabel(playlist.dwellMs))"
              )
              .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("playlist-status")
          }
        }

        if panelState.customIntervalShown {
          HStack(spacing: 8) {
            TextField(
              "Minutes",
              text: Binding(
                get: { panelState.customIntervalMinutes },
                set: { panelState.customIntervalMinutes = $0 }
              )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 85)
            .accessibilityLabel("Custom loop interval in minutes")
            .accessibilityIdentifier("custom-loop-minutes")
            .onSubmit { queueCustomInterval(for: target) }

            Text(
              "At least \(LoopIntervalInput.minimumMinutes(minimumDwellMs: target.minimumDwellMs)) min"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            Button("Queue loop") { queueCustomInterval(for: target) }
              .disabled(customDwellMs(for: target) == nil || model.isBusy)
              .accessibilityIdentifier("queue-custom-loop")

            Button("Cancel") { panelState.customIntervalShown = false }
              .buttonStyle(.plain)
          }
        }
        if target.playlist?.status == .suspended {
          Button("Resume saved loop", systemImage: "play") {
            Task { await model.resumePlaylist() }
          }
          .disabled(
            model.isBusy || target.hasQueuedDelivery == true
              || target.playlist?.requiresRevalidation == true
              || target.directDelivery?.status == .pending)
        }
        Button("Edit playlist in Library", systemImage: "list.number") {
          openWindow(id: "library")
        }
      }
    }
  }

  private func customDwellMs(for target: FrameTarget) -> Int? {
    LoopIntervalInput.dwellMilliseconds(
      panelState.customIntervalMinutes, minimumDwellMs: target.minimumDwellMs)
  }

  private func queueCustomInterval(for target: FrameTarget) {
    guard let dwellMs = customDwellMs(for: target), !model.isBusy else { return }
    panelState.customIntervalShown = false
    Task { await model.loopPinned(dwellMs: dwellMs) }
  }

  private func intervalChoices(for target: FrameTarget) -> [IntervalChoice] {
    let floor = target.minimumDwellMs ?? 1
    let choices = [
      IntervalChoice(label: "15 minutes", milliseconds: 900_000),
      IntervalChoice(label: "1 hour", milliseconds: 3_600_000),
      IntervalChoice(label: "6 hours", milliseconds: 21_600_000),
      IntervalChoice(label: "24 hours", milliseconds: 86_400_000),
    ].filter { $0.milliseconds >= floor }
    return choices.isEmpty
      ? [IntervalChoice(label: intervalLabel(floor), milliseconds: floor)] : choices
  }

  private func suggestedLabel(for target: FrameTarget, milliseconds: Int) -> String {
    let basis = target.recommendationBasis == "provisional-profile" ? " (provisional)" : ""
    return "Suggested · \(intervalLabel(milliseconds))\(basis)"
  }

  private func intervalLabel(_ milliseconds: Int) -> String {
    if milliseconds % 3_600_000 == 0 {
      let hours = milliseconds / 3_600_000
      return "\(hours) \(hours == 1 ? "hour" : "hours")"
    }
    if milliseconds % 60_000 == 0 {
      let minutes = milliseconds / 60_000
      return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }
    if milliseconds % 1_000 == 0 {
      let seconds = milliseconds / 1_000
      return "\(seconds) \(seconds == 1 ? "second" : "seconds")"
    }
    return "\(milliseconds) ms"
  }

  private func playlistStatus(_ playlist: FramePlaylist) -> String {
    switch playlist.status {
    case .pending:
      playlist.replacingActive == true ? "Updating · current loop continues" : "Waiting for frame"
    case .active: "Loop active"
    case .suspended: "Loop paused"
    }
  }

  private var searchField: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField(
          "Search library",
          text: Binding(
            get: { model.searchQuery },
            set: { model.setSearchQuery($0) }
          )
        )
        .textFieldStyle(.plain)
        .accessibilityIdentifier("library-search")
        .onSubmit { Task { await model.submitSearch() } }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))

      if let searchError = model.searchError {
        Text(searchError)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var library: some View {
    if model.visibleItems.isEmpty {
      ContentUnavailableView {
        Label(
          model.searchQuery.isEmpty ? "No artwork yet" : "No matching artwork",
          systemImage: model.searchQuery.isEmpty ? "photo" : "magnifyingglass"
        )
      } description: {
        Text(
          model.searchQuery.isEmpty
            ? "Import a still image. Generation stays disabled until a provider is configured."
            : "Try a title or label prefix."
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(spacing: 10) {
          ForEach(model.visibleItems) { item in
            ResultCard(
              item: item,
              isSelected: model.selectedItem?.id == item.id,
              model: model,
              targetName: model.snapshot.selectedTarget?.name ?? "selected target",
              canQueue: model.snapshot.selectedTarget != nil
                && model.snapshot.selectedTarget?.directDelivery?.status != .pending,
              select: { model.selectItem(item.id) },
              queue: { Task { await model.queue(item.id) } },
              togglePin: { Task { await model.togglePin(item.id) } },
              remove: { Task { await model.remove(item.id) } }
            )
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .scrollIndicators(.visible)
      .accessibilityIdentifier("library-scroll-view")
    }
  }
}

private struct IntervalChoice {
  let label: String
  let milliseconds: Int
}

@MainActor
@Observable
final class PanelState {
  var customIntervalShown = false
  var customIntervalMinutes = ""
}

private struct ResultCard: View {
  let item: FrameshiftShell.LibraryItem
  let isSelected: Bool
  let model: ShellModel
  let targetName: String
  let canQueue: Bool
  let select: () -> Void
  let queue: () -> Void
  let togglePin: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 8)
        .fill(.quaternary)
        .frame(width: 74, height: 58)
        .overlay {
          if isSelected, let preview = model.selectedPreview, let image = preview.image() {
            Image(decorative: image, scale: 1)
              .resizable()
              .interpolation(model.snapshot.selectedTarget?.medium == .pixel ? .none : .high)
              .scaledToFit()
          } else if isSelected && model.isPreviewLoading {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "photo").foregroundStyle(.secondary)
          }
        }
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Button(action: select) {
          HStack(spacing: 5) {
            Text(item.title)
              .font(.headline)
              .lineLimit(1)
            if isSelected {
              Image(systemName: "checkmark.circle.fill")
                .accessibilityHidden(true)
            }
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(item.title)")
        .accessibilityValue(isSelected ? "Selected" : "")
        Text(itemStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
        if isSelected, let preview = model.selectedPreview {
          Text(preview.kind == "target" ? "Approximate target crop" : "Source preview")
            .font(.caption2).foregroundStyle(.secondary)
        } else if isSelected, let message = model.previewMessage {
          Button("Retry preview") { Task { await model.retryPreview() } }
            .font(.caption).help(message)
        }
      }

      Spacer()

      HStack(spacing: 4) {
        Button(action: queue) {
          Image(systemName: "paperplane")
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.borderless)
        .disabled(!canQueue || model.isPreviewLoading)
        .help("Queue this still for \(targetName)")
        .accessibilityLabel("Queue \(item.title)")

        Button(action: togglePin) {
          Image(systemName: item.isPinned ? "bookmark.fill" : "bookmark")
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.borderless)
        .help(item.isPinned ? "Unpin" : "Pin")
        .accessibilityLabel(item.isPinned ? "Unpin \(item.title)" : "Pin \(item.title)")

        Button(role: .destructive, action: remove) {
          Image(systemName: "trash")
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.borderless)
        .help("Remove from the library")
        .accessibilityLabel("Remove \(item.title)")
      }
    }
    .padding(10)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
    .accessibilityElement(children: .contain)
  }

  private var itemStatus: String {
    switch item.loopStatus {
    case .pending: "In queued loop"
    case .active: "In active loop"
    case .suspended: "In paused loop"
    case nil: item.queuedTargetID == nil ? "Ready to queue" : "Queued for \(targetName)"
    }
  }
}

private struct MenuBackdrop: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = TransparentEffectView()
    view.material = .popover
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private final class TransparentEffectView: NSVisualEffectView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.isOpaque = false
    window?.backgroundColor = .clear
  }
}
