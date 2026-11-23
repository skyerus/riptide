import RiptideCore
import SwiftUI

struct PairNativeVoiceScreen: View {
    let remote: RemoteProfile
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var profile = ""
    @State private var token = ""
    @State private var talksToken = ""
    @State private var route: HermesVoiceRoute = .talkSubscription
    @State private var failure: String?
    @State private var attempt: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if remote.kind == .hermes {
                        Picker("Voice route", selection: $route) {
                            ForEach(HermesVoiceRoute.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                    }
                    TextField(remote.kind == .hermes ? "https://host.example" : "wss://host.example", text: $address)
                        .keyboardType(.URL)
                    if remote.kind == .hermes {
                        TextField("Hermes profile (optional)", text: $profile)
                    }
                    SecureField(remote.kind == .hermes ? "Dashboard session token" : "Gateway pairing token", text: $token)
                    if remote.kind == .hermes && route == .talkSubscription {
                        SecureField("Talk token (if required by host)", text: $talksToken)
                    }
                } header: {
                    Text(remote.kind == .hermes ? "Hermes Dashboard" : "OpenClaw Gateway")
                } footer: {
                    Text(remote.kind == .hermes && route == .talkSubscription
                         ? "Use the same hostname as chat. The host must be signed in to Codex and configured for Talk Live subscription billing. No API fallback."
                         : "Use the same hostname as chat. Voice uses your host’s configured provider.")
                }
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            }
            .navigationTitle("Pair \(remote.kind.name) voice")
            .navigationBarTitleDisplayMode(.inline)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onAppear {
                if let saved = store.voice(for: remote) {
                    address = saved.address
                    profile = saved.hermesProfile ?? ""
                    route = saved.selectedHermesRoute
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { attempt?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(attempt == nil ? "Pair" : "Pairing…") { pair() }
                        .disabled(attempt != nil)
                }
            }
            .onDisappear { attempt?.cancel() }
        }
    }

    private func pair() {
        failure = nil
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = talksToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let talkToken = remote.kind == .hermes && route == .talkSubscription && !extra.isEmpty ? extra : nil
        guard let config = NativeVoiceProfile(kind: remote.kind, address: address, hermesProfile: profile,
                                              hermesRoute: remote.kind == .hermes ? route : nil),
              talkToken.map(RemoteProfile.validBearer) ?? true,
              RemoteProfile.validBearer(token) else {
            failure = NativeVoiceError.invalidEndpoint.localizedDescription
            return
        }
        guard URL(string: config.address)?.host?.lowercased() == URL(string: remote.address)?.host?.lowercased() else {
            failure = "The voice endpoint must use the same hostname as this chat remote."
            return
        }
        attempt = Task {
            defer { attempt = nil }
            do {
                try await store.pairVoice(config, token: token, talkToken: talkToken, for: remote)
                self.token = ""
                talksToken = ""
                dismiss()
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}
