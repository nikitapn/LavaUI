import Foundation

/// A mountable filesystem, rather than a whole disk that may hold several of them.
public struct DiskVolume: Equatable, Sendable, Identifiable {
    public var id: String
    public var device: String
    public var label: String
    public var hintName: String
    public var filesystem: String
    public var partitionType: String
    public var model: String
    public var mountPoints: [String]
    public var size: UInt64
    public var external: Bool
    public var ignored: Bool

    public init(id: String, device: String, label: String = "", hintName: String = "",
                filesystem: String, partitionType: String = "", model: String = "",
                mountPoints: [String] = [], size: UInt64 = 0, external: Bool = false,
                ignored: Bool = false) {
        self.id = id
        self.device = device
        self.label = label
        self.hintName = hintName
        self.filesystem = filesystem
        self.partitionType = partitionType
        self.model = model
        self.mountPoints = mountPoints.filter { $0.hasPrefix("/") }.sorted {
            $0.count == $1.count ? $0 < $1 : $0.count < $1.count
        }
        self.size = size
        self.external = external
        self.ignored = ignored
    }

    public var mountPoint: String? { mountPoints.first }
    public var isMounted: Bool { !mountPoints.isEmpty }

    public var title: String {
        if !hintName.isEmpty { return hintName }
        if !label.isEmpty { return label }
        if mountPoints.contains("/") { return "Linux" }
        let capacity = ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .decimal)
        return "\(capacity) \(filesystem.uppercased()) Volume"
    }

    /// These are infrastructure partitions, not locations a person browses.
    public var isVisible: Bool {
        let hidden = [
            "c12a7328-f81f-11d2-ba4b-00a0c93ec93b", // EFI system
            "21686148-6449-6e6f-744e-656564454649", // BIOS boot
            "e3c9e316-0b5c-4db8-817d-f92df00215ae", // Microsoft reserved
            "de94bba4-06d1-4d40-a16a-bfd50179d6ac", // Windows recovery
        ]
        return !ignored && !filesystem.isEmpty && !hidden.contains(partitionType.lowercased())
            && !device.hasPrefix("/dev/loop") && !device.hasPrefix("/dev/zram")
            && !mountPoints.contains { $0 == "/boot" || $0.hasPrefix("/boot/") || $0 == "/efi" }
    }

    public var canUnmount: Bool {
        // Keep system volumes browsable, with no unmount affordance. UDisks
        // still enforces permissions and busy checks for every other volume.
        let system = ["/", "/home", "/usr", "/var", "/opt", "/boot", "/efi", "/etc", "/srv"]
        let home = NSHomeDirectory()
        return isMounted && !mountPoints.contains { mount in
            home == mount || home.hasPrefix(mount + "/") || system.contains(mount) || ["/usr/", "/var/", "/boot/", "/etc/"].contains { mount.hasPrefix($0) }
        }
    }

    public func contains(_ path: String) -> Bool {
        mountPoints.contains { mount in
            mount == "/" ? path.hasPrefix("/") : path == mount || path.hasPrefix(mount + "/")
        }
    }

    /// Prefer the most specific mount when one filesystem is mounted inside another.
    public static func selected(in volumes: [DiskVolume], path: String) -> String? {
        volumes.compactMap { volume -> (String, Int)? in
            let matches = volume.mountPoints.filter { mount in
                mount == "/" ? path.hasPrefix("/") : path == mount || path.hasPrefix(mount + "/")
            }
            guard let length = matches.map(\.count).max() else { return nil }
            return (volume.id, length)
        }.max { $0.1 < $1.1 }?.0
    }
}
