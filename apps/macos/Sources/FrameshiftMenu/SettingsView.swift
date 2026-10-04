import AppKit
import FrameshiftShell
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @Environment(\.openWindow) private var openWindow
  let model: LoginSettingsModel
  let discovery: FrameDiscovery
  let pairing: PairingSettingsModel
  let shell: ShellModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SettingsSection("Connection") {
          settingsValue("Core connection", value: "Local Unix socket")
        }

        SettingsSection(
          "Library",
          footer:
            "Removed artwork remains recoverable. Frame and recipe references preserve retained bytes."
        ) {
          Button("Manage Library", systemImage: "photo.on.rectangle") { openWindow(id: "library") }
          Button("Recently Removed", systemImage: "trash") {
            openWindow(id: "library")
            shell.isRecoveryPresented = true
          }
        }

        SettingsSection(
          "Image generation",
          footer: "You can import images without a generation provider."
        ) {
          settingsValue("Generation provider", value: "Not configured")
        }

        storage

        nearbyFrames
        startup
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .frame(minWidth: 520, idealWidth: 580, minHeight: 420, idealHeight: 620)
    .onAppear {
      model.refresh()
      discovery.start()
    }
    .onDisappear { discovery.stop() }
    .task { await shell.storageSettings.refresh() }
  }

  private var storage: some View {
    let settings = shell.storageSettings
    return SettingsSection(
      "Storage",
      footer:
        "The budget counts registered artwork and recoverable trash. Database, work files, logs and model downloads use additional disk space. Removal does not free this allowance."
    ) {
      if let usage = settings.storage {
        settingsValue("Accounted artwork", value: byteCount(usage.totalBytes))
        settingsValue("Recoverable trash", value: byteCount(usage.trashBytes))
        settingsValue("Current byte budget", value: byteCount(usage.objectByteLimit))
        if usage.overBudget {
          Label(
            "Over budget — new artwork bytes are refused", systemImage: "exclamationmark.circle"
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        TextField(
          "Budget in MiB",
          text: Binding(get: { settings.draftMebibytes }, set: { settings.edit($0) })
        )
        .accessibilityIdentifier("storage-budget")
        Text("Choose a whole number from 1 to 1,048,576 MiB. Existing artwork is preserved.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Save budget", systemImage: "checkmark") { Task { await settings.save() } }
          .disabled(!settings.canSave)
      }
      HStack {
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await settings.refresh() } }
        Button("Reload settings", systemImage: "arrow.counterclockwise") {
          Task { await settings.refresh(discardDraft: true) }
        }
      }
      .disabled(settings.isBusy)
      if let message = settings.message {
        Text(message).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func byteCount(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
  }

  private var nearbyFrames: some View {
    SettingsSection(
      "Nearby frames",
      footer:
        "Nearby advertisements are unverified. Pairing checks the frame’s physical QR identity."
    ) {
      if let discoveryStatus {
        Text(discoveryStatus)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      ForEach(discovery.frames) { frame in
        if frame.id != discovery.frames.first?.id {
          Divider()
        }
        discoveredFrame(frame)
      }

      if pairing.isBusy {
        ProgressView("Pairing frame…")
          .controlSize(.small)
      }
      if let status = pairing.statusMessage {
        Text(status)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let error = pairing.errorMessage {
        Text(error)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var discoveryStatus: String? {
    switch discovery.state {
    case .idle, .searching:
      "Searching for frames on this network…"
    case .unavailable:
      "Frame discovery is unavailable. Check Local Network access in macOS Settings."
    case .tooManyResults:
      "Too many frame advertisements to show safely."
    case .ready:
      discovery.frames.isEmpty ? "No compatible frame advertisements found." : nil
    }
  }

  private func discoveredFrame(_ frame: DiscoveredFrame) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(frame.id)
          .fontWeight(.medium)
          .textSelection(.enabled)
        Text(frame.introduction.pairMode ? "Physical pair mode available" : "Not in pair mode")
          .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 8) {
        if frame.introduction.pairMode {
          Button {
            choosePairingImage(for: frame, recovering: false)
          } label: {
            Label("Pair…", systemImage: "qrcode.viewfinder")
          }
          .accessibilityLabel("Pair frame \(frame.id)")
        }
        Button {
          choosePairingImage(for: frame, recovering: true)
        } label: {
          Label("Recover…", systemImage: "arrow.clockwise")
        }
        .accessibilityLabel("Recover frame pairing \(frame.id)")
      }
      .buttonStyle(FlatActionButtonStyle())
      .disabled(pairing.isBusy)
    }
    .accessibilityIdentifier("discovered-frame-\(frame.id)")
  }

  private var startup: some View {
    SettingsSection("Startup", footer: model.statusText) {
      Toggle(
        "Launch at Login",
        isOn: Binding(
          get: { model.isEnabled },
          set: { model.setEnabled($0) }
        )
      )
      .toggleStyle(.checkbox)
      .accessibilityIdentifier("launch-at-login")

      if model.requiresApproval {
        Divider()
        Button {
          SMAppService.openSystemSettingsLoginItems()
        } label: {
          Label("Open Login Items", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(FlatActionButtonStyle())
      }
      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func settingsValue(_ title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 20) {
      Text(title)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Text(value)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func choosePairingImage(for frame: DiscoveredFrame, recovering: Bool) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message =
      "Choose an image of the physical QR label on \(frame.id) to \(recovering ? "recover" : "pair") it."
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        let bootstrap: String
        do {
          bootstrap = try await Task.detached(priority: .userInitiated) {
            try PairingQRReader.read(url)
          }.value
        } catch {
          pairing.reportInvalidQR()
          return
        }
        guard confirmPhysicalQR(for: frame, imageURL: url, recovering: recovering) else { return }
        let succeeded =
          recovering
          ? await pairing.recover(frame: frame, bootstrap: bootstrap, discovery: discovery)
          : await pairing.pair(frame: frame, bootstrap: bootstrap, discovery: discovery)
        if succeeded {
          await shell.refresh()
        }
      }
    }
  }

  private func confirmPhysicalQR(
    for frame: DiscoveredFrame, imageURL: URL, recovering: Bool
  ) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Confirm the physical frame label"
    alert.informativeText =
      recovering
      ? "Recover \(frame.id) using this physical QR label? This checks its authenticated description without sending the one-time secret again."
      : "Pair \(frame.id) using this QR label? Check that it is attached to the frame and physical pair mode is active."
    alert.addButton(withTitle: recovering ? "Recover pairing" : "Pair frame")
    alert.addButton(withTitle: "Cancel")
    if let image = NSImage(contentsOf: imageURL) {
      let preview = NSImageView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
      preview.image = image
      preview.imageScaling = .scaleProportionallyUpOrDown
      preview.setAccessibilityLabel("Selected physical pairing QR image")
      alert.accessoryView = preview
    }
    return alert.runModal() == .alertFirstButtonReturn
  }
}

private struct SettingsSection<Content: View>: View {
  let title: String
  let footer: String?
  let content: Content

  init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.headline)
        .padding(.horizontal, 12)
        .accessibilityAddTraits(.isHeader)

      VStack(alignment: .leading, spacing: 14) {
        content
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
      }

      if let footer {
        Text(footer)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

@MainActor
final class SystemLoginItemService: LoginItemService {
  var status: LoginItemStatus {
    switch SMAppService.mainApp.status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notRegistered: .notRegistered
    case .notFound: .unavailable
    @unknown default: .unavailable
    }
  }

  func register() throws {
    try SMAppService.mainApp.register()
  }

  func unregister() throws {
    try SMAppService.mainApp.unregister()
  }
}
