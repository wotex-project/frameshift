import FrameshiftShell
import SwiftUI

/// Native display of verified, bounded local RGB pixels.
struct ArtworkPreviewView: View {
  let model: ShellModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let preview = model.selectedPreview, let image = preview.image() {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(model.snapshot.selectedTarget?.medium == .pixel ? .none : .high)
          .aspectRatio(
            CGFloat(preview.aspectWidth) / CGFloat(preview.aspectHeight), contentMode: .fit
          )
          .frame(maxWidth: .infinity, maxHeight: 320)
          .accessibilityLabel("Preview of \(model.selectedItem?.title ?? "selected artwork")")
        Text(
          preview.kind == "target" ? "Target crop preview · approximate color" : "Source preview"
        )
        .font(.caption).foregroundStyle(.secondary)
      } else if model.isPreviewLoading {
        ProgressView("Preparing local preview…")
      } else if let message = model.previewMessage {
        Text(message).font(.caption).foregroundStyle(.secondary)
        Button("Retry preview") { Task { await model.retryPreview() } }
      }
    }
    .accessibilityIdentifier("selected-artwork-preview")
  }
}
