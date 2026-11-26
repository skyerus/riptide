import RiptideCore
import SwiftUI

struct ChatPicker: View {
    private static let compactDetent = PresentationDetent.height(310)

    let model: AgentChatModel
    let openClaw: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var searching: Bool
    @State private var search = ""
    @State private var detent = compactDetent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, ChatTheme.gutter)
                .padding(.top, 14)
                .padding(.bottom, 16)

            ScrollView {
                chatList
                    .padding(.horizontal, ChatTheme.gutter)
                    .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.refreshSessions() }
            .accessibilityIdentifier("chat-picker-list")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(ChatTheme.ink)
        .presentationBackground(ChatTheme.background)
        .presentationDetents([Self.compactDetent, .large], selection: $detent)
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .onChange(of: dynamicTypeSize, initial: true) {
            if dynamicTypeSize.isAccessibilitySize { detent = .large }
        }
        .onChange(of: searching) {
            if searching { detent = .large }
        }
        .task { await model.refreshSessions() }
    }

    private var header: some View {
        let controls = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chats")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(model.target.name)
                        .font(.subheadline)
                        .foregroundStyle(ChatTheme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(ChatTheme.surface, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close chats")
                .accessibilityIdentifier("close-chats")
            }

            controls {
                searchField
                newChatButton
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ChatTheme.muted)
                .accessibilityHidden(true)
            TextField("Find a chat", text: $search, prompt: Text("Find a chat").foregroundStyle(ChatTheme.muted))
                .font(.subheadline)
                .frame(minHeight: 48)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searching)
                .onSubmit { searching = false }
                .accessibilityIdentifier("chat-picker-search")
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(ChatTheme.muted)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -8)
                .accessibilityLabel("Clear chat search")
            }
        }
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(ChatTheme.surface)
                .onTapGesture { searching = true }
                .accessibilityHidden(true)
        }
    }

    private var newChatButton: some View {
        Button {
            Task { if await model.createChat(openClaw: openClaw) { dismiss() } }
        } label: {
            HStack(spacing: 7) {
                if model.creatingChat {
                    ProgressView().controlSize(.small).tint(ChatTheme.background)
                } else {
                    Image(systemName: "square.and.pencil")
                        .accessibilityHidden(true)
                }
                Text(model.creatingChat ? "Starting…" : "New chat")
            }
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .foregroundStyle(ChatTheme.background)
            .background(ChatTheme.ink, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(model.creatingChat)
        .accessibilityIdentifier("new-chat")
    }

    private var chatList: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let mainID = model.target.mainSessionID
        let showsMain = query.isEmpty || "Main Chat".localizedCaseInsensitiveContains(query)
        let sideChats = model.sessions.filter {
            $0.id != mainID && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }

        return LazyVStack(alignment: .leading, spacing: 16) {
            if let error = model.listError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(ChatTheme.warning)
                    .padding(.horizontal, 12)
            }

            if showsMain {
                chatRow("Main Chat", id: mainID, isMain: true)
                    .accessibilityIdentifier("chat-picker-main")
            }

            if !sideChats.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Side chats")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ChatTheme.muted)
                        .padding(.horizontal, 12)
                        .accessibilityAddTraits(.isHeader)

                    LazyVStack(spacing: 2) {
                        ForEach(sideChats) { chat in
                            chatRow(chat.title, id: chat.id)
                        }
                    }
                }
            }

            if model.refreshingList {
                ProgressView("Loading chats…")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
            } else if model.listError == nil && sideChats.isEmpty {
                if query.isEmpty {
                    Text("No side chats yet.")
                        .font(.subheadline)
                        .foregroundStyle(ChatTheme.muted)
                        .padding(.horizontal, 12)
                } else if !showsMain {
                    ContentUnavailableView.search(text: query)
                        .accessibilityIdentifier("chat-picker-no-results")
                }
            }
        }
    }

    private func chatRow(_ title: String, id: String, isMain: Bool = false) -> some View {
        let isSelected = id == model.selectedID

        return Button {
            Task { await model.open(id) }
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isMain ? "bubble.left.fill" : "bubble.left")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isSelected ? ChatTheme.sidebarAccent : ChatTheme.muted)
                    .frame(minWidth: 22)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body.weight(isSelected || isMain ? .semibold : .regular))
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ChatTheme.sidebarAccent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isMain ? 14 : 10)
            .frame(minHeight: isMain ? 54 : 44)
            .background(isSelected ? ChatTheme.raised : isMain ? ChatTheme.surface : .clear,
                        in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu { FollowUpButton(chat: .init(workspace: model.target.id, chat: id), title: title) }
    }
}
