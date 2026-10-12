import SwiftUI
import UniformTypeIdentifiers

/// Accepts a drag of files from anywhere - Finder, another app, or MSL Files
/// itself.
///
/// **Why not `dropDestination(for: URL.self)`.** That is the modern spelling
/// and it is what MSL Files used, and it quietly only worked for drags that
/// started inside MSL Files. `URL`'s `Transferable` conformance is built on
/// `public.url`; a file dragged out of Finder puts `public.file-url` on the
/// pasteboard and nothing else. MSL's own drag source happens to satisfy both
/// because it writes an `NSURL`, which is exactly why the gap was invisible
/// from inside the app: dragging within the window worked perfectly, and
/// dragging in from Finder did nothing at all, with no error anywhere.
///
/// Asking for `.fileURL` explicitly, and reading the providers by hand, is
/// the thing that works for both.
struct FileDropTarget: ViewModifier {
    /// Where the files should go. Returning nil refuses the drop, which is
    /// how a read-only place and a row that is not a folder opt out.
    let destination: () -> String?
    let receive: ([URL], String) -> Void
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        content.onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let destination = destination() else { return false }
            Self.loadFileURLs(from: providers) { urls in
                guard !urls.isEmpty else { return }
                receive(urls, destination)
            }
            // The providers are read asynchronously, so the answer here is
            // "yes, this drop is mine" rather than "the files have landed".
            return true
        }
    }

    /// Reads every provider's file URL, then calls back once on the main
    /// actor with all of them.
    ///
    /// A provider hands back either `Data` holding the URL's bytes or a `URL`
    /// already, depending on which app wrote it, so both are handled. The
    /// group is what makes a multi-file drag arrive as one operation instead
    /// of several, which matters because each one triggers a reload.
    static func loadFileURLs(from providers: [NSItemProvider],
                             then handle: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [URL] = []

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                continue
            }
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                              options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                switch item {
                case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
                case let direct as URL: url = direct
                default: url = nil
                }
                guard let url else { return }
                lock.lock(); found.append(url); lock.unlock()
            }
        }

        group.notify(queue: .main) { handle(found) }
    }
}

extension View {
    /// Accepts files dragged from anywhere. `destination` returns the folder
    /// they should land in, or nil to refuse.
    func fileDropTarget(targeted: Binding<Bool> = .constant(false),
                        destination: @escaping () -> String?,
                        receive: @escaping ([URL], String) -> Void) -> some View {
        modifier(FileDropTarget(destination: destination, receive: receive,
                                targeted: targeted))
    }
}

extension View {
    /// Accepts files dropped anywhere in a listing's area, including the
    /// blank space below the rows.
    ///
    /// **The blank space needs its own target.** A folder row has one, so
    /// dropping onto a folder has always worked - but the empty area below
    /// the rows belongs to the `List`, which swallows the drag rather than
    /// passing it out to whatever container the modifier was attached to.
    /// That is why dropping a file from Finder onto a folder icon worked and
    /// dropping it into the window did nothing: the only drop targets in the
    /// window were the rows themselves.
    func dropsIntoCurrentFolder(_ files: FilesModel) -> some View {
        fileDropTarget {
            files.canWrite ? files.currentPath : nil
        } receive: { urls, destination in
            files.receive(urls, into: destination)
        }
    }
}
