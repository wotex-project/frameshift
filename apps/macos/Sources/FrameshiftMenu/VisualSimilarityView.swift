import FrameshiftShell
import SwiftUI

struct VisualSimilarityView: View {
  let model: ShellModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Local visual similarity").font(.headline)
      Text(
        "Compare saved Apple Vision observations within the current Library filters. Distances are differences, not match probabilities."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Find similar artwork", systemImage: "photo.on.rectangle.angled") {
          model.findSimilarArtwork()
        }
        .disabled(model.isAnalysisBusy || model.similarity.isBusy || model.isBusy)
        .accessibilityIdentifier("library-find-similar")
        if model.similarity.isBusy {
          ProgressView().controlSize(.small)
          Button("Stop comparison", systemImage: "stop.circle") { model.similarity.stop() }
        } else if model.similarity.result != nil {
          Button("Clear results", systemImage: "xmark") { model.similarity.invalidate() }
        }
      }
      if model.isAnalysisBusy {
        Text("Wait for local labeling or stop it before comparing artwork.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let message = model.similarity.message { Text(message).foregroundStyle(.secondary) }
      if let result = model.similarity.result {
        if result.matches.isEmpty {
          Text("No other analyzed artwork matches these filters.").foregroundStyle(.secondary)
        }
        ForEach(result.matches, id: \.item.id) { match in
          Button {
            model.selectItem(match.item.id)
          } label: {
            HStack {
              Label(match.item.title, systemImage: match.item.isPinned ? "bookmark.fill" : "photo")
              Spacer()
              Text("Distance \(match.distance.formatted(.number.precision(.fractionLength(3))))")
                .font(.caption.monospacedDigit())
            }
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Select \(match.item.title), visual distance \(match.distance)")
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("library-visual-similarity")
  }
}
