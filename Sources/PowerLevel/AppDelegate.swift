import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var logiMonitor: LogiBoltMonitor?
    private var corsairMonitor: CorsairMonitor?
    private var pollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bar = StatusBarController { [weak self] in
            self?.refreshAll()
        }
        statusBar = bar

        let logi = LogiBoltMonitor()
        logi.onUpdate = { [weak bar] batteries in
            bar?.update(batteries)
        }
        logiMonitor = logi

        let corsair = CorsairMonitor()
        corsair.onUpdate = { [weak bar] battery in
            bar?.update(battery)
        }
        corsairMonitor = corsair

        // Poll every 5 minutes (hardware pushes live changes asynchronously;
        // 60s tolerance lets macOS coalesce timer wakeups for minimal power/CPU)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAll()
            }
        }
        pollTimer?.tolerance = 60

        // Refresh immediately after Mac wakes from sleep
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAll()
            }
        }

        // Initial refresh
        refreshAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        logiMonitor?.stop()
        corsairMonitor?.stop()
    }

    private func refreshAll() {
        logiMonitor?.refresh()
        corsairMonitor?.refresh()
    }
}
