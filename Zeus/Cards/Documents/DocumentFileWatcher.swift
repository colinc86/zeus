import Foundation
import Darwin

/// Watch the parent directory so atomic replacement at the same path also refreshes the document.
final class DocumentFileWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    init?(url: URL, changed: @escaping @Sendable () -> Void) {
        let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let descriptor = open((directory ? url : url.deletingLastPathComponent()).path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib], queue: .global(qos: .utility))
        source.setEventHandler(handler: changed)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }
    deinit { source.cancel() }
}
