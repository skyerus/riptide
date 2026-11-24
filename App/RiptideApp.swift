import RiptideCore
import SwiftUI

@main
struct RiptideApp: App {
    @UIApplicationDelegateAdaptor(RiptideNotificationDelegate.self) private var notificationDelegate
    private let roster: [AgentChatModel]
    private let preferences: UserDefaults
    private let localCodex: CodexLocalEndpoint?
    private let remotes: RemoteStore
    @State private var workspace: WorkspaceState
    @State private var seededBusyInbox = false

    private static var fixtureNamespace: UUID? {
        ProcessInfo.processInfo.environment["RIPTIDE_FIXTURE_NAMESPACE"].flatMap(UUID.init(uuidString:))
    }

    init() {
        let base = AgentTarget.demos.map { Self.makeDemo($0) }
        #if DEBUG
        let busy = Self.fixtureNamespace != nil && ProcessInfo.processInfo.environment["RIPTIDE_BUSY_WORKSPACE"] == "1"
        roster = base + (busy ? (1...12).map { index in
            let id = "ops-\(index)"
            return Self.makeDemo(
                AgentTarget(id: id, name: "Ops \(index)", mainSessionID: "\(id)-main", cwd: "/demo/\(id)"),
                catalog: (1...24).map { "Incident \($0) review" })
        } : [])
        #else
        roster = base
        #endif
        preferences = Self.fixtureNamespace.flatMap { UserDefaults(suiteName: "app.riptide.fixture.\($0.uuidString)") }
            ?? .standard
        remotes = RemoteStore(defaults: preferences)
        #if DEBUG
        localCodex = CodexLocalEndpoint(environment: ProcessInfo.processInfo.environment)
        #else
        localCodex = nil
        #endif
        _workspace = State(initialValue: WorkspaceState(roster: roster, localCodex: localCodex,
                                                        remotes: remotes, defaults: preferences))
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceNavigation(workspace: workspace)
            .defaultAppStorage(preferences)
            .preferredColorScheme(.dark)
            .tint(ChatTheme.accent)
            .task { await seedBusyInbox() }
        }
    }

    @MainActor
    private func seedBusyInbox() async {
        #if DEBUG
        guard Self.fixtureNamespace != nil, !seededBusyInbox,
              ProcessInfo.processInfo.environment["RIPTIDE_BUSY_INBOX"] == "1" else { return }
        seededBusyInbox = true
        for model in roster where model.target.id.hasPrefix("ops-") {
            await model.showMain()
            model.submit("Show an approval")
        }
        #endif
    }

    private static func makeDemo(_ target: AgentTarget, catalog: [String] = []) -> AgentChatModel {
        var directory = URL.applicationSupportDirectory.appending(path: "RiptideFixtures", directoryHint: .isDirectory)
        if let id = fixtureNamespace {
            directory.append(path: id.uuidString, directoryHint: .isDirectory)
        }
        let file = directory.appending(path: "\(target.id).json")
        do {
            let transport = try FixtureTransport(target: target, file: file, catalog: catalog)
            return AgentChatModel(target: target, client: ACPClient(transport: transport))
        } catch {
            return AgentChatModel(target: target, unavailable: "Saved demo chats could not be opened.")
        }
    }
}

enum ChatTheme {
    static let background = Color(red: 14 / 255, green: 17 / 255, blue: 21 / 255)
    static let surface = Color(red: 26 / 255, green: 33 / 255, blue: 40 / 255)
    static let raised = Color(red: 34 / 255, green: 43 / 255, blue: 51 / 255)
    static let ink = Color(red: 243 / 255, green: 247 / 255, blue: 250 / 255)
    static let muted = Color(red: 175 / 255, green: 191 / 255, blue: 203 / 255)
    static let inset = Color.white.opacity(0.08)
    static let border = Color.white.opacity(0.16)
    static let accent = Color(red: 127 / 255, green: 234 / 255, blue: 210 / 255)
    static let selected = Color(red: 28 / 255, green: 63 / 255, blue: 58 / 255)
    static let warning = Color(red: 255 / 255, green: 215 / 255, blue: 151 / 255)
}
