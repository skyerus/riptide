import RiptideCore
import SwiftUI
import UIKit

private enum PairTransport: String, CaseIterable, Identifiable {
    case webSocket = "WebSocket"
    case ssh = "SSH"

    var id: Self { self }
}

struct PairRemoteScreen: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RemoteKind
    @State private var transport: PairTransport
    @State private var name = ""
    @State private var address = ""
    @State private var workspace = ""
    @State private var mainID = ""
    @State private var token = ""
    @State private var sshFingerprint = ""
    @State private var sshIdentity = SSHDeviceIdentity()
    @State private var copiedKey = false
    @State private var failure: String?
    @State private var pairing: Task<Void, Never>?

    init(store: RemoteStore, initialKind: RemoteKind? = nil) {
        self.store = store
        _kind = State(initialValue: initialKind ?? .codex)
        _transport = State(initialValue: initialKind.map { $0 == .codex ? .webSocket : .ssh } ?? .webSocket)
    }

    private var usesSSH: Bool { kind != .codex && transport == .ssh }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    Picker("Backend", selection: $kind) {
                        ForEach(RemoteKind.allCases, id: \.self) { kind in
                            Text(kind.name).tag(kind)
                        }
                    }
                    TextField("Name", text: $name)
                    if kind != .codex {
                        Picker("Connection", selection: $transport) {
                            ForEach(PairTransport.allCases) { option in Text(option.rawValue).tag(option) }
                        }
                        .accessibilityIdentifier("pair-transport")
                    }
                }
                Section {
                    TextField(usesSSH ? "ssh://user@host.example" : "wss://host.example/agent", text: $address)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("pair-address")
                    TextField("Absolute workspace path", text: $workspace)
                    if kind != .codex {
                        TextField("Existing main chat ID", text: $mainID)
                    }
                    if usesSSH {
                        TextField("SSH host fingerprint (SHA256:…)", text: $sshFingerprint)
                            .accessibilityIdentifier("pair-ssh-fingerprint")
                        Button(copiedKey ? "Public key copied" : "Copy SSH public key", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = sshIdentity.publicKey
                            copiedKey = true
                        }
                        .accessibilityIdentifier("pair-ssh-public-key")
                    } else {
                        SecureField("Host pairing token", text: $token)
                            .accessibilityIdentifier("pair-token")
                    }
                } header: {
                    Text(usesSSH ? "ACP over SSH" : kind == .codex ? "Private App Server endpoint" : "Private ACP endpoint")
                } footer: {
                    if usesSSH {
                        Text("On the server, authorize this public key for a forced ACP command. Verify the server’s host fingerprint separately. Your device key stays in Keychain.")
                    } else {
                        Text("Use a TLS endpoint you control over your private network. The host token goes in this device’s Keychain; it isn’t a model API key.")
                    }
                }
                if let failure {
                    Text(failure)
                        .foregroundStyle(ChatTheme.warning)
                        .accessibilityIdentifier("pair-error")
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Pair remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pairing?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pairing == nil ? "Pair" : "Pairing…") { pair() }
                        .disabled(pairing != nil)
                }
            }
            .onDisappear { pairing?.cancel() }
        }
    }

    private func pair() {
        failure = nil
        let secret = usesSSH ? sshIdentity.privateCredential : token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profile = RemoteProfile(kind: kind, name: name.isEmpty ? kind.name : name, address: address,
                                          workspace: workspace, mainSessionID: mainID,
                                          sshHostFingerprint: usesSSH ? sshFingerprint : nil),
              usesSSH || RemoteProfile.validBearer(secret) else { failure = PairingFailure.invalid.localizedDescription; return }
        pairing = Task {
            defer { pairing = nil }
            do {
                try await store.pair(profile, credential: secret)
                token = ""
                dismiss()
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}
