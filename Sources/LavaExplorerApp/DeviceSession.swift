import CUDisks
import Foundation
import LavaExplorerCore
import LavaUI

private final class VolumeCollector {
    var volumes: [DiskVolume] = []
}

private func bufferText(_ value: [CChar]) -> String {
    String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func text(_ value: UnsafePointer<CChar>?) -> String {
    value.map { String(cString: $0) } ?? ""
}

/// UDisks calls can wait for the system bus or authentication. A serial worker
/// keeps both that work and hotplug refreshes off the frame loop.
final class DeviceMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lava.explorer.devices", qos: .utility)
    private let timer: DispatchSourceTimer
    private let update: @Sendable ([DiskVolume], String?) -> Void

    init(update: @escaping @Sendable ([DiskVolume], String?) -> Void) {
        self.update = update
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
    }

    deinit { timer.cancel() }

    private func refresh() {
        let collector = VolumeCollector()
        var error = [CChar](repeating: 0, count: 2048)
        let status = lava_disks_list({ context, raw in
            guard let context, let raw else { return }
            let target = Unmanaged<VolumeCollector>.fromOpaque(context).takeUnretainedValue()
            let value = raw.pointee
            let mounts = (0..<Int(value.mount_count)).map { text(value.mount_points?[$0]) }
            let volume = DiskVolume(
                id: text(value.object_path), device: text(value.device), label: text(value.label),
                hintName: text(value.hint_name), filesystem: text(value.filesystem),
                partitionType: text(value.partition_type), model: text(value.model),
                mountPoints: mounts, size: value.size, external: value.external != 0,
                ignored: value.ignored != 0
            )
            if volume.isVisible { target.volumes.append(volume) }
        }, Unmanaged.passUnretained(collector).toOpaque(), &error, error.count)
        let volumes = collector.volumes.sorted {
            if $0.external != $1.external { return !$0.external }
            return $0.title == $1.title ? $0.device < $1.device : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        update(volumes, status < 0 ? "Devices unavailable: \(bufferText(error))" : nil)
    }

    func perform(_ volume: DiskVolume, unmount: Bool,
                 completion: @escaping @Sendable (Result<String, DeviceError>) -> Void) {
        queue.async { [weak self] in
            var result = [CChar](repeating: 0, count: 4096)
            var error = [CChar](repeating: 0, count: 2048)
            let status = lava_disks_mount(volume.id, unmount ? 1 : 0, &result, result.count, &error, error.count)
            completion(status < 0 ? .failure(DeviceError(message: bufferText(error)))
                                 : .success(bufferText(result)))
            self?.refresh()
        }
    }
}

struct DeviceError: Error, Sendable { var message: String }

extension ExplorerSession {
    func startDevices() {
        deviceMonitor = DeviceMonitor { [weak self] volumes, error in
            MainQueue.async { [weak self] in
                guard let self else { return }
                // Polling a clean desktop must not make a frame.
                if !self.devicesLoaded || self.devices != volumes || self.devicesError != error {
                    if error == nil {
                        let missing = self.devices.compactMap { old -> DiskVolume? in
                            guard old.canUnmount else { return nil }
                            let mounts = volumes.first { $0.id == old.id }?.mountPoints ?? []
                            var removed = old
                            removed.mountPoints = old.mountPoints.filter { !mounts.contains($0) }
                            return removed.mountPoints.isEmpty ? nil : removed
                        }
                        self.leaveDevices(missing)
                    }
                    self.devicesLoaded = true
                    self.devices = volumes
                    self.devicesError = error
                    ViewInvalidation.markDirty()
                }
            }
        }
    }

    private func leaveDevices(_ volumes: [DiskVolume]) {
        guard !volumes.isEmpty else { return }
        let source = self.source
        layout.updateAllTabs { tab in
            if volumes.contains(where: { $0.contains(tab.listing.path) }) {
                tab.open(NSHomeDirectory(), scroll: 0, source: source)
            }
        }
    }

    func openDevice(_ volume: DiskVolume) {
        guard deviceBusy == nil else { return }
        if let path = volume.mountPoint { go(path); return }
        changeDevice(volume, unmount: false)
    }

    func unmountDevice(_ volume: DiskVolume) {
        guard volume.canUnmount, deviceBusy == nil else { return }
        guard canUnmountDevices else {
            notice = "Finish the current file operation before unmounting"
            ViewInvalidation.markDirty()
            return
        }
        changeDevice(volume, unmount: true)
    }

    private func changeDevice(_ volume: DiskVolume, unmount: Bool) {
        guard let deviceMonitor else { return }
        deviceBusy = volume.id
        let profileID = profiles.selectedID
        let tabID = tabSet.currentID
        let oldPath = listing.path
        notice = "\(unmount ? "Unmounting" : "Mounting") \(volume.title)…"
        deviceMonitor.perform(volume, unmount: unmount) { [weak self] result in
            MainQueue.async { [weak self] in
                guard let self else { return }
                self.deviceBusy = nil
                switch result {
                case .failure(let error): self.notice = error.message
                case .success(let path):
                    self.notice = "\(unmount ? "Unmounted" : "Mounted") \(volume.title)"
                    if unmount {
                        // Close our directory watches and leave every tab on this
                        // volume after a successful unmount, including inactive panes.
                        self.leaveDevices([volume])
                    } else if self.profiles.selectedID == profileID,
                              self.tabSet.currentID == tabID, self.listing.path == oldPath {
                        self.go(path)
                    }
                }
                ViewInvalidation.markDirty()
            }
        }
    }
}
