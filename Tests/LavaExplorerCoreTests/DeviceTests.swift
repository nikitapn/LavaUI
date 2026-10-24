import Foundation
import Testing
@testable import LavaExplorerCore

@Suite("Explorer devices")
struct DeviceTests {
    @Test("Internal Linux, Windows and a USB SSD are browsable; system and recovery partitions are hidden")
    func visibility() {
        let linux = DiskVolume(id: "linux", device: "/dev/nvme0n1p2", filesystem: "ext4", mountPoints: ["/"])
        let windows = DiskVolume(id: "windows", device: "/dev/nvme1n1p2", label: "Data", filesystem: "ntfs", mountPoints: ["/mnt/windows"])
        let portable = DiskVolume(id: "usb", device: "/dev/sda1", label: "Portable", filesystem: "ntfs", external: true)
        #expect(linux.isVisible && windows.isVisible && portable.isVisible)
        #expect(linux.title == "Linux")
        #expect(windows.title == "Data")
        #expect(!linux.canUnmount)
        #expect(windows.canUnmount)
        #expect(!portable.isMounted)
        for partition in ["C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "de94bba4-06d1-4d40-a16a-bfd50179d6ac",
                          "e3c9e316-0b5c-4db8-817d-f92df00215ae", "21686148-6449-6e6f-744e-656564454649"] {
            let volume = DiskVolume(id: partition, device: "/dev/sda2", filesystem: "vfat", partitionType: partition)
            #expect(!volume.isVisible)
        }
        #expect(!DiskVolume(id: "loop", device: "/dev/loop0", filesystem: "squashfs").isVisible)
        #expect(!DiskVolume(id: "ignored", device: "/dev/sda2", filesystem: "ext4", ignored: true).isVisible)
    }

    @Test("System mounts cannot be unmounted even through another bind mount")
    func protectedMounts() {
        for path in ["/", "/home", "/usr", "/usr/local", "/var", "/var/lib", "/opt", "/boot", "/efi", NSHomeDirectory()] {
            let volume = DiskVolume(id: path, device: "/dev/mapper/system", filesystem: "btrfs", mountPoints: ["/mnt/bind", path])
            #expect(!volume.canUnmount)
        }
    }

    @Test("Selection uses the most specific mount and respects path boundaries")
    func selection() {
        let root = DiskVolume(id: "root", device: "/dev/nvme0n1p2", filesystem: "ext4", mountPoints: ["/home/user/bind", "/"])
        let data = DiskVolume(id: "data", device: "/dev/nvme1n1p2", filesystem: "ntfs", mountPoints: ["/mnt/windows"])
        #expect(root.mountPoint == "/")
        #expect(DiskVolume.selected(in: [root, data], path: "/mnt/windows/Users") == "data")
        #expect(DiskVolume.selected(in: [root, data], path: "/mnt/windows-backup") == "root")
        #expect(!data.contains("/mnt/windows-backup"))
        #expect(data.contains("/mnt/windows"))
        #expect(DiskVolume.selected(in: [root, data], path: "ftp://host/photos") == nil)
    }

    @Test("Existing profiles retain their data when the Devices section is introduced")
    func profileMigration() throws {
        var profile = ExplorerProfile(name: "Work", id: "work")
        profile.favorites = ["/work"]
        profile.serversExpanded = false
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json.removeValue(forKey: "devicesExpanded")
        let restored = try JSONDecoder().decode(ExplorerProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.devicesExpanded)
        #expect(restored.favorites == ["/work"])
        #expect(!restored.serversExpanded)
        var closed = restored
        closed.devicesExpanded = false
        #expect(try JSONDecoder().decode(ExplorerProfile.self, from: JSONEncoder().encode(closed)).devicesExpanded == false)
    }
}
