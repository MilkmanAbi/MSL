// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation
#if canImport(Virtualization)
import Virtualization
#endif

/// Builds a headless `VZVirtualMachineConfiguration` for driving Alpine's
/// netboot live environment over a serial console - the common device set
/// `bootstrap-guest` and `extract-guest-modules` both need (kernel/initrd,
/// NAT networking, serial port, optional disk, optional single directory
/// share), so each tool only has to specify what's different about it.
public enum LiveBootConfig {
    public static func headlessConfiguration(
        kernelURL: URL,
        initrdURL: URL,
        commandLine: String,
        cpuCount: Int,
        memorySize: UInt64,
        serialAttachment: VZSerialPortAttachment,
        diskURL: URL? = nil,
        directoryShares: [(tag: String, path: URL, readOnly: Bool)] = []
    ) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.initialRamdiskURL = initrdURL
        bootLoader.commandLine = commandLine
        config.bootLoader = bootLoader

        config.cpuCount = cpuCount
        config.memorySize = memorySize

        if let diskURL {
            let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
        }

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [net]

        let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialConfig.attachment = serialAttachment
        config.serialPorts = [serialConfig]

        if !directoryShares.isEmpty {
            config.directorySharingDevices = directoryShares.map { share in
                let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
                fsDevice.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: share.path, readOnly: share.readOnly))
                return fsDevice
            }
        }

        try config.validate()
        return config
    }
}
