import AppKit
import Testing
@testable import Nimb

@Suite @MainActor struct WindowConfiguratorTests {
    @Test func normalizesTheFrameAgainAfterRestoration() async {
        let window = NSWindow(contentRect: CGRect(x: 40, y: 60, width: 1100, height: 962),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(WindowConfigurator.LockView())
        await finishLayout()

        let fixedFrame = window.frame.size
        #expect(window.contentLayoutRect.size == CGSize(width: 1100, height: 660))
        #expect(window.minSize == fixedFrame && window.maxSize == fixedFrame)
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.styleMask.contains([.closable, .miniaturizable]))
        #expect(window.collectionBehavior.contains([.fullScreenNone, .fullScreenDisallowsTiling]))
        #expect(window.isMovableByWindowBackground)

        var restored = window.frame
        restored.size.height += 275
        window.maxSize = restored.size
        window.setFrame(restored, display: false)
        await finishLayout()
        #expect(window.frame.size == fixedFrame)
        #expect(window.maxSize == fixedFrame)
    }

    private func finishLayout() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
