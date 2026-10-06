import FrameshiftShell
import SwiftUI

/// Shared connection/retry and shutdown presentation without replacing delivery status.
struct ShellLifecycleStatus: View {
  let model: ShellModel

  var body: some View {
    Group {
      if model.isQuiescing {
        Label(
          "New artwork actions are paused while Frameshift finishes quitting.",
          systemImage: "pause.circle"
        )
        .font(.callout).foregroundStyle(.secondary)
      } else if model.isStarting {
        ProgressView("Starting the local core…").controlSize(.small)
      } else if model.startupFailed {
        VStack(alignment: .leading, spacing: 6) {
          Text("The local core could not start.").foregroundStyle(.secondary)
          Button("Retry connection", systemImage: "arrow.clockwise") { model.start() }
            .disabled(model.isBusy)
        }
      }
    }
    .accessibilityIdentifier("shell-lifecycle-status")
  }
}
