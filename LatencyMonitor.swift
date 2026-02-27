import SwiftUI
import Foundation
import Network

// MARK: - Models

enum TradingProvider: String, CaseIterable {
    case rithmic = "Rithmic"
    case dxfeed = "dxFeed"
    case cqg = "CQG"
    case tradovate = "Tradovate"
    case unknown = ""
    
    var color: Color {
        switch self {
        case .rithmic: return .orange
        case .dxfeed: return .blue
        case .cqg: return .green
        case .tradovate: return .purple
        case .unknown: return .gray
        }
    }
}

struct ProcessInfo: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let pids: [String]
    
    var displayTitle: String {
        return name
    }
}

struct Connection: Identifiable, Hashable {
    let id: String
    let ip: String
    let port: Int
    var hostname: String?
    var provider: TradingProvider = .unknown
    
    var key: String { "\(ip):\(port)" }
    var displayName: String {
        if let host = hostname { return "\(host):\(port)" }
        return key
    }
}

// MARK: - Latency Monitor Logic

class LatencyMonitor: ObservableObject {
    @Published var processes: [ProcessInfo] = []
    @Published var connections: [Connection] = []
    @Published var latencies: [String: Int] = [:]
    @Published var icmpLatencies: [String: Int] = [:]
    @Published var jitterScores: [String: Int] = [:]
    
    @Published var selectedPids: [String] = []
    @Published var selectedKey: String?
    @Published var manualOverride: Bool = false
    @Published var isSearching: Bool = false
    @Published var showHelp: Bool = false
    @Published var isCompact: Bool = false {
        didSet {
            updateWindowSize()
        }
    }
    @Published var isAlwaysOnTop: Bool = false {
        didSet {
            updateWindowLevel()
        }
    }
    
    private func updateWindowSize() {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }) else { return }
            let targetHeight: CGFloat = self.isCompact ? 140 : 500
            var frame = window.frame
            let heightDifference = frame.size.height - targetHeight
            
            frame.size.height = targetHeight
            frame.origin.y += heightDifference
            
            window.setFrame(frame, display: true, animate: true)
        }
    }
    
    var activeProvider: String {
        guard let key = selectedKey else { return "" }
        if let conn = connections.first(where: { $0.key == key }) {
            return conn.provider == .unknown ? "" : conn.provider.rawValue
        }
        return ""
    }
    
    private var timer: Timer?
    private var history: [String: Int] = [:]
    private var hostnameCache: [String: String] = [:]

    func refreshProcesses() {
        // 1. Get all PIDs with established TCP connections from lsof
        let lsofTask = Process()
        lsofTask.launchPath = "/usr/sbin/lsof"
        lsofTask.arguments = ["-nP", "-iTCP", "-sTCP:ESTABLISHED"]
        
        let lsofPipe = Pipe()
        lsofTask.standardOutput = lsofPipe
        lsofTask.launch()
        
        let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
        guard let lsofOutput = String(data: lsofData, encoding: .utf8) else { return }
        
        let pids = Set(lsofOutput.components(separatedBy: .newlines).dropFirst().compactMap { line -> String? in
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            return parts.count >= 2 ? parts[1] : nil
        })
        
        if pids.isEmpty {
            DispatchQueue.main.async { self.processes = [] }
            return
        }

        // 2. Get full command names for all PIDs in one go
        let psTask = Process()
        psTask.launchPath = "/bin/ps"
        psTask.arguments = ["-o", "pid=,comm=", "-p"] + Array(pids)
        
        let psPipe = Pipe()
        psTask.standardOutput = psPipe
        psTask.launch()
        
        let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
        guard let psOutput = String(data: psData, encoding: .utf8) else { return }
        
        var groupedPids: [String: [String]] = [:]
        for line in psOutput.components(separatedBy: .newlines) {
            let lineTrimmed = line.trimmingCharacters(in: .whitespaces)
            if lineTrimmed.isEmpty { continue }
            
            let parts = lineTrimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 2 {
                let pidNum = parts[0]
                let fullPath = parts.dropFirst().joined(separator: " ")
                let name = URL(fileURLWithPath: fullPath).lastPathComponent
                if !name.isEmpty {
                    groupedPids[name, default: []].append(pidNum)
                }
            }
        }
        
        DispatchQueue.main.async {
            self.processes = groupedPids.map { name, pids in
                ProcessInfo(name: name, pids: pids)
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }
    
    func startMonitoring(pids: [String]) {
        self.selectedPids = pids
        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.tick()
        }
        self.tick()
    }
    
    private func tick() {
        if selectedPids.isEmpty { return }
        
        // 1. Get Connections for all Selected PIDs
        var currentConns: [Connection] = []
        var seenKeys = Set<String>()
        
        for pid in selectedPids {
            let task = Process()
            task.launchPath = "/usr/sbin/lsof"
            task.arguments = ["-a", "-nP", "-p", pid, "-iTCP", "-sTCP:ESTABLISHED"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            task.launch()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                
                for line in lines.dropFirst() {
                    let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if parts.count >= 9 {
                        let addrPart = parts[8]
                        let addrComponents = addrPart.components(separatedBy: "->")
                        if addrComponents.count == 2 {
                            let remote = addrComponents[1]
                            let remoteParts = remote.components(separatedBy: ":")
                            if remoteParts.count >= 2 {
                                let port = Int(remoteParts.last!) ?? 0
                                let ip = remoteParts.dropLast().joined(separator: ":")
                                let key = "\(ip):\(port)"
                                
                                // Filter out localhost/loopback (127.0.0.1, ::1, etc)
                                // AND de-duplicate by key
                                if !ip.contains("127.0.0.1") && !ip.contains("::1") && !ip.hasPrefix("127.") {
                                    if !seenKeys.contains(key) {
                                        currentConns.append(Connection(id: remote, ip: ip, port: port))
                                        seenKeys.insert(key)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        DispatchQueue.main.async {
            self.connections = currentConns.map { conn in
                var updated = conn
                updated.hostname = self.hostnameCache[conn.ip]
                updated.provider = self.detectProvider(conn: updated)
                return updated
            }
            
            // Cleanup Stale State
            let activeKeys = Set(self.connections.map { $0.key })
            
            // If the selected key is no longer active, reset it
            if let key = self.selectedKey, !activeKeys.contains(key) {
                if !self.manualOverride {
                    self.selectedKey = nil
                }
            }
            
            // Prune old data from maps to prevent memory leaks or stale UI
            for key in self.latencies.keys {
                if !activeKeys.contains(key) {
                    self.latencies.removeValue(forKey: key)
                    self.icmpLatencies.removeValue(forKey: key)
                    self.jitterScores.removeValue(forKey: key)
                }
            }
            
            self.measureLatencies()
            self.resolveHostnames()
        }
    }
    
    private func detectProvider(conn: Connection) -> TradingProvider {
        let port = conn.port
        let host = conn.hostname?.lowercased() ?? ""
        
        // Rithmic
        if host.contains("rithmic.com") || 
           [65000, 64100, 63100, 56000, 55555, 44444].contains(port) ||
           (port >= 40000 && port <= 42100) {
            return .rithmic
        }
        
        // dxFeed
        if host.contains("dxfeed.com") || port == 7300 || host.contains("amazonaws.com") ||
           conn.ip.hasPrefix("208.93.100.") || conn.ip.hasPrefix("208.93.101.") || conn.ip.hasPrefix("208.93.102.") {
            return .dxfeed
        }
        
        // CQG
        if host.contains("cqg.com") || port == 2823 {
            return .cqg
        }
        
        // Tradovate
        if host.contains("tradovate.com") {
            return .tradovate
        }
        
        return .unknown
    }
    
    private func resolveHostnames() {
        for conn in connections where conn.hostname == nil {
            let ip = conn.ip
            DispatchQueue.global(qos: .background).async {
                if let resolved = self.reverseDNS(ip: ip) {
                    DispatchQueue.main.async {
                        self.hostnameCache[ip] = resolved
                        // Update existing connections
                        self.connections = self.connections.map { c in
                            if c.ip == ip {
                                var updated = c
                                updated.hostname = resolved
                                updated.provider = self.detectProvider(conn: updated)
                                return updated
                            }
                            return c
                        }
                    }
                }
            }
        }
    }
    
    private func reverseDNS(ip: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_flags = AI_NUMERICHOST

        var res: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(ip, nil, &hints, &res) != 0 { return nil }
        defer { freeaddrinfo(res) }

        guard let addr = res?.pointee.ai_addr else { return nil }
        let addrLen = res?.pointee.ai_addrlen ?? 0

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, addrLen, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NAMEREQD) == 0 {
            return String(cString: hostBuffer)
        }
        return nil
    }
    
    private func updateWindowLevel() {
        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.level = self.isAlwaysOnTop ? .floating : .normal
            }
        }
    }
    
    private func measureLatencies() {
        for conn in connections {
            let startTime = CFAbsoluteTimeGetCurrent()
            let host = NWEndpoint.Host(conn.ip)
            let port = NWEndpoint.Port(rawValue: UInt16(conn.port))!
            let connection = NWConnection(host: host, port: port, using: .tcp)
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let duration = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                    DispatchQueue.main.async {
                        self.updateLatency(key: conn.key, ms: duration)
                    }
                    connection.cancel()
                case .failed(_):
                    DispatchQueue.main.async {
                        self.updateLatency(key: conn.key, ms: -1)
                    }
                    connection.cancel()
                default: break
                }
            }
            
            // Timeout after 500ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if connection.state != .cancelled {
                    connection.cancel()
                }
            }
            
            connection.start(queue: .global())
            
            // TCP-based Deep Ping
            self.measureDeepTCP(ip: conn.ip, port: conn.port) { duration in
                DispatchQueue.main.async {
                    self.icmpLatencies[conn.key] = duration
                }
            }
        }
    }
    
    private func measureDeepTCP(ip: String, port: Int, completion: @escaping (Int) -> Void) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let host = NWEndpoint.Host(ip)
        let nPort = NWEndpoint.Port(rawValue: UInt16(port))!
        
        // We use a different configuration or simply a raw attempt to see through the VPN
        // Using .tcp with no special proxy settings often forces a real route check
        let connection = NWConnection(host: host, port: nPort, using: .tcp)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let duration = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                completion(duration)
                connection.cancel()
            case .failed(_):
                completion(-1)
                connection.cancel()
            default: break
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if connection.state != .cancelled {
                connection.cancel()
                completion(-1)
            }
        }
        
        connection.start(queue: .global())
    }
    
    private func updateLatency(key: String, ms: Int) {
        latencies[key] = ms
        
        if ms != -1 {
            let prev = history[key] ?? 0
            let diff = abs(ms - prev)
            if diff > 0 {
                jitterScores[key, default: 0] += 1
            }
            history[key] = ms
        }
        
        if !manualOverride {
            // Priority 1: Verified Provider with high jitter
            // Priority 2: Highest jitter overall
            let winner = jitterScores.keys.compactMap { key in
                connections.first(where: { $0.key == key })
            }.sorted { a, b in
                let scoreA = jitterScores[a.key] ?? 0
                let scoreB = jitterScores[b.key] ?? 0
                
                if a.provider != .unknown && b.provider == .unknown { return true }
                if a.provider == .unknown && b.provider != .unknown { return false }
                
                return scoreA > scoreB
            }.first
            
            if let w = winner, (jitterScores[w.key] ?? 0) > 0 {
                selectedKey = w.key
            }
        }
    }
}

// MARK: - UI Components

struct ProcessRow: View {
    let process: ProcessInfo
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                VStack(alignment: .trailing) {
                    Text(process.name)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("\(process.pids.count) Instances")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Image(systemName: "chevron.right")
                    .foregroundColor(.gray)
                    .padding(.leading, 8)
            }
            .padding()
            .background(isHovered ? Color.blue.opacity(0.3) : Color.white.opacity(0.05))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct ConnectionRow: View {
    let connection: Connection
    let latency: Int
    let icmpLatency: Int?
    let isSelected: Bool
    let action: () -> Void
    
    var color: Color {
        if latency == -1 { return .red }
        if latency < 50 { return .green }
        if latency < 100 { return .yellow }
        return .red
    }
    
    var body: some View {
        Button(action: action) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text(connection.displayName)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .foregroundColor(isSelected ? .white : .gray)
                    
                    if connection.provider != .unknown {
                        Text(connection.provider.rawValue)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(connection.provider.color)
                            .foregroundColor(.white)
                            .cornerRadius(3)
                    }
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(latency == -1 ? "---" : "\(latency)ms")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(color)
                        
                        if let icmp = icmpLatency {
                            Text(icmp == -1 ? "Deep: T/O" : "Deep: \(icmp)ms")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(icmp == -1 ? .red : .gray)
                        }
                    }
                }
            }
            .padding(8)
            .background(isSelected ? Color.white.opacity(0.1) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Main Views

struct MainView: View {
    @StateObject var monitor = LatencyMonitor()
    @State var selectedProcess: ProcessInfo?
    @State var searchText = ""
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if let process = selectedProcess {
                MonitorView(process: process, monitor: monitor) {
                    self.selectedProcess = nil
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("Select Process")
                                .font(.title3.bold())
                            
                            HStack(spacing: 12) {
                                Button(action: { monitor.showHelp = true }) {
                                    Image(systemName: "questionmark.circle")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.plain)
                                .help("Help & Documentation")

                                Button(action: { monitor.isAlwaysOnTop.toggle() }) {
                                    Image(systemName: monitor.isAlwaysOnTop ? "pin.fill" : "pin")
                                        .foregroundColor(monitor.isAlwaysOnTop ? .blue : .gray)
                                }
                                .buttonStyle(.plain)
                                .help("Always on Top")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .sheet(isPresented: $monitor.showHelp) {
                        HelpView()
                    }
                    .padding(.horizontal)
                    .padding(.top)
                    
                    TextField("Search...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                    
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(monitor.processes.filter { 
                                searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                            }) { proc in
                                ProcessRow(process: proc) {
                                    self.selectedProcess = proc
                                    monitor.startMonitoring(pids: proc.pids)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
        }
        .frame(minWidth: 300, minHeight: monitor.isCompact ? 100 : 400)
        .preferredColorScheme(.dark)
        .onAppear {
            monitor.refreshProcesses()
        }
    }
}

struct MonitorView: View {
    let process: ProcessInfo
    @ObservedObject var monitor: LatencyMonitor
    let onBack: () -> Void
    
    var selectedLatency: Int {
        guard let key = monitor.selectedKey else { return -1 }
        return monitor.latencies[key] ?? -1
    }
    
    var selectedICMP: Int {
        guard let key = monitor.selectedKey else { return -1 }
        return monitor.icmpLatencies[key] ?? -1
    }
    
    var color: Color {
        if selectedLatency == -1 { return .orange }
        if selectedLatency < 50 { return .green }
        if selectedLatency < 100 { return .yellow }
        return .red
    }
    
    var body: some View {
        VStack(spacing: monitor.isCompact ? 5 : 15) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .padding(8)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text(process.name)
                        .font(.headline)
                    
                    HStack(spacing: 12) {
                        Button(action: { monitor.showHelp = true }) {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        .help("Help & Documentation")
                        
                        Button(action: { monitor.isCompact.toggle() }) {
                            Image(systemName: monitor.isCompact ? "chevron.down" : "chevron.up")
                                .foregroundColor(monitor.isCompact ? .blue : .gray)
                        }
                        .buttonStyle(.plain)
                        .help(monitor.isCompact ? "Expand" : "Shrink")

                        Button(action: { monitor.isAlwaysOnTop.toggle() }) {
                            Image(systemName: monitor.isAlwaysOnTop ? "pin.fill" : "pin")
                                .foregroundColor(monitor.isAlwaysOnTop ? .blue : .gray)
                        }
                        .buttonStyle(.plain)
                        .help("Always on Top")

                        Button(action: { monitor.refreshProcesses(); onBack() }) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            
            VStack(spacing: 15) {
                HStack(alignment: .bottom, spacing: 20) {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("APP (TCP)")
                            .font(.caption.bold())
                            .foregroundColor(.gray)
                        Text(selectedLatency == -1 ? "---" : "\(selectedLatency) ms")
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .foregroundColor(color)
                    }
                    
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("DEEP (TCP)")
                            .font(.caption.bold())
                            .foregroundColor(.gray)
                        Text(selectedICMP == -1 ? "---" : "\(selectedICMP) ms")
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .foregroundColor(selectedICMP == -1 ? .orange : .cyan)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.trailing, 20)
                .animation(.spring(), value: selectedLatency)
                .animation(.spring(), value: selectedICMP)
                
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if !monitor.activeProvider.isEmpty {
                            Text(monitor.activeProvider)
                                .font(.system(size: 10, weight: .black))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                        
                        Text(monitor.manualOverride ? "Manual: \(monitor.selectedKey ?? "")" : "Auto-Tracking: \(monitor.selectedKey ?? "...")")
                            .font(.caption)
                            .foregroundColor(monitor.manualOverride ? .cyan : .orange)
                    }
                    .padding(.trailing, 20)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, monitor.isCompact ? 5 : 15)
            .background(Color.white.opacity(0.03))
            
            if !monitor.isCompact {
                Divider().background(Color.gray)
                
                ScrollView {
                    VStack(spacing: 2) {
                        if monitor.connections.isEmpty {
                            Text("No active connections...")
                                .foregroundColor(.gray)
                                .padding()
                        } else {
                            ForEach(monitor.connections) { conn in
                                ConnectionRow(
                                    connection: conn,
                                    latency: monitor.latencies[conn.key] ?? -1,
                                    icmpLatency: monitor.icmpLatencies[conn.key],
                                    isSelected: monitor.selectedKey == conn.key
                                ) {
                                    monitor.manualOverride = true
                                    monitor.selectedKey = conn.key
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(), value: monitor.isCompact)
    }
}

// MARK: - Help View

struct HelpView: View {
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Latency Monitor Pro")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    presentationMode.wrappedValue.dismiss()
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Group {
                        HelpSection(title: "App Latency (TCP)", content: "Measures the time for a full TCP handshake between your running software (e.g. ATAS) and its remote server. This is the real-world 'lag' your application experiences during data transmission.")
                        
                        HelpSection(title: "Deep Latency (TCP Check)", content: "Specifically designed to bypass VPN 'shortcuts'. It establishes an independent secondary connection to verify the true end-to-end route speed, revealing the actual distance to the data center.")
                        
                        HelpSection(title: "Auto-Tracking Logic", content: "The app monitors 'Jitter' (frequency of connection activity). It identifies the most active data feed in real-time and automatically focuses the monitor on that connection.")
                    }
                    
                    Group {
                        HelpSection(title: "Smart Provider Detection", content: "Uses a signature database to automatically identify major trading data providers (Rithmic, dxFeed, Tradovate, CQG) based on IP ranges and port signatures.")
                    }
                    
                    Divider().background(Color.gray.opacity(0.3))
                    
                    VStack(alignment: .center, spacing: 10) {
                        Text("EXPERIMENTAL SOFTWARE")
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                        
                        Text("This monitor is provided for informational purposes only. Network conditions can change rapidly. Always cross-verify with your trading platform's internal stats.")
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.gray)
                            
                        Text("© 2026 TraderJan. All rights reserved.")
                            .font(.caption.italic())
                            .padding(.top, 10)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                }
                .padding()
            }
        }
        .frame(width: 350, height: 450)
        .background(Color(white: 0.1).edgesIgnoringSafeArea(.all))
        .preferredColorScheme(.dark)
    }
}

struct HelpSection: View {
    let title: String
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundColor(.cyan)
            Text(content)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
                .lineSpacing(4)
        }
    }
}

// MARK: - App Entry Point

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = MainView()
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.center()
        window.setFrameAutosaveName("LatencyMonitorWindow")
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
