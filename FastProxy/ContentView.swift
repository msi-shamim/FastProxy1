//
//  ContentView.swift
//  FastProxy
//
//  Created by MSI Shamim on 20/11/24.
//


import SwiftUI

struct ContentView: View {
    @StateObject private var vpnManager = VPNManager.shared
    @State private var vpnURL = ""
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Status Card
                VStack {
                    Image(systemName: vpnManager.isConnected ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 50))
                        .foregroundColor(vpnManager.isConnected ? .green : .red)
                    
                    Text(vpnManager.connectionStatus)
                        .font(.headline)
                        .padding(.top, 5)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.systemGray6))
                .cornerRadius(15)
                .padding(.horizontal)
                
                // VPN URL Input
                TextField("Enter VPN URL", text: $vpnURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                
                // Connect/Disconnect Button
                Button(action: {
                    Task {
                        do {
                            if vpnManager.isConnected {
                                try await vpnManager.disconnect()
                            } else {
                                try await vpnManager.configureAndConnect(with: vpnURL)
                            }
                        } catch {
                            alertMessage = error.localizedDescription
                            showingAlert = true
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: vpnManager.isConnected ? "power" : "power")
                        Text(vpnManager.isConnected ? "Disconnect" : "Connect")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(vpnManager.isConnected ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .navigationTitle("Simple VPN")
            .alert("Error", isPresented: $showingAlert) {
                Button("OK") {}
            } message: {
                Text(alertMessage)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}