//
//  VPNManager.swift
//  FastProxy
//
//  Created by MSI Shamim on 20/11/24.
//


import NetworkExtension
import Foundation

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
    @Published var connectionStatus: String = "Not Connected"
    @Published var isConnected = false
    
    struct VPNConfig {
        let appProtocol: VPNProtocolType
        let username: String
        let password: String
        let domain: String
        let port: Int
        
        enum VPNProtocolType {
            case socks5
            case http
            case https
            
            var tunnelProtocol: NEVPNProtocol.Type {
                switch self {
                case .socks5:
                    return NEVPNProtocolIKEv2.self
                case .http, .https:
                    return NEVPNProtocolIPSec.self
                }
            }
        }
    }
    
    private let vpnManager = NEVPNManager.shared()
    
    func parseVPNURL(_ urlString: String) -> VPNConfig? {
        // Remove protocol:// prefix
        let components = urlString.components(separatedBy: "://")
        guard components.count == 2 else { return nil }
        
        let protocolString = components[0]
        let remainingString = components[1]
        
        // Split credentials and host
        let credentialsAndHost = remainingString.components(separatedBy: "@")
        guard credentialsAndHost.count == 2 else { return nil }
        
        // Get username and password
        let credentials = credentialsAndHost[0].components(separatedBy: ":")
        guard credentials.count == 2 else { return nil }
        
        // Get host and port
        let hostAndPort = credentialsAndHost[1].components(separatedBy: ":")
        guard hostAndPort.count == 2,
              let port = Int(hostAndPort[1]) else { return nil }
        
        // Determine protocol type
        let protocolType: VPNConfig.VPNProtocolType
        switch protocolString.lowercased() {
        case "socks5":
            protocolType = .socks5
        case "http":
            protocolType = .http
        case "https":
            protocolType = .https
        default:
            return nil
        }
        
        return VPNConfig(
            appProtocol: protocolType,
            username: credentials[0],
            password: credentials[1],
            domain: hostAndPort[0],
            port: port
        )
    }
    
    func configureAndConnect(with urlString: String) async throws {
        guard let config = parseVPNURL(urlString) else {
            throw NSError(domain: "VPNError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL format"])
        }
        
        try await configureTunnel(with: config)
        try await connect()
    }
    
    private func configureTunnel(with config: VPNConfig) async throws {
        let manager = NETunnelProviderManager()
        try await manager.loadFromPreferences()
        
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = "com.incrementsinc.FastProxy.PacketTunnelProvider" 
        tunnelProtocol.serverAddress = config.domain
        
        // Store configuration as dictionary
        let configuration: [String: Any] = [
            "username": config.username,
            "password": config.password,
            "protocol": config.appProtocol,
            "port": config.port
        ]
        tunnelProtocol.providerConfiguration = configuration
        
        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = "VPN Connection"
        manager.isEnabled = true
        
        try await manager.saveToPreferences()
        
        // Start monitoring status
        startMonitoringStatus()
    }
    
    private func configureIKEv2(_ config: VPNConfig) -> NEVPNProtocolIKEv2 {
        let proto = NEVPNProtocolIKEv2()
        proto.remoteIdentifier = config.domain
        proto.localIdentifier = "client-\(UUID().uuidString)"
        proto.useExtendedAuthentication = true
        proto.serverAddress = config.domain
        proto.authenticationMethod = .none
        return proto
    }
    
    private func configureIPSec(_ config: VPNConfig) -> NEVPNProtocolIPSec {
        let proto = NEVPNProtocolIPSec()
        proto.useExtendedAuthentication = true
        proto.serverAddress = config.domain
        proto.authenticationMethod = .none
        return proto
    }
    
    private func storePassword(_ password: String) throws -> Data {
        let password = password.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "VPNPassword",
            kSecValueData as String: password,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "Keychain", code: Int(status))
        }
        
        return password
    }
    
    func connect() async throws {
        try await vpnManager.loadFromPreferences()
        try vpnManager.connection.startVPNTunnel()
    }
    
    func disconnect() async throws {
        try await vpnManager.loadFromPreferences()
        vpnManager.connection.stopVPNTunnel()
    }
    
    private func startMonitoringStatus() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let connection = notification.object as? NEVPNConnection {
                DispatchQueue.main.async {
                    self?.updateStatus(connection.status)
                }
            }
        }
    }
    
    private func updateStatus(_ status: NEVPNStatus) {
        switch status {
        case .connected:
            connectionStatus = "Connected"
            isConnected = true
        case .connecting:
            connectionStatus = "Connecting..."
            isConnected = false
        case .disconnecting:
            connectionStatus = "Disconnecting..."
            isConnected = false
        case .disconnected:
            connectionStatus = "Disconnected"
            isConnected = false
        case .invalid:
            connectionStatus = "Invalid Configuration"
            isConnected = false
        case .reasserting:
            connectionStatus = "Reasserting..."
            isConnected = false
        @unknown default:
            connectionStatus = "Unknown"
            isConnected = false
        }
    }
}
