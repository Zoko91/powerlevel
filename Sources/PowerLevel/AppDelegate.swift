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
        logi.onUpdate = { [weak self, weak bar] batteries in
            bar?.update(batteries)
            self?.syncPollingTimer()
        }
        logiMonitor = logi

        let corsair = CorsairMonitor()
        corsair.onUpdate = { [weak self, weak bar] battery in
            bar?.update(battery)
            self?.syncPollingTimer()
        }
        corsairMonitor = corsair

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

        // Initial check; polling timer only starts if at least one device is online
        refreshAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPollingTimer()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        logiMonitor?.stop()
        corsairMonitor?.stop()
    }

    private func syncPollingTimer() {
        let anyOnline = (logiMonitor?.hasOnlineDevice ?? false) || (corsairMonitor?.hasOnlineDevice ?? false)
        if anyOnline {
            startPollingTimerIfNeeded()
        } else {
            stopPollingTimer()
        }
    }

    private func startPollingTimerIfNeeded() {
        guard pollTimer == nil else { return }
        // Poll every 5 minutes only while at least one device is online;
        // 60s tolerance lets macOS coalesce timer wakeups for minimal CPU/power
        let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshOnlineMonitors()
            }
        }
        timer.tolerance = 60
        pollTimer = timer
    }

    private func stopPollingTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshOnlineMonitors() {
        if logiMonitor?.hasOnlineDevice == true {
            logiMonitor?.refresh()
        }
        if corsairMonitor?.hasOnlineDevice == true {
            corsairMonitor?.refresh()
        }
    }

    private func refreshAll() {
        logiMonitor?.refresh()
        corsairMonitor?.refresh()
    }
}
