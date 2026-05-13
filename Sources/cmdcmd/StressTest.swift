// Debug-only stress harness for the SCContentFilter / SCStream init race
// behind issue #18. Run with: cmdcmd --stress [--serialize] [--iterations N].
// Mirrors the concurrent setup pattern from Tile.start() (and fans it out
// 4x with a parallel SCShareableContent refresher). Could not reproduce the
// crash on macOS 15.7.4 / M4 Pro; intended for confirmation on macOS 26.
import Foundation
import ScreenCaptureKit
import CoreVideo
import CoreMedia

final class StressTarget: NSObject, SCStreamDelegate, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

enum StressTest {
    private static let setupQueue = DispatchQueue(label: "stress.setup")
    private static let sampleQueue = DispatchQueue(label: "stress.sample")

    static func run(serialize: Bool, iterations: Int) async {
        print("StressTest: serialize=\(serialize) iterations=\(iterations)")
        fflush(stdout)

        let prewarm = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            }
        }

        for i in 0..<iterations {
            let windows: [SCWindow]
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                windows = content.windows.filter {
                    $0.owningApplication != nil &&
                    $0.frame.width >= 200 && $0.frame.height >= 200
                }
            } catch {
                print("iter \(i) content fetch failed: \(error)")
                continue
            }

            await withTaskGroup(of: Void.self) { group in
                // Fan out to 4x the natural concurrency to widen the race window.
                for _ in 0..<4 {
                    for w in windows {
                        group.addTask {
                            await runOne(window: w, serialize: serialize)
                        }
                    }
                }
            }
            if i % 10 == 0 { print("iter \(i) windows=\(windows.count)"); fflush(stdout) }
        }

        prewarm.cancel()
        print("StressTest survived \(iterations) iterations")
        fflush(stdout)
        exit(0)
    }

    private static func runOne(window: SCWindow, serialize: Bool) async {
        let filter: SCContentFilter
        if serialize {
            filter = await withCheckedContinuation { cont in
                setupQueue.async {
                    cont.resume(returning: SCContentFilter(desktopIndependentWindow: window))
                }
            }
        } else {
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let config = SCStreamConfiguration()
        config.width = 512
        config.height = 512
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3

        let target = StressTarget()
        let stream: SCStream
        if serialize {
            stream = await withCheckedContinuation { cont in
                setupQueue.async {
                    cont.resume(returning: SCStream(filter: filter, configuration: config, delegate: target))
                }
            }
        } else {
            stream = SCStream(filter: filter, configuration: config, delegate: target)
        }
        try? stream.addStreamOutput(target, type: .screen, sampleHandlerQueue: sampleQueue)
        try? await stream.startCapture()
        try? await stream.stopCapture()
    }
}
