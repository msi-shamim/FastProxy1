//
//  VPNError.swift
//  FastProxy
//
//  Created by MSI Shamim on 21/11/24.
//


import Foundation
import NetworkExtension
import Network

enum VPNError: Error {
    case invalidConfiguration
    case connectionFailed(String)
    case tunnelSetupFailed
    case proxySetupFailed
    case invalidCredentials
    case systemError(Error)
}

enum ProxyProtocol: String {
    case http
    case https
    case socks5
    
    var defaultPort: Int {
        switch self {
        case .http: return 80
        case .https: return 443
        case .socks5: return 1080
        }
    }
    
    var tunnelProtocol: NEVPNProtocol.Type {
        switch self {
        case .http, .https:
            return NEVPNProtocolIPSec.self
        case .socks5:
            return NEVPNProtocolIKEv2.self
        }
    }
}

@MainActor
final class VPNManager: NSObject, ObservableObject {
    // MARK: - Properties
    static let shared = VPNManager()
    private let manager = NEVPNManager.shared()
    
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var isConnecting = false
    
    
    @Published private(set) var isConnected = false
    @Published private(set) var connectionStatus = "Disconnected"
    @Published private(set) var currentDomain = "-"
    @Published private(set) var currentIP = "-"
    @Published private(set) var currentPort = "-"
    @Published private(set) var currentProtocol = "-"
    @Published private(set) var currentUsername = "-"
    
    // MARK: - Initialization
    private override init() {
        super.init()
        setupObserver()
    }
    
    // MARK: - Status Observer
    private func setupObserver() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let connection = notification.object as? NEVPNConnection else { return }
            
            Task { @MainActor in
                self.status = connection.status
                
                // Update connection status and isConnected
                switch connection.status {
                case .connected:
                    self.connectionStatus = "Connected"
                    self.isConnected = true
                case .connecting:
                    self.connectionStatus = "Connecting..."
                    self.isConnected = false
                case .disconnecting:
                    self.connectionStatus = "Disconnecting..."
                    self.isConnected = false
                case .disconnected:
                    self.connectionStatus = "Disconnected"
                    self.isConnected = false
                    // Reset current connection info
                    self.currentDomain = "-"
                    self.currentIP = "-"
                    self.currentPort = "-"
                    self.currentProtocol = "-"
                    self.currentUsername = "-"
                default:
                    self.connectionStatus = "Invalid"
                    self.isConnected = false
                }
                
                if connection.status != .connecting {
                    self.isConnecting = false
                }
            }
        }
    }
    
    // MARK: - Public Methods
    
    func configureAndConnect(with urlString: String) async throws {
        let config = try parseVPNURL(urlString)
        
        // Resolve DNS
        let resolvedIP = try await resolveDNS(for: config.host)
        
        // Update the UI properties
        currentDomain = config.host
        currentIP = resolvedIP
        currentPort = String(config.port)
        currentProtocol = config.protocol.rawValue.uppercased()
        currentUsername = config.username
        
        // Connect using the parsed configuration
        try await connect(
            proxyProtocol: config.protocol,
            host: resolvedIP,
            port: config.port,
            username: config.username,
            password: config.password
        )
    }
    
    
    func connect(
        proxyProtocol: ProxyProtocol,
        host: String,
        port: Int? = nil,
        username: String,
        password: String
    ) async throws {
        guard !username.isEmpty, !password.isEmpty else {
            throw VPNError.invalidCredentials
        }
        
        isConnecting = true
        
        do {
            // Store credentials securely
            try await storeCredentials(username: username, password: password)
            
            // Configure and establish VPN connection
            try await configureVPN(
                proxyProtocol: proxyProtocol,
                host: host,
                port: port ?? proxyProtocol.defaultPort,
                username: username
            )
        } catch {
            isConnecting = false
            throw error
        }
    }
    
    func disconnect() async throws {
        try await manager.loadFromPreferences()
        manager.connection.stopVPNTunnel()
        isConnecting = false
        isConnected = false
        connectionStatus = "Disconnected"
        
        // Reset connection info
        currentDomain = "-"
        currentIP = "-"
        currentPort = "-"
        currentProtocol = "-"
        currentUsername = "-"
    }
    
    // MARK: - Private Methods
    
    private func parseVPNURL(_ urlString: String) throws -> (protocol: ProxyProtocol, host: String, port: Int, username: String, password: String) {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              let username = components.user,
              let password = components.password,
              let port = components.port else {
            throw VPNError.invalidConfiguration
        }
        
        // Determine protocol
        let proxyProtocol: ProxyProtocol
        switch components.scheme?.lowercased() {
        case "http":
            proxyProtocol = .http
        case "https":
            proxyProtocol = .https
        case "socks5":
            proxyProtocol = .socks5
        default:
            proxyProtocol = .https // Default to HTTPS if not specified
        }
        
        return (proxyProtocol, host, port, username, password)
    }
    
    
    
    private func storeCredentials(username: String, password: String) async throws {
        // Store VPN Password
        let passwordQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "VPNPassword_\(username)",
            kSecValueData as String: password.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecReturnPersistentRef as String: true
        ]
        
        // Store Shared Secret (PSK)
        let pskQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "VPNPSK_\(username)",
            kSecValueData as String: password.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecReturnPersistentRef as String: true
        ]
        
        SecItemDelete(passwordQuery as CFDictionary)
        SecItemDelete(pskQuery as CFDictionary)
        
        var passwordRef: AnyObject?
        var pskRef: AnyObject?
        
        let passwordStatus = SecItemAdd(passwordQuery as CFDictionary, &passwordRef)
        let pskStatus = SecItemAdd(pskQuery as CFDictionary, &pskRef)
        
        guard passwordStatus == errSecSuccess, pskStatus == errSecSuccess else {
            throw VPNError.systemError(NSError(domain: "Keychain", code: Int(passwordStatus)))
        }
    }

    private func retrieveCredentials(for username: String) throws -> (passwordRef: Data, pskRef: Data) {
        let passwordQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "VPNPassword_\(username)",
            kSecReturnPersistentRef as String: true
        ]
        
        let pskQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "VPNPSK_\(username)",
            kSecReturnPersistentRef as String: true
        ]
        
        var passwordRef: AnyObject?
        var pskRef: AnyObject?
        
        let passwordStatus = SecItemCopyMatching(passwordQuery as CFDictionary, &passwordRef)
        let pskStatus = SecItemCopyMatching(pskQuery as CFDictionary, &pskRef)
        
        guard passwordStatus == errSecSuccess,
              pskStatus == errSecSuccess,
              let passwordData = passwordRef as? Data,
              let pskData = pskRef as? Data else {
            throw VPNError.invalidCredentials
        }
        
        return (passwordData, pskData)
    }
    
    
    private func resolveDNS(for host: String) async throws -> String {
        let host = CFHostCreateWithName(kCFAllocatorDefault, host as CFString).takeRetainedValue()
        CFHostStartInfoResolution(host, .addresses, nil)
        
        var success: DarwinBoolean = false
        guard let addresses = CFHostGetAddressing(host, &success)?.takeUnretainedValue() as NSArray? else {
            throw VPNError.connectionFailed("DNS resolution failed")
        }
        
        for case let addr as NSData in addresses {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let data = addr as Data
            
            if data.withUnsafeBytes({ bytes -> Bool in
                guard let baseAddress = bytes.baseAddress else { return false }
                return getnameinfo(baseAddress.assumingMemoryBound(to: sockaddr.self),
                                 socklen_t(data.count),
                                 &hostname,
                                 socklen_t(hostname.count),
                                 nil,
                                 0,
                                 NI_NUMERICHOST) == 0
            }) {
                if let ipAddress = String(cString: hostname, encoding: .utf8) {
                    return ipAddress
                }
            }
        }
        
        throw VPNError.connectionFailed("No valid IP address found")
    }
    
    private func configureVPN(
        proxyProtocol: ProxyProtocol,
        host: String,
        port: Int,
        username: String
    ) async throws {
        try await manager.loadFromPreferences()
        
        // Create protocol configuration
        let protocolConfiguration: NEVPNProtocol
        
        switch proxyProtocol.tunnelProtocol {
        case is NEVPNProtocolIKEv2.Type:
            protocolConfiguration = configureIKEv2(host: host, port: port, username: username)
        case is NEVPNProtocolIPSec.Type:
            protocolConfiguration = configureIPSec(host: host, port: port, username: username)
        default:
            throw VPNError.invalidConfiguration
        }
        
        // Configure proxy settings
        let proxySettings = NEProxySettings()
        proxySettings.autoProxyConfigurationEnabled = false
        
        switch proxyProtocol {
        case .http:
            proxySettings.httpEnabled = true
            proxySettings.httpServer = NEProxyServer(address: host, port: port)
        case .https:
            proxySettings.httpsEnabled = true
            proxySettings.httpsServer = NEProxyServer(address: host, port: port)
        case .socks5:
            proxySettings.httpEnabled = true
            proxySettings.httpsEnabled = true
            proxySettings.httpServer = NEProxyServer(address: host, port: port)
            proxySettings.httpsServer = NEProxyServer(address: host, port: port)
        }
        
        // Configure DNS settings
        let dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        dnsSettings.matchDomains = [""] // Route all DNS queries through VPN
        
        // Apply settings
        manager.protocolConfiguration = protocolConfiguration
        manager.localizedDescription = "VPN Connection"
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        
        // Save configuration
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        
        // Start VPN connection
        try manager.connection.startVPNTunnel()
    }
    
    private func configureIKEv2(host: String, port: Int, username: String) -> NEVPNProtocolIKEv2 {
        let ikev2 = NEVPNProtocolIKEv2()
        
        // Basic settings
        ikev2.serverAddress = host
        ikev2.username = username
        ikev2.remoteIdentifier = host
        ikev2.localIdentifier = "client-\(UUID().uuidString)"
        
        // Security settings with PSK
        ikev2.useExtendedAuthentication = true
        ikev2.authenticationMethod = .sharedSecret
        
        do {
                let credentials = try retrieveCredentials(for: username)
                ikev2.passwordReference = credentials.passwordRef
                ikev2.sharedSecretReference = credentials.pskRef
            } catch {
                print("Failed to retrieve credentials: \(error)")
            }
        
        ikev2.disconnectOnSleep = false
        
        // IKE Security Association
        ikev2.ikeSecurityAssociationParameters.encryptionAlgorithm = .algorithmAES256GCM
        ikev2.ikeSecurityAssociationParameters.integrityAlgorithm = .SHA256
        ikev2.ikeSecurityAssociationParameters.diffieHellmanGroup = .group14
        ikev2.ikeSecurityAssociationParameters.lifetimeMinutes = 1440
        
        // Child Security Association
        ikev2.childSecurityAssociationParameters.encryptionAlgorithm = .algorithmAES256GCM
        ikev2.childSecurityAssociationParameters.diffieHellmanGroup = .group14
        ikev2.childSecurityAssociationParameters.lifetimeMinutes = 1440
        
        return ikev2
    }

    private func configureIPSec(host: String, port: Int, username: String) -> NEVPNProtocolIPSec {
        let ipsec = NEVPNProtocolIPSec()
        
        // Basic settings
        ipsec.serverAddress = host
        ipsec.username = username
        
        // Security settings with PSK
        ipsec.useExtendedAuthentication = true
        ipsec.authenticationMethod = .sharedSecret
        
        do {
                let credentials = try retrieveCredentials(for: username)
                ipsec.passwordReference = credentials.passwordRef
                ipsec.sharedSecretReference = credentials.pskRef
            } catch {
                print("Failed to retrieve credentials: \(error)")
            }
        
        
        ipsec.disconnectOnSleep = false
        
        return ipsec
    }
    
}

// MARK: - Usage Example
extension VPNManager {
    static func example() async {
        do {
            try await VPNManager.shared.connect(
                proxyProtocol: .socks5,
                host: "proxy.example.com",
                port: 1080,
                username: "user",
                password: "password"
            )
        } catch {
            print("VPN Connection Error: \(error)")
        }
    }
}
