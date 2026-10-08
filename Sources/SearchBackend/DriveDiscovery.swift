import Foundation

package struct StorageVolume: Identifiable, Hashable, Sendable {
    package let url: URL
    package let name: String

    package var id: String {
        url.path
    }
    package init(url: URL, name: String) {
        self.url = url
        self.name = name
    }

}

package enum DriveDiscovery {
    package static func availableVolumes() -> [StorageVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let fileManager = FileManager.default

        var volumes: [StorageVolume] = []
        if let mounted = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) {
            volumes = mounted.compactMap { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.volumeIsBrowsable != false else {
                    return nil
                }
                let name = values?.volumeName ?? url.lastPathComponent
                return StorageVolume(url: url, name: name.isEmpty ? url.path : name)
            }
        }

        if !volumes.contains(where: { $0.url.path == "/" }) {
            let rootName = volumeName(for: URL(fileURLWithPath: "/")) ?? "Macintosh HD"
            volumes.insert(StorageVolume(url: URL(fileURLWithPath: "/"), name: rootName), at: 0)
        }

        return volumes.sorted { lhs, rhs in
            switch (lhs.url.path == "/", rhs.url.path == "/") {
            case (true, false):
                return true
            case (false, true):
                return false
            default:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    package static func primaryVolume() -> StorageVolume {
        availableVolumes().first(where: { $0.url.path == "/" }) ?? StorageVolume(
            url: URL(fileURLWithPath: "/"),
            name: volumeName(for: URL(fileURLWithPath: "/")) ?? "Macintosh HD"
        )
    }

    package static func volumeName(for url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName
    }
}
