import Foundation
import Darwin

/// The file catches in-place writes; its parent catches atomic replacement and later reappearance.
final class DocumentFileWatcher: @unchecked Sendable {
    private let sources: [DispatchSourceFileSystemObject]
    init?(url: URL, changed: @escaping @Sendable () -> Void) {
        var watched: [DispatchSourceFileSystemObject] = []
        for path in Set([url.path, url.deletingLastPathComponent().path]) {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .global(qos: .utility))
            source.setEventHandler(handler: changed)
            source.setCancelHandler { close(descriptor) }
            source.resume(); watched.append(source)
        }
        guard !watched.isEmpty else { return nil }
        sources = watched
    }
    deinit { for source in sources { source.cancel() } }
}
