//
//  PacketTunnelProvider.swift
//  PacketTunnelProvider
//
//  Created by MSI Shamim on 20/11/24.
//

import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.168.1.1")
        
        // IPv4 settings
        let ipv4Settings = NEIPv4Settings(addresses: ["192.168.1.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        networkSettings.ipv4Settings = ipv4Settings
        
        // DNS settings
        networkSettings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        
        setTunnelNetworkSettings(networkSettings) { error in
            if let error = error {
                completionHandler(error)
                return
            }
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
