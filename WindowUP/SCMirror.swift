import SwiftUI
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage

// MARK: - Mirror live via ScreenCaptureKit (stile Floaty: SCStream @~15fps)

/// Cattura la singola finestra (anche se coperta, grazie a desktopIndependentWindow)
/// e pubblica i frame come NSImage. Richiede Registrazione schermo.
final class SCMirrorSession: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published var frame: NSImage?
    @Published var status: String = "avvio…"
    @Published var failed = false
    @Published var needsPermission = false

    private var stream: SCStream?
    private var streamTask: Task<Void, Never>?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var wid: UInt32 = 0
    private var goneTimer: Timer?

    func start(wid: UInt32) {
        stop()
        self.wid = wid
        status = "avvio…"
        failed = false
        needsPermission = false
        streamTask = Task { [weak self] in
            await self?.runCapture(wid: wid)
        }
        // Controllo chiusura finestra sorgente (non serve permesso per l'esistenza).
        goneTimer?.invalidate()
        goneTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !WindowPinning.shared.windowExists(self.wid) {
                self.status = "finestra chiusa"
                self.stop()
            }
        }
        if let t = goneTimer { RunLoop.main.add(t, forMode: .common) }
    }

    func stop() {
        goneTimer?.invalidate()
        goneTimer = nil
        streamTask?.cancel()
        streamTask = nil
        if let s = stream {
            stream = nil
            Task { try? await s.stopCapture() }
        }
    }

    private func runCapture(wid: UInt32) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard !Task.isCancelled else { return }
            guard let win = content.windows.first(where: { $0.windowID == CGWindowID(wid) }) else {
                await setStatus("finestra non trovata", failed: true)
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            // Risoluzione contenuta: basta per uno sticker nitido, leggera sulla CPU.
            cfg.width = 960
            cfg.height = 600
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            cfg.showsCursor = true
            cfg.queueDepth = 3
            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            self.stream = stream
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()
            await setStatus("LIVE", failed: false)
        } catch {
            await handleStartError(error)
        }
    }

    @MainActor
    private func setStatus(_ s: String, failed: Bool) {
        status = s
        self.failed = failed
    }

    @MainActor
    private func handleStartError(_ error: Error) {
        let code = (error as NSError).code
        if code == -3801 || code == -3802 {
            // Permesso negato / revocato.
            status = "serve Registrazione schermo"
            needsPermission = true
            failed = true
        } else if (error as NSError).domain == NSURLErrorDomain {
            status = "finestra non trovata"
            failed = true
        } else {
            status = "errore cattura (\(code))"
            failed = true
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let img = imageFromSampleBuffer(sampleBuffer) else { return }
        Task { @MainActor [weak self] in
            self?.frame = img
            if self?.status != "LIVE" { self?.status = "LIVE" }
        }
    }

    private func imageFromSampleBuffer(_ sb: CMSampleBuffer) -> NSImage? {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self = self, self.stream != nil else { return }
            await self.handleStartError(error)
        }
    }
}
