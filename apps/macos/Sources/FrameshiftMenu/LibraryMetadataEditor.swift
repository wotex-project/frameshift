import FrameshiftShell
import SwiftUI

struct LibraryMetadataEditor: View {
  let model: ShellModel
  @State private var newLabel = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Artwork metadata").font(.headline)
      Button("Analyze artwork locally", systemImage: "sparkle.magnifyingglass") {
        model.analyzeSelectedArtwork()
      }
      .disabled(
        model.isAnalysisBusy || model.similarity.isBusy || model.isMetadataLoading || model.isBusy
      )
      .help("Refresh Apple Vision observations. Your title and labels are preserved.")
      .accessibilityIdentifier("library-analyze-artwork")
      if let draft = model.metadataDraft {
        TextField(
          "Title",
          text: Binding(get: { model.metadataDraft?.title ?? "" }, set: model.setMetadataTitle)
        )
        .accessibilityIdentifier("library-metadata-title")
        Text(
          "\(draft.base.sourceKind.capitalized) · \(draft.base.width) × \(draft.base.height) source pixels"
        )
        .font(.caption).foregroundStyle(.secondary)
        Text("Your labels").font(.subheadline)
        ForEach(Array(draft.userLabels.enumerated()), id: \.offset) { index, label in
          HStack {
            Text(label).textSelection(.enabled)
            Spacer()
            Button("Remove label", systemImage: "minus.circle") { model.removeUserLabel(at: index) }
              .labelStyle(.iconOnly).accessibilityLabel("Remove user label \(label)")
          }
        }
        HStack {
          TextField("Add a user label", text: $newLabel).onSubmit(addLabel)
          Button("Add label", systemImage: "plus") { addLabel() }
            .disabled(
              newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || draft.userLabels.count >= 32)
        }
        if !draft.machineLabels.isEmpty {
          Text("Machine observations").font(.subheadline)
          ForEach(draft.machineLabels) { label in
            let dismissed = draft.dismissedLabels.contains(
              LabelDismissal(label: label.label, provenance: label.provenance))
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                Text(label.label).strikethrough(dismissed)
                Text(observation(label)).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button(
                dismissed ? "Keep observation" : "Dismiss observation",
                systemImage: dismissed ? "arrow.uturn.backward" : "minus.circle"
              ) {
                model.toggleLabelDismissal(label)
              }
              .accessibilityLabel(
                "\(dismissed ? "Keep" : "Dismiss") \(label.provenance) label \(label.label)")
            }
          }
          Text(
            "Correct an observation by dismissing it and adding your own label. New classifier runs may add observations again."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        if model.metadataIsStale {
          Label(
            "Metadata changed. Reload and review your draft before saving.",
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.secondary)
        }
        if !draft.isValid {
          Text(
            "Use a nonempty title up to 256 UTF-8 bytes and at most 32 labels of 128 bytes each. Control characters are not accepted."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("Save metadata", systemImage: "checkmark") { Task { await model.saveMetadata() } }
            .disabled(
              model.isBusy || model.isMetadataLoading || !draft.hasChanges || !draft.isValid
                || model.metadataIsStale)
          Button(
            draft.hasChanges ? "Discard draft and reload" : "Reload metadata",
            systemImage: "arrow.clockwise"
          ) {
            newLabel = ""
            Task { await model.loadSelectedMetadata(discardDraft: true) }
          }
          .disabled(model.isBusy || model.isMetadataLoading)
          if draft.hasChanges { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
        }
      } else if model.isMetadataLoading {
        ProgressView("Reading artwork metadata…")
      } else {
        Button("Retry metadata", systemImage: "arrow.clockwise") {
          Task { await model.loadSelectedMetadata() }
        }
      }
      if let message = model.metadataMessage { Text(message).foregroundStyle(.secondary) }
    }
    .onChange(of: model.selectedItem?.id) { _, _ in newLabel = "" }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("library-metadata-editor")
  }

  private func addLabel() {
    model.addUserLabel(newLabel)
    newLabel = ""
  }

  private func observation(_ label: ArtworkLabel) -> String {
    var parts = [label.provenance.capitalized]
    if let confidence = label.confidence {
      parts.append(confidence.formatted(.percent.precision(.fractionLength(0))))
    }
    if let revision = label.revision { parts.append(revision) }
    return parts.joined(separator: " · ")
  }
}
