import AppKit
import FrameshiftShell
import FrameshiftUpdater
import SwiftUI

@MainActor
private enum ShellSession {
  static let model = ShellModel(client: LocalCoreClient())
  static let panelState = PanelState()
  static let loginSettings = LoginSettingsModel(service: SystemLoginItemService())
  static let discovery = FrameDiscovery()
  static let pairingSettings = PairingSettingsModel()
  static let outboxAdvertisement = OutboxAdvertisement()
  static let termination = CoreTerminationCoordinator { quiesce() }
  // Development has no qualified production channel. Do not infer eligibility
  // from bundle metadata or start Sparkle with a sample feed/key.
  static let updater = NativeUpdater(channel: nil, termination: termination)

  static func quiesce() {
    model.quiesce()
    discovery.stop()
    outboxAdvertisement.stop()
    updater.quiesce()
  }
}

@main
struct FrameshiftMenuApp: App {
  @NSApplicationDelegateAdaptor(FrameshiftAppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra {
      FrameshiftPanel(model: ShellSession.model, panelState: ShellSession.panelState)
        .modifier(AppIconAppearance())
    } label: {
      Image(nsImage: MenuBarIcon.image)
        .accessibilityLabel("Frameshift")
    }
    .menuBarExtraStyle(.window)

    Window("Frameshift Library", id: "library") {
      LibraryWindow(model: ShellSession.model)
        .modifier(AppIconAppearance())
    }
    .defaultSize(width: 860, height: 640)
    .windowResizability(.contentMinSize)
    .commands { LibraryCommands() }

    Settings {
      SettingsView(
        model: ShellSession.loginSettings,
        discovery: ShellSession.discovery,
        pairing: ShellSession.pairingSettings,
        shell: ShellSession.model,
        updater: ShellSession.updater
      )
    }
    .defaultSize(width: 580, height: 620)
    .windowResizability(.contentMinSize)
  }
}

private struct LibraryCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button("Check for Updates…") { ShellSession.updater.checkForUpdates() }
        .disabled(!ShellSession.updater.canCheckForUpdates)
    }
    CommandGroup(after: .newItem) {
      Button("Open Library") { openWindow(id: "library") }
        .keyboardShortcut("l", modifiers: .command)
    }
  }
}

@MainActor
private enum MenuBarIcon {
  static let image: NSImage = {
    let image = NSImage(size: NSSize(width: 18, height: 18))

    for suffix in ["", "@2x", "@3x"] {
      guard let url = Bundle.main.url(forResource: "FrameshiftMenu\(suffix)", withExtension: "png"),
        let data = try? Data(contentsOf: url),
        let representation = NSBitmapImageRep(data: data)
      else { continue }
      representation.size = NSSize(width: 18, height: 18)
      image.addRepresentation(representation)
    }

    if image.representations.isEmpty {
      return NSImage(
        systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Frameshift")!
    }

    image.isTemplate = true
    return image
  }()
}

private struct AppIconAppearance: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .onAppear { AppIcon.apply(colorScheme) }
      .onChange(of: colorScheme) { _, appearance in AppIcon.apply(appearance) }
  }
}

@MainActor
enum AppIcon {
  static func image(for appearance: ColorScheme) -> NSImage? {
    let name = appearance == .dark ? "FrameshiftDark" : "FrameshiftLight"
    guard let url = Bundle.main.url(forResource: name, withExtension: "icns"),
      let image = NSImage(contentsOf: url)
    else { return nil }
    return image
  }

  static func apply(_ appearance: ColorScheme) {
    guard let image = image(for: appearance) else { return }
    NSApplication.shared.applicationIconImage = image
  }
}

@MainActor
private final class FrameshiftAppDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    _ = application
    for url in urls {
      ShellSession.model.receiveGuideURL(url)
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    _ = notification
    ShellSession.outboxAdvertisement.start()
    ShellSession.model.start()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    ShellSession.termination.requestTermination(sender)
  }

  func applicationWillTerminate(_ notification: Notification) {
    _ = notification
    ShellSession.outboxAdvertisement.stop()
    ShellSession.model.quiesce()
    ShellSession.discovery.stop()
    ShellSession.updater.quiesce()
  }
}
