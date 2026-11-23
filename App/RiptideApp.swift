import RiptideCore
import SwiftUI

@main
struct RiptideApp: App {
    private let roster: [AgentChatModel]
    private let preferences: UserDefaults
    private let localCodex: CodexLocalEndpoint?
    private let remotes: RemoteStore

    private static var fixtureNamespace: UUID? {
        ProcessInfo.processInfo.environment["RIPTIDE_FIXTURE_NAMESPACE"].flatMap(UUID.init(uuidString:))
    }

    init() {
        roster = AgentTarget.demos.map { Self.makeDemo($0) }
        preferences = Self.fixtureNamespace.flatMap { UserDefaults(suiteName: "app.riptide.fixture.\($0.uuidString)") }
            ?? .standard
        remotes = RemoteStore(defaults: preferences)
        #if DEBUG
        localCodex = CodexLocalEndpoint(environment: ProcessInfo.processInfo.environment)
        #else
        localCodex = nil
        #endif
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                AgentRoster(roster: roster, localCodex: localCodex, remotes: remotes)
            }
            .defaultAppStorage(preferences)
            .preferredColorScheme(.dark)
            .tint(ChatTheme.accent)
        }
    }

    private static func makeDemo(_ target: AgentTarget) -> AgentChatModel {
        var directory = URL.applicationSupportDirectory.appending(path: "RiptideFixtures", directoryHint: .isDirectory)
        if let id = fixtureNamespace {
            directory.append(path: id.uuidString, directoryHint: .isDirectory)
        }
        let file = directory.appending(path: "\(target.id).json")
        do {
            let transport = try FixtureTransport(target: target, file: file)
            return AgentChatModel(target: target, client: ACPClient(transport: transport))
        } catch {
            return AgentChatModel(target: target, unavailable: "Saved demo chats could not be opened.")
        }
    }
}

enum ChatTheme {
    static let background = Color(red: 16 / 255, green: 19 / 255, blue: 23 / 255)
    static let surface = Color(red: 25 / 255, green: 31 / 255, blue: 37 / 255)
    static let inset = Color.white.opacity(0.07)
    static let border = Color.white.opacity(0.12)
    static let accent = Color(red: 118 / 255, green: 220 / 255, blue: 199 / 255)
}
