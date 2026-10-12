import MSLCore
import SwiftUI

/// The right-click menu for empty space in a file view.
///
/// Finder has one, and its absence is felt the moment you want a new folder
/// somewhere: every action here already exists in the menu bar, this is
/// simply where the hand goes. Selection-dependent items stay out, because
/// clicking empty space is how you *clear* a selection.
struct FileBackgroundMenu: View {
    @ObservedObject var files: FilesModel

    var body: some View {
        Button("New Folder") { files.newFolder() }
            .disabled(!files.canWrite)
        Button("Paste") { files.pasteFromPasteboard() }
            .disabled(!files.canWrite)

        Divider()

        Toggle("Show Hidden Files", isOn: Binding(
            get: { files.showHidden },
            set: { files.showHidden = $0 }))

        Divider()

        Button("Copy Folder Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(files.currentPath, forType: .string)
        }
        Button("Open This Folder in Terminal") { files.openInTerminal(nil) }
        Button("Git…") {
            let path = files.currentPath
            files.gitTarget = GitPanelTarget(
                path: path,
                // The last component, except at a root, where it is the
                // whole path and "/" reads better than an empty title.
                name: (path as NSString).lastPathComponent.isEmpty
                      ? path : (path as NSString).lastPathComponent)
        }
        Button("Reveal This Folder in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: files.currentPath)])
        }
    }
}

extension View {
    /// Attaches the background menu to a whole view, behind its items.
    func fileBackgroundMenu(_ files: FilesModel) -> some View {
        contentShape(Rectangle()).contextMenu { FileBackgroundMenu(files: files) }
    }
}
