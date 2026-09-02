import SwiftUI
import AppKit
import Foundation

// MARK: - Hysteria Controller

class HysteriaController: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var status: String = "Disconnected"
    @Published var publicIP: String = "—"
    @Published var latency: Int = 0
    @Published var mode: String = "Full Tunnel (TUN)"
    @Published var isStarting: Bool = false

    private var timer: Timer?
    private var isStopping = false

    let scriptPath = NSHomeDirectory() + "/Library/Application Support/HysteriaMenu/hysteria-helper.sh"

    init() {
        // Copy helper script from app bundle to user's Application Support (if newer)
        let appHelper = Bundle.main.bundlePath + "/Contents/Resources/hysteria-helper.sh"
        let userHelper = NSHomeDirectory() + "/Library/Application Support/HysteriaMenu/hysteria-helper.sh"

        let fm = FileManager.default
        if fm.fileExists(atPath: appHelper) {
            let appAttrs = try? fm.attributesOfItem(atPath: appHelper)
            let userAttrs = try? fm.attributesOfItem(atPath: userHelper)
            let appMtime = (appAttrs?[.modificationDate] as? Date) ?? Date.distantPast
            let userMtime = (userAttrs?[.modificationDate] as? Date) ?? Date.distantPast

            // Copy if app version is newer or user version doesn't exist
            if appMtime > userMtime {
                try? fm.createDirectory(atPath: (userHelper as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                try? fm.removeItem(atPath: userHelper)
                try? fm.copyItem(atPath: appHelper, toPath: userHelper)
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: userHelper)
            }
        }

        // Sync initial state with system
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkRealStatus()
        }
    }

    func checkRealStatus() {
        // Actually check if hysteria and tun2socks are running
        let hysteriaRunning = isProcessRunning(name: "hysteria")
        let tun2socksRunning = isProcessRunning(name: "tun2socks")

        let wasRunning = isRunning
        isRunning = hysteriaRunning && tun2socksRunning

        if isRunning {
            status = "Connected"
        } else if hysteriaRunning || tun2socksRunning {
            status = "Partial connection"
        } else {
            status = "Disconnected"
            publicIP = "—"
            latency = 0
        }

        // Notify observers about status change
        if wasRunning != isRunning {
            NotificationCenter.default.post(name: NSNotification.Name("HysteriaStatusChanged"), object: nil)
        }

        if isRunning {
            refreshStatus()
            startMonitoring()
        }
    }

    private func isProcessRunning(name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // Use -f to match full command line (works for tun2socks-bin)
        task.arguments = ["-f", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    func start() {
        guard !isRunning && !isStarting else { return }

        isStarting = true
        status = "Connecting..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let result = self.runHelper(action: "start")
            NSLog("HysteriaMenu: start result: \(result)")

            // Wait then check actual status
            Thread.sleep(forTimeInterval: 3.0)

            DispatchQueue.main.async {
                self.isStarting = false
                self.checkRealStatus()
            }
        }
    }

    func stop() {
        guard isRunning && !isStopping else { return }

        isStopping = true
        status = "Disconnecting..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let result = self.runHelper(action: "stop")
            NSLog("HysteriaMenu: stop result: \(result)")

            // Wait then check actual status
            Thread.sleep(forTimeInterval: 2.0)

            DispatchQueue.main.async {
                self.isStopping = false
                self.checkRealStatus()
            }
        }
    }

    private func runHelper(action: String) -> String {
        // Spawn osascript as a subprocess - this is a signed system binary
        // and will show Touch ID option (instead of just password)
        // Use quoted form of POSIX path to handle spaces in path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // scriptPath may contain spaces (e.g. "Application Support"), so escape it
        let escapedPath = scriptPath.replacingOccurrences(of: "\"", with: "\\\"")
        task.arguments = [
            "-e",
            "do shell script \"\\\"\(escapedPath)\\\" \(action) 2>&1\" with administrator privileges"
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            if task.terminationStatus == 0 {
                return output
            } else {
                NSLog("HysteriaMenu: \(action) failed: \(errorOutput)")
                return "error: \(errorOutput)"
            }
        } catch {
            NSLog("HysteriaMenu: \(action) exception: \(error)")
            return "exception: \(error.localizedDescription)"
        }
    }

    func refreshStatus() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            // Get public IP
            let ipTask = Process()
            ipTask.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            ipTask.arguments = ["-s", "--max-time", "5", "https://ifconfig.me"]
            let ipPipe = Pipe()
            ipTask.standardOutput = ipPipe
            ipTask.standardError = Pipe()
            do {
                try ipTask.run()
                ipTask.waitUntilExit()
                let data = ipPipe.fileHandleForReading.readDataToEndOfFile()
                let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
                DispatchQueue.main.async {
                    self.publicIP = ip.isEmpty ? "—" : ip
                }
            } catch {
                DispatchQueue.main.async {
                    self.publicIP = "—"
                }
            }

            // Measure latency
            let pingTask = Process()
            pingTask.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            pingTask.arguments = ["-s", "-o", "/dev/null", "-w", "%{time_total}", "https://httpbin.org/get"]
            let pingPipe = Pipe()
            pingTask.standardOutput = pingPipe
            pingTask.standardError = Pipe()
            do {
                try pingTask.run()
                pingTask.waitUntilExit()
                let data = pingPipe.fileHandleForReading.readDataToEndOfFile()
                if let timeStr = String(data: data, encoding: .utf8),
                   let time = Double(timeStr) {
                    DispatchQueue.main.async {
                        self.latency = Int(time * 1000)
                    }
                }
            } catch {}
        }
    }

    private func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @ObservedObject var controller: HysteriaController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(controller.isRunning ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(controller.status)
                    .font(.headline)
            }

            HStack {
                Text("Mode:")
                    .foregroundColor(.secondary)
                Text(controller.mode)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.blue)
            }
            .font(.callout)

            if controller.isRunning {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("IP:")
                            .foregroundColor(.secondary)
                        Text(controller.publicIP)
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack {
                        Text("Latency:")
                            .foregroundColor(.secondary)
                        Text("\(controller.latency)ms")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(controller.latency < 200 ? .green : .orange)
                    }
                }
                .font(.callout)
            }

            Divider()

            if controller.isRunning {
                Button("Disconnect") {
                    controller.stop()
                }
            } else {
                Button("Connect") {
                    controller.start()
                }
                .disabled(controller.isStarting)
            }

            Button("Refresh Status") {
                controller.checkRealStatus()
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(width: 280)
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = HysteriaController()
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    private var observer: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("HysteriaMenu: starting")

        statusItem = NSStatusBar.system.statusItem(withLength: 32)

        if let button = statusItem?.button {
            button.font = NSFont.systemFont(ofSize: 16, weight: .bold)
            button.action = #selector(togglePopover)
            button.target = self
            updateMenuBarIcon()
        } else {
            NSLog("HysteriaMenu: ERROR - no status item")
            NSApp.setActivationPolicy(.regular)
            return
        }

        popover = NSPopover()
        popover?.contentSize = NSSize(width: 280, height: 220)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: MenuBarView(controller: controller))

        // Listen for status change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusDidChange),
            name: NSNotification.Name("HysteriaStatusChanged"),
            object: nil
        )

        // Sync status periodically
        Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.controller.checkRealStatus()
        }

        NSLog("HysteriaMenu: ready")
    }

    @objc func statusDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.updateMenuBarIcon()
        }
    }

    func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        // Green circle when on, dark circle when off
        button.title = controller.isRunning ? "🟢" : "⚫"
        button.font = NSFont.systemFont(ofSize: 14, weight: .bold)
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                controller.refreshStatus()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("HysteriaMenu: terminating (keeping VPN running)")
        // Don't stop VPN on quit - let user manually control
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Activate and run
app.activate(ignoringOtherApps: true)
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)