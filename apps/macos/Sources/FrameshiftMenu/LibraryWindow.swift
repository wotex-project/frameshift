import AppKit
import FrameshiftShell
import SwiftUI
import UniformTypeIdentifiers

/// Persistent library work shares one shell session with the compact popover.
struct LibraryWindow: View {
  @Environment(\.openSettings) private var openSettings
  let model: ShellModel

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        List(
          selection: Binding(
            get: { model.selectedItem?.id },
            set: { if let itemID = $0 { model.selectItem(itemID) } }
          )
        ) {
          ForEach(model.visibleItems) { item in
            Label(item.title, systemImage: item.isPinned ? "bookmark.fill" : "photo")
              .tag(item.id)
              .accessibilityValue(item.isPinned ? "Pinned" : "")
          }
        }
        .accessibilityLabel("Artwork library")
        .accessibilityIdentifier("focused-library-list")
        if model.visibleItems.isEmpty {
          Text(
            model.searchQuery.isEmpty ? "Import a still image to begin." : "No matching artwork."
          )
          .foregroundStyle(.secondary)
          .padding()
        }
        if let error = model.searchError {
          Text(error).foregroundStyle(.secondary).padding()
        }
      }
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
      .searchable(
        text: Binding(get: { model.searchQuery }, set: { model.setSearchQuery($0) }),
        prompt: "Search titles and labels"
      )
      .onSubmit(of: .search) { Task { await model.submitSearch() } }
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          target
          if let item = model.selectedItem {
            artwork(item)
          } else {
            ContentUnavailableView("Select artwork", systemImage: "photo.on.rectangle")
          }
          instruction
          PlaylistEditor(model: model)
          Label(model.snapshot.statusMessage, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("focused-delivery-status")
          if let error = model.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
              Text(error).foregroundStyle(.secondary)
              Button("Dismiss") { model.dismissError() }
            }
            .accessibilityElement(children: .contain)
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 700, minHeight: 520)
    .toolbar {
      Button("Import image", systemImage: "photo.badge.plus") { chooseImage() }
        .disabled(model.isBusy)
      Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
        .disabled(model.isBusy)
      Button("Settings", systemImage: "gearshape") { openSettings() }
      Button("Recently Removed", systemImage: "trash") { model.isRecoveryPresented = true }
    }
    .sheet(
      isPresented: Binding(
        get: { model.isRecoveryPresented }, set: { model.isRecoveryPresented = $0 })
    ) {
      RecentlyRemovedView(model: model)
    }
    .task {
      await model.refresh()
      model.beginPlaylistEdit()
    }
    .onChange(of: model.snapshot.selectedTargetID) { _, _ in model.beginPlaylistEdit() }
  }

  @ViewBuilder
  private var target: some View {
    if let selected = model.snapshot.selectedTargetID {
      Picker(
        "Target frame",
        selection: Binding(get: { selected }, set: { id in Task { await model.selectTarget(id) } })
      ) {
        ForEach(model.snapshot.targets) { target in
          Text("\(target.medium.label) — \(target.name)").tag(target.id)
        }
      }
      .disabled(model.isBusy)
    } else {
      Label("No frame paired", systemImage: "square.on.square")
        .foregroundStyle(.secondary)
    }
  }

  private func artwork(_ item: FrameshiftShell.LibraryItem) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(item.title).font(.title2)
      ArtworkPreviewView(model: model)
      LibraryMetadataEditor(model: model)
      LabeledContent("Source master") {
        Text(item.digest).font(.caption.monospaced()).textSelection(.enabled)
      }
      if let state = item.loopStatus {
        Label(loopLabel(state), systemImage: "arrow.triangle.2.circlepath")
      } else if item.queuedTargetID != nil {
        Label("Queued artwork", systemImage: "clock")
      }
      HStack {
        Button("Queue for frame", systemImage: "paperplane") { Task { await model.queue(item.id) } }
          .disabled(
            model.snapshot.selectedTarget == nil
              || model.snapshot.selectedTarget?.directDelivery?.status == .pending || model.isBusy
              || model.isPreviewLoading)
        Button(
          item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "bookmark.fill" : "bookmark"
        ) {
          Task { await model.togglePin(item.id) }
        }
        Button("Remove", systemImage: "trash", role: .destructive) {
          Task { await model.remove(item.id) }
        }
      }
      .buttonStyle(FlatActionButtonStyle())
      .disabled(model.isBusy)
      if model.snapshot.selectedTarget?.directDelivery?.status == .pending {
        Button("Check frame", systemImage: "clock.arrow.circlepath") {
          Task { await model.reconcileDelivery() }
        }
        .disabled(model.isBusy)
      }
    }
    .accessibilityIdentifier("focused-artwork-detail")
  }

  private var instruction: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Instruction").font(.headline)
      TextEditor(
        text: Binding(get: { model.draftInstruction }, set: { model.draftInstruction = $0 })
      )
      .font(.body)
      .frame(minHeight: 120)
      .accessibilityLabel("Instruction")
      HStack {
        Button("Save instruction", systemImage: "checkmark") {
          Task { await model.saveInstruction() }
        }
        .disabled(model.isBusy || !model.hasUnsavedInstruction)
        if model.hasUnsavedInstruction { Text("Unsaved changes").foregroundStyle(.secondary) }
      }
    }
  }

  private func loopLabel(_ state: FramePlaylist.Status) -> String {
    switch state {
    case .pending: "In queued loop"
    case .active: "In active loop"
    case .suspended: "In paused loop"
    }
  }

  private func chooseImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await model.importFile(url) }
  }
}
