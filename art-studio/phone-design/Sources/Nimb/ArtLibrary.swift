import AppKit
import ImageIO

/// The pictures of the interface (halo, figures, icons), loaded from the app when they are first needed and let go when the
/// window closes: a program that sits in the background should not keep tens of megabytes of pictures.
final class ArtLibrary: @unchecked Sendable {
    static let shared = ArtLibrary()

    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private var sequences: [String: [CGImage]] = [:]

    private init() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, window.canBecomeMain else { return }
            self?.purge()
        }
    }

    /// One picture of a folder of `Art`, for example `image("halo", "back.png")`.
    func image(_ folder: String, _ file: String) -> CGImage? {
        let key = folder + "/" + file
        lock.lock()
        if let cached = images[key] { lock.unlock(); return cached }
        lock.unlock()
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Art/\(key)"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        lock.lock(); images[key] = image; lock.unlock()
        return image
    }

    /// A numbered sequence, for example `sequence("halo", pattern: "sparkle-%02d.png", frames: 24)`.
    func sequence(_ folder: String, pattern: String, frames: Int) -> [CGImage] {
        let key = folder + "/" + pattern
        lock.lock()
        if let cached = sequences[key] { lock.unlock(); return cached }
        lock.unlock()
        let loaded = (0..<frames).compactMap { image(folder, String(format: pattern, $0)) }
        lock.lock(); sequences[key] = loaded; lock.unlock()
        return loaded
    }

    /// Lets go of everything; the pictures come back from the files when they are needed again.
    func purge() {
        lock.lock(); images.removeAll(); sequences.removeAll(); lock.unlock()
    }
}
