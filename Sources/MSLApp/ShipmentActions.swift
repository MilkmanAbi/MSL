import AppKit
import MSLCore
import SwiftUI

/// Making and installing shipments from the app.
///
/// The work itself is `Shipment`; this is the part that asks where to put the
/// file, keeps the main thread free while xz runs, and says what happened.
extension AppModel {
    /// Whether a shipment is being written or read right now, by instance
    /// name (or `""` for an install, which has no instance yet).
    static var shipmentBusyNotification: Notification.Name { .init("msl.shipment.busy") }

    /// Packages `instance`, asking where to save it first.
    ///
    /// Refuses while the instance is running rather than capturing a
    /// half-written filesystem - the same rule the image builder follows.
    func createShipment(_ instance: Instance) {
        guard !instance.isLive else {
            banner = Banner(kind: .error, title: "\(instance.name) is running",
                            detail: "Shut it down first - a shipment taken from a running instance captures its filesystem mid-write.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Shipment"
        panel.nameFieldStringValue = "\(instance.name).\(Shipment.fileExtension)"
        panel.allowedContentTypes = []
        panel.message = "A shipment is this whole instance - its apps, files and account - in one file another Mac's MSL can install."
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        shipping.insert(instance.name)
        let apps = installedApps(for: instance)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try Shipment.create(instance: instance.name, distro: instance.distro,
                                        destination: destination, apps: apps, isRunning: false) { line in
                        Task { @MainActor [weak self] in self?.shipmentStatus[instance.name] = line }
                    }
                    return nil
                } catch {
                    return "\(error)"
                }
            }.value
            guard let self else { return }
            self.shipping.remove(instance.name)
            self.shipmentStatus[instance.name] = nil
            if let result {
                self.banner = Banner(kind: .error, title: "Couldn't ship \(instance.name)", detail: result)
            } else {
                let size = DiskStorage.format(DiskStorage.allocatedSize(of: destination.path))
                self.banner = Banner(kind: .success, title: "\(instance.name) shipped",
                                     detail: "\(destination.lastPathComponent) · \(size)")
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }

    /// Asks for a `.mslship`, then installs it as a new instance.
    func installShipment() {
        let panel = NSOpenPanel()
        panel.title = "Install MSL Shipment"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let manifest: Shipment.Manifest
        do {
            manifest = try Shipment.info(at: url)
        } catch {
            banner = Banner(kind: .error, title: "Not a shipment", detail: "\(error)")
            return
        }
        // A free name, so installing never overwrites an instance that exists.
        var name = manifest.source.instance
        var suffix = 2
        let taken = Set(instances.map(\.name))
        while taken.contains(name) { name = "\(manifest.source.instance)-\(suffix)"; suffix += 1 }
        let chosen = name

        // A window, because there is nowhere else for this to show.
        // Creating a shipment reports into the instance's own view
        // (`InstanceView` watches `shipping`), but an install has no instance
        // yet - the New Instance sheet closes and the app went back to
        // looking idle while it unpacked many gigabytes. It read as nothing
        // happening at all.
        let window = ProgressWindow(title: "Installing Shipment",
                                    status: "Reading \(url.lastPathComponent)…",
                                    onCancel: nil)
        window.show()

        shipping.insert("")
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[InstanceExperiments.Outcome], Error> in
                do {
                    var existing: [String: GuestDistro] = [:]
                    for instance in await self?.instances ?? [] { existing[instance.name] = instance.distro }
                    let outcomes = try Shipment.install(url, as: chosen, existingInstances: existing) { line in
                        Task { @MainActor [weak self] in
                            self?.shipmentStatus[""] = line
                            window.update(status: line)
                        }
                    }
                    return .success(outcomes)
                } catch {
                    return .failure(error)
                }
            }.value

            window.close()
            guard let self else { return }
            self.shipping.remove("")
            self.shipmentStatus[""] = nil
            switch result {
            case .failure(let error):
                self.banner = Banner(kind: .error, title: "Couldn't install the shipment", detail: "\(error)")
            case .success(let outcomes):
                guard let distro = GuestDistro(rawValue: manifest.source.distro) else {
                    self.banner = Banner(kind: .error, title: "Unknown distribution",
                                         detail: "This shipment says it is '\(manifest.source.distro)', which this MSL doesn't know.")
                    return
                }
                _ = DaemonClient.send(.createInstance(instance: chosen, distro: distro))
                // Best effort, said out loud rather than left to be noticed.
                let skipped = outcomes.compactMap { outcome -> String? in
                    if case .skipped(let key, let why) = outcome { return "\(key): \(why)" }
                    return nil
                }
                // A shipment carries the filesystem and nothing else. Without
                // the distro's image on this Mac there is no kernel to boot
                // it with, and saying "installed" alone sent someone to a raw
                // VZErrorDomain dump the first time they pressed Start.
                let needsImage = Shipment.missingDistroImage(for: chosen, distro: distro) != nil
                self.banner = Banner(
                    kind: needsImage ? .info : (skipped.isEmpty ? .success : .info),
                    title: "\(chosen) installed",
                    detail: needsImage
                        ? "From \(url.lastPathComponent). \(distro.displayName) isn't downloaded on this Mac yet - install it and \(chosen) will start."
                        : (skipped.isEmpty
                           ? "From \(url.lastPathComponent). Its settings apply to this instance only."
                           : "From \(url.lastPathComponent). Not applied here - \(skipped.joined(separator: "; "))."))
                await self.refresh()
                self.selection = chosen
            }
        }
    }

    /// The app names this instance has, for the manifest. Informational only.
    private func installedApps(for instance: Instance) -> [String] {
        apps[instance.name]?.map(\.name).sorted() ?? []
    }
}
