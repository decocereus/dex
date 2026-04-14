import Foundation
import Observation
import UIKit

private struct BonjourDiscoverySeed: Hashable {
    let name: String
    let host: String
    let port: UInt16?
    let serviceType: String
}

struct TailscalePeerIdentity: Equatable {
    let ip: String
    let name: String?
}

struct TailscaleAvailability: Equatable, Sendable {
    let appInstalled: Bool
    let likelyActiveTunnel: Bool

    var shouldSurfaceDiscoveryNotice: Bool {
        appInstalled || likelyActiveTunnel
    }

    var logDescription: String {
        "installed=\(appInstalled) likelyActive=\(likelyActiveTunnel)"
    }
}

enum TailscalePeerParseError: Error, Equatable {
    case unsupportedSurface
    case invalidPayload
}

private struct TailscaleInterfaceSnapshot: Sendable {
    struct InterfaceRecord: Sendable {
        let name: String
        let family: String
        let address: String
        let flags: [String]
        let isTailscaleAddress: Bool
    }

    let localWiFiAddress: String?
    let localWiFiInterface: String?
    let activeTunnelInterfaces: [String]
    let tailscaleInterfaces: [String]
    let records: [InterfaceRecord]

    var hasLikelyActiveTailscaleTunnel: Bool {
        !activeTunnelInterfaces.isEmpty && !tailscaleInterfaces.isEmpty
    }

    var logDescription: String {
        let wifiSummary: String
        if let localWiFiInterface, let localWiFiAddress {
            wifiSummary = "\(localWiFiInterface)=\(localWiFiAddress)"
        } else {
            wifiSummary = "none"
        }

        let tunnelSummary = activeTunnelInterfaces.isEmpty
            ? "none"
            : activeTunnelInterfaces.joined(separator: ",")
        let tailscaleSummary = tailscaleInterfaces.isEmpty
            ? "none"
            : tailscaleInterfaces.joined(separator: ",")
        let recordsSummary = records.isEmpty
            ? "none"
            : records.map { record in
                let flags = record.flags.joined(separator: "+")
                return "\(record.name):\(record.family):\(record.address):\(flags)\(record.isTailscaleAddress ? ":tailscale" : "")"
            }.joined(separator: " | ")

        return "wifi=\(wifiSummary) likelyActive=\(hasLikelyActiveTailscaleTunnel) utun=\(tunnelSummary) tailscale=\(tailscaleSummary) records=\(recordsSummary)"
    }
}

private actor TailscaleDiscoveryDiagnostics {
    private(set) var notice: String?

    func markSuccess() {
        notice = nil
    }

    func record(_ notice: String) {
        if self.notice == nil {
            self.notice = notice
        }
    }
}

@MainActor
@Observable
final class NetworkDiscovery {
    var servers: [DiscoveredServer] = []
    var isScanning = false
    var isInitialLoad = false
    var tailscaleDiscoveryNotice: String?
    /// Overall scan progress from 0.0 to 1.0.
    var scanProgress: Float = 0
    /// Human-readable label for the current scan phase.
    var scanProgressLabel: String?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var initialLoadTask: Task<Void, Never>?
    @ObservationIgnored private var activeScanID = UUID()
    @ObservationIgnored private var networkServerLastSeen: [String: Date] = [:]

    private let cacheKey = "litter.discovery.networkServers.v1"
    private let cacheRetention: TimeInterval = 7 * 24 * 60 * 60

    private struct CachedNetworkServer: Codable {
        let id: String
        let name: String
        let hostname: String
        let port: UInt16?
        let codexPorts: [UInt16]?
        let sshPort: UInt16?
        let source: ServerSource
        let hasCodexServer: Bool
        let wakeMAC: String?
        let preferredConnectionMode: PreferredConnectionMode?
        let preferredCodexPort: UInt16?
        let lastSeenAt: TimeInterval
        let os: String?
        let sshBanner: String?
    }

    func startScanning() {
        stopScanning()
        let scanID = UUID()
        activeScanID = scanID
        tailscaleDiscoveryNotice = nil

        let cachedNetworkServers = loadCachedNetworkServers()
        let savedNetworkServers = loadSavedNetworkServers()
        let retainedNetworkServers = servers.filter { $0.source != .local }
        servers = reconcileNetworkServers(cachedNetworkServers + savedNetworkServers + retainedNetworkServers)
        isScanning = true
        isInitialLoad = true
        scanProgress = 0
        scanProgressLabel = "Discovering services…"
        servers.append(DiscoveredServer(
            id: "local",
            name: UIDevice.current.name,
            hostname: "127.0.0.1",
            port: nil,
            source: .local,
            hasCodexServer: true
        ))

        initialLoadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run { [weak self] in
                guard let self, self.activeScanID == scanID else { return }
                self.isInitialLoad = false
            }
        }

        scanTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.discoverNetworkServersInBackground(scanID: scanID)
        }
    }

    func stopScanning() {
        scanTask?.cancel()
        initialLoadTask?.cancel()
        scanTask = nil
        initialLoadTask = nil
        isScanning = false
        isInitialLoad = false
    }

    // MARK: - Discovery

    private nonisolated func discoverNetworkServersInBackground(scanID: UUID) async {
        defer {
            Task { @MainActor [weak self] in
                guard let self, self.activeScanID == scanID else { return }
                self.isScanning = false
                self.isInitialLoad = false
            }
        }
        guard !Task.isCancelled else { return }
        let isCurrent = await MainActor.run { [weak self] in
            guard let self else { return false }
            return self.activeScanID == scanID
        }
        guard isCurrent else { return }

        let tailscaleDiagnostics = TailscaleDiscoveryDiagnostics()
        let tailscaleAppInstalled = await MainActor.run { Self.isTailscaleAppInstalled() }
        async let tailscaleNoticeProbe: Void = Self.probeTailscaleDiscoveryNotice(
            timeout: 1.0,
            appInstalled: tailscaleAppInstalled,
            diagnostics: tailscaleDiagnostics
        )

        let seeds = await Self.discoverBonjourSeeds(timeout: 5.0)
        let localIPv4 = Self.localIPv4Address()?.0
        guard !Task.isCancelled else { return }

        await MainActor.run { [weak self] in
            guard let self, self.activeScanID == scanID else { return }
            self.scanProgress = 0.02
            self.scanProgressLabel = "Resolving services…"
        }

        let metadataSources = await MainActor.run { [weak self] in
            guard let self else { return [DiscoveredServer]() }
            return self.loadSavedNetworkServers() + self.servers.filter { $0.source != .local }
        }
        let discovered = Self.discoveredServers(
            from: seeds,
            localIpv4: localIPv4,
            metadataSources: metadataSources
        )
        guard !Task.isCancelled else { return }
        await MainActor.run { [weak self] in
            guard let self, self.activeScanID == scanID else { return }
            self.isInitialLoad = false
            self.applyDiscoveredServers(discovered)
            self.scanProgress = 1
            self.scanProgressLabel = discovered.isEmpty ? "No servers found" : "Found \(discovered.count) server\(discovered.count == 1 ? "" : "s")"
        }

        _ = await tailscaleNoticeProbe
        let tailscaleNotice = await tailscaleDiagnostics.notice
        await MainActor.run { [weak self] in
            guard let self, self.activeScanID == scanID else { return }
            self.tailscaleDiscoveryNotice = tailscaleNotice
        }
    }

    private func applyDiscoveredServers(_ discovered: [DiscoveredServer]) {
        let now = Date()
        for server in discovered {
            networkServerLastSeen[server.id] = now
        }

        let local = servers.filter { $0.source == .local }
        let metadataSources = loadSavedNetworkServers() + servers.filter { $0.source != .local }
        servers = local + reconcileNetworkServers(discovered + metadataSources)
        saveCachedNetworkServers()
    }

    private func reconcileNetworkServers(_ candidates: [DiscoveredServer]) -> [DiscoveredServer] {
        var mergedByKey: [String: DiscoveredServer] = [:]

        for server in candidates where server.source != .local {
            let key = server.deduplicationKey
            if let existing = mergedByKey[key] {
                mergedByKey[key] = Self.mergeServers(existing: existing, incoming: server)
            } else {
                mergedByKey[key] = server
            }
        }

        return mergedByKey.values.sorted { lhs, rhs in
            let lhsName = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsName = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameOrder = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.hostname.localizedCaseInsensitiveCompare(rhs.hostname) == .orderedAscending
        }
    }

    private func loadSavedNetworkServers() -> [DiscoveredServer] {
        SavedServerStore.load()
            .map { $0.toDiscoveredServer() }
            .filter { $0.source != .local }
    }

    nonisolated private static func normalizedServerKey(for host: String) -> String {
        var normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")

        if !normalized.contains(":"), let scopeIndex = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<scopeIndex])
        }

        return normalized.lowercased()
    }

    nonisolated private static func discoveredServers(
        from seeds: [BonjourDiscoverySeed],
        localIpv4: String?,
        metadataSources: [DiscoveredServer]
    ) -> [DiscoveredServer] {
        var existingByKey: [String: DiscoveredServer] = [:]
        for server in metadataSources {
            existingByKey[server.deduplicationKey] = server
        }

        return seeds.compactMap { seed in
            let host = seed.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, host != "127.0.0.1", host != localIpv4 else { return nil }
            let key = normalizedServerKey(for: host)
            let existing = existingByKey[key]
            let port = seed.port
            let isCodex = seed.serviceType == "_codex._tcp."
            let codexPorts = isCodex ? port.map { [$0] } ?? [] : (existing?.codexPorts ?? [])
            let sshPort = seed.serviceType == "_ssh._tcp." ? port : (existing?.sshPort)

            return DiscoveredServer(
                id: existing?.id ?? "network-\(host)",
                name: seed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (existing?.name ?? host) : seed.name,
                hostname: host,
                port: isCodex ? port : existing?.port,
                codexPorts: codexPorts,
                sshPort: sshPort,
                source: existing?.source == .tailscale ? .tailscale : .bonjour,
                hasCodexServer: isCodex || existing?.hasCodexServer == true,
                wakeMAC: existing?.wakeMAC,
                sshPortForwardingEnabled: existing?.sshPortForwardingEnabled ?? false,
                websocketURL: existing?.websocketURL,
                preferredConnectionMode: existing?.preferredConnectionMode,
                preferredCodexPort: existing?.preferredCodexPort,
                os: existing?.os,
                sshBanner: existing?.sshBanner,
                metadata: existing?.metadata ?? [:]
            )
        }
    }

    nonisolated private static func mergeServers(existing: DiscoveredServer, incoming: DiscoveredServer) -> DiscoveredServer {
        let mergedCodexPorts = Array(Set(existing.codexPorts + incoming.codexPorts)).sorted()
        let resolvedName: String = {
            let existingName = existing.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let incomingName = incoming.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if existingName.isEmpty || existingName == existing.hostname {
                return incomingName.isEmpty ? existing.name : incoming.name
            }
            return existing.name
        }()

        return DiscoveredServer(
            id: existing.id,
            name: resolvedName,
            hostname: existing.hostname,
            port: incoming.port ?? existing.port ?? mergedCodexPorts.first,
            codexPorts: mergedCodexPorts,
            sshPort: incoming.sshPort ?? existing.sshPort,
            source: existing.source == .tailscale || incoming.source == .tailscale ? .tailscale : existing.source,
            hasCodexServer: existing.hasCodexServer || incoming.hasCodexServer || !mergedCodexPorts.isEmpty,
            wakeMAC: existing.wakeMAC ?? incoming.wakeMAC,
            sshPortForwardingEnabled: existing.sshPortForwardingEnabled || incoming.sshPortForwardingEnabled,
            websocketURL: existing.websocketURL ?? incoming.websocketURL,
            preferredConnectionMode: existing.preferredConnectionMode ?? incoming.preferredConnectionMode,
            preferredCodexPort: existing.preferredCodexPort ?? incoming.preferredCodexPort,
            os: existing.os ?? incoming.os,
            sshBanner: existing.sshBanner ?? incoming.sshBanner,
            metadata: existing.metadata.merging(incoming.metadata) { current, _ in current }
        )
    }

    private func loadCachedNetworkServers() -> [DiscoveredServer] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [] }
        let decoder = JSONDecoder()
        guard let cached = try? decoder.decode([CachedNetworkServer].self, from: data) else {
            UserDefaults.standard.removeObject(forKey: cacheKey)
            return []
        }

        let now = Date()
        let maxAge = cacheRetention
        var pruned: [CachedNetworkServer] = []
        var loaded: [DiscoveredServer] = []
        networkServerLastSeen.removeAll(keepingCapacity: true)

        for entry in cached {
            guard now.timeIntervalSince1970 - entry.lastSeenAt <= maxAge else { continue }
            guard entry.source != .local else { continue }
            let server = DiscoveredServer(
                id: entry.id,
                name: entry.name,
                hostname: entry.hostname,
                port: entry.port,
                codexPorts: entry.codexPorts ?? (entry.port.map { [ $0 ] } ?? []),
                sshPort: entry.sshPort,
                source: entry.source,
                hasCodexServer: entry.hasCodexServer,
                wakeMAC: entry.wakeMAC,
                preferredConnectionMode: entry.preferredConnectionMode,
                preferredCodexPort: entry.preferredCodexPort,
                os: entry.os,
                sshBanner: entry.sshBanner
            )
            loaded.append(server)
            pruned.append(entry)
            networkServerLastSeen[entry.id] = Date(timeIntervalSince1970: entry.lastSeenAt)
        }

        if pruned.count != cached.count {
            persistCachedNetworkServers(pruned)
        }

        return loaded
    }

    private func saveCachedNetworkServers() {
        let now = Date()
        let cached = servers
            .filter { $0.source != .local }
            .map { server in
                let lastSeen = networkServerLastSeen[server.id] ?? now
                return CachedNetworkServer(
                    id: server.id,
                    name: server.name,
                    hostname: server.hostname,
                    port: server.port,
                    codexPorts: server.codexPorts,
                    sshPort: server.sshPort,
                    source: server.source,
                    hasCodexServer: server.hasCodexServer,
                    wakeMAC: server.wakeMAC,
                    preferredConnectionMode: server.preferredConnectionMode,
                    preferredCodexPort: server.preferredCodexPort,
                    lastSeenAt: lastSeen.timeIntervalSince1970,
                    os: server.os,
                    sshBanner: server.sshBanner
                )
            }
        persistCachedNetworkServers(cached)
    }

    private func persistCachedNetworkServers(_ cached: [CachedNetworkServer]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private static func discoverBonjourSeeds(timeout: TimeInterval) async -> [BonjourDiscoverySeed] {
        async let ssh = discoverBonjourSeeds(
            serviceType: "_ssh._tcp.",
            timeout: timeout
        )
        async let codex = discoverBonjourSeeds(
            serviceType: "_codex._tcp.",
            timeout: timeout
        )
        return Array((await ssh) + (await codex))
    }

    private static func discoverBonjourSeeds(
        serviceType: String,
        timeout: TimeInterval
    ) async -> [BonjourDiscoverySeed] {
        let browser = BonjourServiceDiscoverer(serviceType: serviceType)
        return await browser.discover(timeout: timeout)
    }

    nonisolated static func parseTailscalePeerCandidates(
        data: Data,
        response: URLResponse
    ) throws -> [TailscalePeerIdentity] {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw TailscalePeerParseError.invalidPayload
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        let preview = String(decoding: data.prefix(128), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if contentType?.contains("text/html") == true ||
            preview.hasPrefix("<!doctype html") ||
            preview.hasPrefix("<html") {
            throw TailscalePeerParseError.unsupportedSurface
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = json["Peer"] as? [String: Any] else {
            throw TailscalePeerParseError.invalidPayload
        }

        var out: [TailscalePeerIdentity] = []
        out.reserveCapacity(peers.count)
        for peer in peers.values {
            guard let peerDict = peer as? [String: Any] else { continue }
            if let online = peerDict["Online"] as? Bool, !online {
                continue
            }
            let hostName = cleanedHostName(peerDict["HostName"] as? String)
                ?? cleanedHostName(peerDict["DNSName"] as? String)
            let ips = (peerDict["TailscaleIPs"] as? [String]) ?? []
            guard let ipv4 = ips.first(where: { isIPv4Address($0) }) else { continue }
            out.append(TailscalePeerIdentity(ip: ipv4, name: hostName))
        }

        return out
    }

    nonisolated static func tailscaleDiscoveryNotice(
        for error: Error,
        availability: TailscaleAvailability
    ) -> String? {
        guard availability.shouldSurfaceDiscoveryNotice else {
            return nil
        }

        if let urlError = error as? URLError, urlError.code == .timedOut {
            return "Tailscale peer discovery timed out. Add a server manually with its MagicDNS name or Tailscale IP. Saved servers will still appear here."
        }

        if let parseError = error as? TailscalePeerParseError, parseError == .unsupportedSurface {
            return "Tailscale returned its web UI instead of a peer list, so peer discovery is unavailable here. Add a server manually with its MagicDNS name or Tailscale IP. Saved servers will still appear here."
        }

        return "Tailscale peer discovery is unavailable right now. Add a server manually with its MagicDNS name or Tailscale IP. Saved servers will still appear here."
    }

    nonisolated private static func probeTailscaleDiscoveryNotice(
        timeout: TimeInterval,
        appInstalled: Bool,
        diagnostics: TailscaleDiscoveryDiagnostics
    ) async {
        guard let url = URL(string: "http://100.100.100.100/localapi/v0/status") else {
            return
        }

        let interfaceSnapshot = tailscaleInterfaceSnapshot()
        let availability = TailscaleAvailability(
            appInstalled: appInstalled,
            likelyActiveTunnel: interfaceSnapshot.hasLikelyActiveTailscaleTunnel
        )
        NSLog(
            "[tailscale] availability=%@ interface snapshot before request: %@",
            availability.logDescription,
            interfaceSnapshot.logDescription
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 0.25
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                NSLog("[tailscale] response status=%d contentType=%@", http.statusCode, contentType)
            }
            let peers = try parseTailscalePeerCandidates(data: data, response: response)
            await diagnostics.markSuccess()
            NSLog("[tailscale] got %d peers", peers.count)
        } catch {
            let responsePreview = (error as NSError).localizedDescription
            if let notice = Self.tailscaleDiscoveryNotice(for: error, availability: availability) {
                await diagnostics.record(notice)
            } else {
                NSLog("[tailscale] suppressing notice because Tailscale does not look installed or active")
            }
            NSLog("[tailscale] request error: %@", responsePreview)
            NSLog("[tailscale] interface snapshot after error: %@", tailscaleInterfaceSnapshot().logDescription)
        }
    }

    @MainActor
    private static func isTailscaleAppInstalled() -> Bool {
        guard let url = URL(string: "tailscale://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    nonisolated private static func cleanedHostName(_ value: String?) -> String? {
        guard var value, !value.isEmpty else { return nil }
        if value.hasSuffix(".") {
            value.removeLast()
        }
        if value.hasSuffix(".local") {
            value = String(value.dropLast(6))
        }
        return value.isEmpty ? nil : value
    }

    nonisolated fileprivate static func ipv4Address(fromSockaddrData data: Data) -> String? {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            let sockaddrPtr = base.assumingMemoryBound(to: sockaddr.self)
            guard sockaddrPtr.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
            let sinPtr = base.assumingMemoryBound(to: sockaddr_in.self)
            var addr = sinPtr.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: buffer)
        }
    }

    nonisolated private static func isIPv4Address(_ value: String) -> Bool {
        var addr = in_addr()
        return value.withCString { cstr in
            inet_pton(AF_INET, cstr, &addr) == 1
        }
    }

    nonisolated private static func isTailscaleIPv4Address(_ value: String) -> Bool {
        let octets = value.split(separator: ".")
        guard octets.count == 4,
              let first = Int(octets[0]),
              let second = Int(octets[1]) else {
            return false
        }
        return first == 100 && (64...127).contains(second)
    }

    nonisolated private static func isTailscaleIPv6Address(_ value: String) -> Bool {
        value.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    nonisolated private static func interfaceFlagDescriptions(_ flags: Int32) -> [String] {
        var out: [String] = []
        if flags & IFF_UP != 0 { out.append("up") }
        if flags & IFF_RUNNING != 0 { out.append("running") }
        if flags & IFF_LOOPBACK != 0 { out.append("loopback") }
        if flags & IFF_POINTOPOINT != 0 { out.append("ptp") }
        if flags & IFF_MULTICAST != 0 { out.append("multicast") }
        return out
    }

    nonisolated private static func ipAddress(fromSockaddr pointer: UnsafePointer<sockaddr>) -> (family: String, address: String)? {
        let family = pointer.pointee.sa_family
        switch family {
        case sa_family_t(AF_INET):
            let sinPtr = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in.self)
            var addr = sinPtr.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return ("ipv4", String(cString: buffer))
        case sa_family_t(AF_INET6):
            let sin6Ptr = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in6.self)
            var addr = sin6Ptr.pointee.sin6_addr
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return nil
            }
            return ("ipv6", String(cString: buffer))
        default:
            return nil
        }
    }

    nonisolated private static func tailscaleInterfaceSnapshot() -> TailscaleInterfaceSnapshot {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return TailscaleInterfaceSnapshot(
                localWiFiAddress: nil,
                localWiFiInterface: nil,
                activeTunnelInterfaces: [],
                tailscaleInterfaces: [],
                records: []
            )
        }
        defer { freeifaddrs(ifaddr) }

        var localWiFiAddress: String?
        var localWiFiInterface: String?
        var activeTunnelInterfaces = Set<String>()
        var tailscaleInterfaces = Set<String>()
        var records: [TailscaleInterfaceSnapshot.InterfaceRecord] = []

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sockaddr = ptr.pointee.ifa_addr else { continue }
            guard let entry = ipAddress(fromSockaddr: sockaddr) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            let flags = Int32(ptr.pointee.ifa_flags)
            let flagDescriptions = interfaceFlagDescriptions(flags)
            let isUp = flags & IFF_UP != 0
            let isLoopback = flags & IFF_LOOPBACK != 0
            let isTunnel = name.hasPrefix("utun")
            let hasTailscaleAddress = isTailscaleIPv4Address(entry.address) || isTailscaleIPv6Address(entry.address)
            let isLikelyTailscaleInterface = isTunnel && hasTailscaleAddress

            if isUp && isTunnel {
                activeTunnelInterfaces.insert(name)
            }
            if isLikelyTailscaleInterface {
                tailscaleInterfaces.insert(name)
            }
            if isUp && !isLoopback && localWiFiAddress == nil && entry.family == "ipv4" && name.hasPrefix("en") {
                localWiFiInterface = name
                localWiFiAddress = entry.address
            }

            if isTunnel || isLikelyTailscaleInterface || (isUp && !isLoopback) {
                records.append(
                    TailscaleInterfaceSnapshot.InterfaceRecord(
                        name: name,
                        family: entry.family,
                        address: entry.address,
                        flags: flagDescriptions,
                        isTailscaleAddress: isLikelyTailscaleInterface
                    )
                )
            }
        }

        records.sort { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            if lhs.family != rhs.family {
                return lhs.family < rhs.family
            }
            return lhs.address < rhs.address
        }

        return TailscaleInterfaceSnapshot(
            localWiFiAddress: localWiFiAddress,
            localWiFiInterface: localWiFiInterface,
            activeTunnelInterfaces: activeTunnelInterfaces.sorted(),
            tailscaleInterfaces: tailscaleInterfaces.sorted(),
            records: records
        )
    }

    nonisolated private static func localIPv4Address() -> (String, String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = ptr.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                inet_ntop(AF_INET, &sin.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            return (String(cString: buf), name)
        }
        return nil
    }
}

@MainActor
private final class BonjourServiceDiscoverer: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private struct ServiceRecord {
        let name: String
        let port: UInt16?
    }

    private let serviceType: String
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var results: [String: ServiceRecord] = [:]
    private var pendingServices: Set<ObjectIdentifier> = []
    private var continuation: CheckedContinuation<[BonjourDiscoverySeed], Never>?
    private var timeoutTask: Task<Void, Never>?
    private var resolveDrainTask: Task<Void, Never>?
    private var isFinished = false
    private var requestedStop = false

    init(serviceType: String) {
        self.serviceType = serviceType
    }

    func discover(timeout: TimeInterval) async -> [BonjourDiscoverySeed] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            browser.delegate = self
            browser.searchForServices(ofType: serviceType, inDomain: "local.")
            timeoutTask = Task { [weak self] in
                guard let self else { return }
                let nanos = UInt64(max(timeout, 0.25) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                self.stopAndDrain()
            }
        }
    }

    private func stopAndDrain() {
        guard !requestedStop else { return }
        requestedStop = true
        browser.stop()
        if pendingServices.isEmpty {
            finish()
            return
        }
        resolveDrainTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(900))
            self.finish()
        }
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()
        resolveDrainTask?.cancel()
        timeoutTask = nil
        resolveDrainTask = nil
        if !requestedStop {
            browser.stop()
        }
        for service in services {
            service.stop()
            service.delegate = nil
        }
        let discovered = results.map {
            BonjourDiscoverySeed(
                name: $0.value.name,
                host: $0.key,
                port: $0.value.port,
                serviceType: serviceType
            )
        }
        continuation?.resume(returning: discovered)
        continuation = nil
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {}

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish()
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        if requestedStop, pendingServices.isEmpty {
            finish()
        } else if !requestedStop {
            finish()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !isFinished else { return }
        services.append(service)
        pendingServices.insert(ObjectIdentifier(service))
        service.delegate = self
        service.resolve(withTimeout: 2.5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        pendingServices.remove(ObjectIdentifier(sender))
        guard let addresses = sender.addresses else { return }
        let resolvedPort: UInt16? = {
            guard sender.port > 0, sender.port <= Int(UInt16.max) else { return nil }
            return UInt16(sender.port)
        }()
        for address in addresses {
            guard let ip = NetworkDiscovery.ipv4Address(fromSockaddrData: address) else { continue }
            results[ip] = ServiceRecord(name: sender.name, port: resolvedPort)
            break
        }
        if requestedStop, pendingServices.isEmpty {
            finish()
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pendingServices.remove(ObjectIdentifier(sender))
        if requestedStop, pendingServices.isEmpty {
            finish()
        }
    }
}
