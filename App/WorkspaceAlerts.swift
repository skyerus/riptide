import CryptoKit
import Observation
import RiptideCore
import SwiftUI
import UserNotifications
import UIKit

@MainActor
final class RiptideNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var opened: ((WorkspaceChatID?) -> Void)?
    static var receivedToken: ((String) -> Void)?
    static var failedRegistration: (() -> Void)?
    static var pendingOpen: (WorkspaceChatID?, Bool)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Self.receivedToken?(token.map { String(format: "%02x", $0) }.joined())
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.failedRegistration?()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let data = response.notification.request.content.userInfo
        let chat = (data["workspace"] as? String).flatMap { workspace in
            (data["chat"] as? String).flatMap { chat in
                (1...200).contains(workspace.utf8.count) && (1...300).contains(chat.utf8.count)
                    ? WorkspaceChatID(workspace: workspace, chat: chat) : nil
            }
        }
        Task { @MainActor in
            if let opened = Self.opened { opened(chat) }
            else { Self.pendingOpen = (chat, true) }
            // UIKit uses the completion handler to update the app's foreground snapshot.
            completionHandler()
        }
    }
}

@MainActor @Observable
final class WorkspaceAlerts {
    private let defaults = UserDefaults.standard
    private let center = UNUserNotificationCenter.current()
    private let credentialID = UUID(uuidString: "00000000-0000-4000-8000-000000000021")!
    private let deviceID: UUID
    private var recent: [WorkspaceAttention.ID: Date] = [:]
    private var revision = 0
    private var token: String?
    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var changingRelay = false
    private(set) var relayAddress: String
    private(set) var policy: AttentionPolicy
    private(set) var message: String?
    private(set) var pushEnabled = false
    private var pushWorkspaces = Set<String>()
    weak var remotes: RemoteStore?
    var openWorkspace: ((WorkspaceChatID?) -> Void)?

    init() {
        policy = (try? JSONDecoder().decode(AttentionPolicy.self,
                                           from: defaults.data(forKey: "alerts.policy") ?? Data())) ?? .init()
        relayAddress = defaults.string(forKey: "alerts.relay-address") ?? ""
        deviceID = defaults.string(forKey: "alerts.device-id").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(deviceID.uuidString, forKey: "alerts.device-id")
    }

    var pushAvailable: Bool { pushEnvironment != nil }
    var hasHermesPairing: Bool { !hermesProfiles.isEmpty }

    private var hermesProfiles: [RemoteProfile] {
        remotes?.profiles.filter { $0.kind == .hermes && $0.sshHostFingerprint != nil } ?? []
    }

    func relayInbox() async -> [RelayedAttention]? {
        guard let relay else { return [] }
        return try? await relay.inbox()
    }

    func activate() {
        RiptideNotificationDelegate.opened = { [weak self] in self?.openWorkspace?($0) }
        if let pending = RiptideNotificationDelegate.pendingOpen {
            RiptideNotificationDelegate.pendingOpen = nil
            openWorkspace?(pending.0)
        }
        RiptideNotificationDelegate.receivedToken = { [weak self] token in
            self?.token = token
            Task { await self?.syncPush() }
        }
        RiptideNotificationDelegate.failedRegistration = { [weak self] in
            self?.pushEnabled = false
            self?.message = "This build couldn’t register for push. Local alerts are still available."
        }
        if policy.delivery != .off, (relay != nil || hasHermesPairing), pushAvailable {
            Task {
                guard await self.permissionsAllowed(), self.policy.delivery != .off else { return }
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func setPolicy(_ value: AttentionPolicy) async {
        revision += 1
        let requestRevision = revision
        message = nil
        if value.delivery != .off {
            let permitted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true
            guard requestRevision == revision else { return }
            if !permitted { message = "Allow notifications in iOS Settings to receive alerts." }
        }
        policy = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "alerts.policy") }
        if value.delivery == .off {
            center.removeAllPendingNotificationRequests()
            await syncPush()
        } else {
            activate()
            await syncPush()
        }
    }

    func pair(origin: String, bearer: String) async throws {
        guard let candidate = AttentionRelay(origin: origin, bearer: bearer) else { throw NativeVoiceError.invalidEndpoint }
        guard !changingRelay else { throw NativeVoiceError.expired }
        changingRelay = true
        defer { changingRelay = false }
        _ = try await candidate.presence()
        try Task.checkCancellation()
        revision += 1
        await registrationTask?.value
        if !relayAddress.isEmpty, let old = relay, let environment = pushEnvironment,
           old.origin != candidate.origin {
            try await old.updateDevice(id: deviceID, token: nil, environment: environment, policy: .init())
        }
        try KeychainToken.save(bearer, for: credentialID, purpose: "desktop-attention")
        relayAddress = candidate.origin.absoluteString
        defaults.set(relayAddress, forKey: "alerts.relay-address")
        message = "Private relay connected."
        changingRelay = false
        activate()
        await syncPush()
    }

    func unpair() async throws {
        guard !changingRelay else { throw NativeVoiceError.expired }
        changingRelay = true
        defer { changingRelay = false }
        revision += 1
        await registrationTask?.value
        if let relay, let environment = pushEnvironment {
            try await relay.updateDevice(id: deviceID, token: nil, environment: environment, policy: .init())
        }
        try KeychainToken.remove(credentialID, purpose: "desktop-attention")
        relayAddress = ""
        defaults.removeObject(forKey: "alerts.relay-address")
        pushEnabled = false
        message = nil
        changingRelay = false
        activate()
        await syncPush()
    }

    func receive(_ entry: WorkspaceAttention, appIsActive: Bool) {
        guard !appIsActive, policy.delivery != .off else { return }
        guard !pushWorkspaces.contains(entry.chat.workspace) else { return }
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 90 }
        guard recent[entry.id] == nil else { return }
        recent[entry.id] = now
        let current = revision
        Task {
            let presence = self.policy.delivery == .whenAway ? try? await self.relay?.presence(workspace: entry.chat.workspace) : nil
            guard self.revision == current, self.policy.allows(entry.reason, appIsActive: false, desktop: presence) else { return }
            let content = UNMutableNotificationContent()
            content.title = "Riptide"
            content.body = entry.reason.title
            content.sound = .default
            content.userInfo = ["workspace": entry.chat.workspace, "chat": entry.chat.chat]
            let identifier = SHA256.hash(data: Data("\(entry.chat.workspace)\n\(entry.chat.chat)\n\(entry.reason.rawValue)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            try? await self.center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    private var pushEnvironment: String? {
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "RiptidePushEnvironment") as? String,
              ["development", "production"].contains(environment) else { return nil }
        return environment
    }

    private var relay: AttentionRelay? {
        guard let bearer = KeychainToken.read(credentialID, purpose: "desktop-attention") else { return nil }
        return AttentionRelay(origin: relayAddress, bearer: bearer)
    }

    private func permissionsAllowed() async -> Bool {
        let settings = await center.notificationSettings()
        return [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
    }

    private func syncPush() async {
        guard !changingRelay else { return }
        let previous = registrationTask
        let work = Task { [weak self] in
            await previous?.value
            guard let self, !self.changingRelay else { return }
            await self.writePushRegistration()
        }
        registrationTask = work
        await work.value
    }

    private func writePushRegistration() async {
        guard let environment = pushEnvironment else { pushEnabled = false; return }
        let current = revision
        let value = policy
        let allowed = await permissionsAllowed()
        guard current == revision else { return }
        let remoteToken = value.delivery != .off && allowed ? token : nil
        if value.delivery != .off && allowed && remoteToken == nil { return }
        if let relay {
            do {
                try await relay.updateDevice(id: deviceID, token: remoteToken, environment: environment, policy: value)
                guard revision == current else { return }
                pushEnabled = remoteToken != nil
                if pushEnabled { message = "Push device registered with the private relay." }
            } catch {
                guard revision == current else { return }
                pushEnabled = false
                message = "Couldn’t update push. Check the private relay or use iOS Settings to turn alerts off immediately."
            }
        }
        let profiles = hermesProfiles
        guard !profiles.isEmpty else {
            pushWorkspaces = []
            if relay == nil { pushEnabled = false }
            return
        }
        let hermesToken = relay == nil ? remoteToken : nil
        var registered = Set<String>()
        for profile in profiles {
            guard revision == current else { return }
            guard let credential = remotes?.bearer(for: profile) else { continue }
            do {
                try await profile.registerHermesNotifications(credential: credential, token: hermesToken,
                                                               environment: environment, policy: value)
                if hermesToken != nil { registered.insert(profile.id.uuidString) }
            } catch { continue }
        }
        guard revision == current else { return }
        pushWorkspaces = registered
        if relay == nil {
            pushEnabled = !registered.isEmpty
            if pushEnabled { message = "Push is connected to Hermes." }
            else if remoteToken != nil { message = "Couldn’t connect to Hermes push. Check the SSH host’s notification relay." }
        }
    }
}

struct WorkspaceAlertSettings: View {
    @Environment(WorkspaceAlerts.self) private var alerts
    @Environment(\.dismiss) private var dismiss
    @State private var origin = ""
    @State private var bearer = ""
    @State private var issue: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Deliver alerts", selection: binding(\.delivery)) {
                        ForEach(AttentionDelivery.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Approvals and input", isOn: binding(\.approvals))
                        .tint(nil)
                    Toggle("Replies I missed", isOn: binding(\.replies))
                        .tint(nil)
                } footer: {
                    Text("When I’m away keeps the Inbox current but holds alerts for workspaces you’re using on a desktop. It won’t mute other workspaces.")
                        .foregroundStyle(ChatTheme.muted)
                }
                .listRowBackground(ChatTheme.surface)
                Section {
                    TextField("Relay URL", text: $origin, prompt: Text("https://private-relay.example").foregroundStyle(ChatTheme.muted))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Relay pairing token", text: $bearer, prompt: Text("Relay pairing token").foregroundStyle(ChatTheme.muted))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(alerts.relayAddress.isEmpty ? "Connect relay" : "Update relay") {
                        update { try await alerts.pair(origin: origin, bearer: bearer); bearer = "" }
                    }
                    .disabled(busy || origin.isEmpty || bearer.isEmpty)
                    if !alerts.relayAddress.isEmpty {
                        Button("Disconnect relay", role: .destructive) {
                            update { try await alerts.unpair(); origin = "" }
                        }
                        .disabled(busy)
                    }
                } header: {
                    Text("Desktop presence")
                } footer: {
                    Text(alerts.pushAvailable
                         ? (alerts.hasHermesPairing
                            ? "Hermes can send push through your existing SSH pairing when the host relay is running."
                            : "For alerts while the app is asleep, configure push and event publishers on your private relay.")
                         : "This build can alert for live connections while iOS is still running Riptide. Alerts while the app is suspended require a push-enabled build and private relay.")
                        .foregroundStyle(ChatTheme.muted)
                }
                .listRowBackground(ChatTheme.surface)
                if let line = issue ?? alerts.message { Text(line).font(.footnote).foregroundStyle(ChatTheme.muted) }
            }
            .scrollContentBackground(.hidden)
            .background(ChatTheme.background)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { origin = alerts.relayAddress }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AttentionPolicy, Value>) -> Binding<Value> {
        Binding(get: { alerts.policy[keyPath: keyPath] }) { value in
            var newPolicy = alerts.policy
            newPolicy[keyPath: keyPath] = value
            Task { await alerts.setPolicy(newPolicy) }
        }
    }

    private func update(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        issue = nil
        Task {
            defer { busy = false }
            do { try await work() }
            catch { issue = error.localizedDescription }
        }
    }
}
