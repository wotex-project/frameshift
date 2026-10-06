import FrameshiftShell
import SwiftUI

struct RecentlyRemovedView: View {
  let model: ShellModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Recently Removed").font(.title2)
      Text(
        "Restore retained artwork to the Library. Pins, frame references and recipes protect bytes from collection."
      )
      .foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          ForEach(model.removedItems) { item in
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text(Date(timeIntervalSince1970: Double(item.removedAtMs) / 1000), style: .date)
                  .font(.caption).foregroundStyle(.secondary)
                Text(retention(item)).font(.caption).foregroundStyle(.secondary)
                Text(item.id).font(.caption.monospaced()).textSelection(.enabled)
              }
              Spacer()
              Button("Restore", systemImage: "arrow.uturn.backward") {
                Task { await model.restoreArtwork(item.id) }
              }
              .disabled(model.actionsUnavailable)
              .accessibilityLabel("Restore \(item.title)")
            }
          }
          if model.removedItems.isEmpty && !model.isRecoveryLoading {
            Text("No removed artwork in this listing.").foregroundStyle(.secondary)
          }
          if model.recoveryCursor != nil {
            Button("Load more removed artwork") { Task { await model.loadRecovery() } }
              .disabled(model.isRecoveryLoading || model.actionsUnavailable)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if model.isRecoveryLoading { ProgressView("Reading removed artwork…") }
      if let message = model.recoveryMessage { Text(message).foregroundStyle(.secondary) }
      if let message = model.errorMessage { Text(message).foregroundStyle(.secondary) }
      HStack {
        Button("Refresh", systemImage: "arrow.clockwise") {
          Task { await model.loadRecovery(reset: true) }
        }
        .disabled(model.isRecoveryLoading || model.actionsUnavailable)
        Spacer()
        Button("Done") { model.isRecoveryPresented = false }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .frame(minWidth: 600, idealWidth: 680, minHeight: 420, idealHeight: 560)
    .task { await model.loadRecovery(reset: true) }
    .accessibilityIdentifier("recently-removed")
  }

  private func retention(_ item: RemovedArtwork) -> String {
    let reasons = item.retentionReasons.map { reason in
      switch reason {
      case "pinned": "Pin"
      case "frame": "Frame reference"
      case "artifact": "Rendered artifact"
      case "recipe": "Recipe source"
      default: "Retained reference"
      }
    }
    if !reasons.isEmpty { return "Retained by: \(reasons.joined(separator: ", "))" }
    return item.storageState == "trash"
      ? "Recoverable trash" : "Removed from the Library; bytes retained"
  }
}
