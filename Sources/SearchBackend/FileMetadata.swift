import Foundation
import CoreServices

package enum FileMetadata {
    package static func finderTags(_ url: URL, followSymlinks: Bool = false) -> [String]? {
        let key = "com.apple.metadata:_kMDItemUserTags"
        let options = followSymlinks ? 0 : XATTR_NOFOLLOW
        for _ in 0..<3 {
            let size = getxattr(url.path, key, nil, 0, 0, options)
            if size < 0 { return [ENOATTR, ENOTSUP, ENOENT].contains(errno) ? [] : nil }
            guard size <= 1024 * 1024 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, size, 0, options) }
            if read < 0 { if errno == ERANGE { continue }; return nil }
            if read == 0 { return [] }
            data.count = read
            guard let tags = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else { return nil }
            return tags.map { tag in
                guard let newline = tag.lastIndex(of: "\n"), tag[tag.index(after: newline)...].count == 1,
                      tag.last?.isNumber == true else { return tag }
                return String(tag[..<newline])
            }
        }
        return nil
    }
    /// File access time also changes for background readers; it is not a record
    /// of a user opening a document. Missing Spotlight metadata stays unknown.
    package static func lastOpened(_ url: URL) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
