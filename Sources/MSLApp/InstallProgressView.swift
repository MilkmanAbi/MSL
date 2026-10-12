import MSLCore
import SwiftUI

/// What a distro download looks like while it is happening.
///
/// **Why a bar and not just a spinner.** The download is several hundred
/// megabytes over a CDN, and for minutes at a time the only thing a person
/// wants to know is whether it is moving or has hung. A spinner answers
/// neither: it turns exactly the same way on a dead connection. So while
/// bytes are arriving this shows how far it has got, how much that is, and
/// how fast - and falls back to the indeterminate spinner for the stages
/// that genuinely have no measurable size (verifying the checksum,
/// unpacking, growing the disk).
///
/// Its own view rather than lines inside `AppsTab`, so it can be rendered
/// offscreen in a test: `swift build` passing says a view compiles, not that
/// it draws anything.
struct InstallProgressView: View {
    /// The installer's current status line, always present.
    let status: String
    /// Set only while a transfer is in flight.
    let transfer: DistroInstaller.TransferProgress?
    /// Called once the person has confirmed they want to stop. Omitted when
    /// there is nothing to cancel.
    var onCancel: (() -> Void)?

    @State private var confirming = false

    var body: some View {
        VStack(spacing: Design.Spacing.small) {
            if let transfer {
                // Drawn rather than `ProgressView(value:)`: the AppKit-backed
                // linear style does not render in `ImageRenderer`, so the one
                // test that could show this bar is right produced a
                // prohibitory placeholder instead. Two capsules draw the same
                // thing, in any context, and can be checked.
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                        Capsule()
                            .fill(.tint)
                            .frame(width: max(0, geometry.size.width * transfer.fraction))
                    }
                }
                .frame(maxWidth: 320)
                .frame(height: 6)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(Int(transfer.fraction * 100)) percent")
                Text(transfer.description)
                    .monospacedDigit()
                    .font(.callout)
                // The URL is long and uninteresting next to the numbers, but
                // worth keeping visible so it is obvious *what* is coming
                // down - just demoted below them.
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                ProgressView()
                Text(status).monospacedDigit()
            }

            if let onCancel {
                Button("Cancel", role: .cancel) { confirming = true }
                    .buttonStyle(.link)
                    .padding(.top, 2)
                    .confirmationDialog("Stop this download?", isPresented: $confirming) {
                        Button("Stop Downloading", role: .destructive) { onCancel() }
                        Button("Keep Downloading", role: .cancel) {}
                    } message: {
                        Text("What has downloaded so far will be deleted, and nothing will be installed.")
                    }
            }
        }
    }
}
