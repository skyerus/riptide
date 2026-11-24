import RiptideCore
import SwiftUI

struct PairRemoteScreen: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind = RemoteKind.codex
    @State private var name = ""
    @State private var address = ""
    @State private var workspace = ""
    @State private var mainID = ""
    @State private var token = ""
    @State private var failure: String?
    @State private var pairing: Task<Void, Never>?

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
                }
                Section {
                    TextField("wss://host.example/agent", text: $address)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("pair-address")
                    TextField("Absolute workspace path", text: $workspace)
                    if kind != .codex {
                        TextField("Existing main chat ID", text: $mainID)
                    }
                    SecureField("Host pairing token", text: $token)
                } header: {
                    Text(kind == .codex ? "Private App Server endpoint" : "Private ACP endpoint")
                } footer: {
                    Text("Use a TLS endpoint you control over your private network. The host token goes in this device’s Keychain; it isn’t a model API key.")
                }
                if let failure { Text(failure).foregroundStyle(.red) }
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
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profile = RemoteProfile(kind: kind, name: name.isEmpty ? kind.name : name, address: address,
                                          workspace: workspace, mainSessionID: mainID),
              RemoteProfile.validBearer(secret) else { failure = PairingFailure.invalid.localizedDescription; return }
        pairing = Task {
            defer { pairing = nil }
            do {
                try await store.pair(profile, bearer: secret)
                token = ""
                dismiss()
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}
