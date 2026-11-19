import SwiftUI
import UIKit

// ExactJPEG Check: runs the exactness checks and benchmarks of Runner.swift on launch, shows progress, prints every
// result line to stdout and writes Documents/results-<date>.json. Launch arguments:
//   --timing-only   device properties and the timing section only
//   --decode-profile  device properties, the per-stage decode profile and the GPU clock experiments (DecodeProfile.swift)
//   --decode-ab     device properties and the chunkBits A/B of DecodeProfile.swift chunkAB
//   --load-routing  device properties, the load-correction wiring checks and the routing acceptance cells (LoadRouting.swift)
//   --public        device properties and public-bench's comparison on the exported public JPEGs in Public/ (PublicMode.swift)
//   --exit          exit when done (run-device.sh passes it, so `devicectl ... --console` returns)

final class Progress: ObservableObject {
    @Published var lines: [String] = []
    @Published var status = "starting"
    @Published var done = false
}

@main
struct CheckApp: App {
    @StateObject private var progress = Progress()
    var body: some Scene {
        WindowGroup {
            ContentView(progress: progress)
                .onAppear { start() }
        }
    }

    private func start() {
        guard progress.lines.isEmpty, progress.status == "starting" else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        UIApplication.shared.isIdleTimerDisabled = true
        let args = ProcessInfo.processInfo.arguments
        let p = progress
        let thread = Thread {
            let r = Runner(timingOnly: args.contains("--timing-only")) { line, status in
                DispatchQueue.main.async {
                    if let line { p.lines.append(line); if p.lines.count > 400 { p.lines.removeFirst(p.lines.count - 400) } }
                    if let status { p.status = status }
                }
            }
            let file = r.run()
            DispatchQueue.main.async {
                p.done = true; p.status = "done: \(file)"
                UIApplication.shared.isIdleTimerDisabled = false
                if args.contains("--exit") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) } }
            }
        }
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

struct ContentView: View {
    @ObservedObject var progress: Progress
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ExactJPEG Check").font(.headline)
            Text(progress.status).font(.subheadline).foregroundColor(progress.done ? .green : .secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(progress.lines.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(size: 10, design: .monospaced)).id(i)
                        }
                    }
                }
                .onChange(of: progress.lines.count) { n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
        .padding()
    }
}
