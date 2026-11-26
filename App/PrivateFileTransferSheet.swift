import RiptideCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PrivateFileTransferSheet: View {
    let transfer: PrivateFileTransfer
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var selected: URL?
    @State private var upload: Task<Void, Never>?
    @State private var path: String?
    @State private var copied = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Destination", value: transfer.destination)
                } footer: {
                    Text("The file goes directly to the VPS over SSH, outside the conversation.")
                }
                if let path {
                    Section("Uploaded to VPS") {
                        Text(path).font(.footnote.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("private-file-path")
                        Button(copied ? "Path Copied" : "Copy VPS Path", systemImage: copied ? "checkmark" : "document.on.document") {
                            UIPasteboard.general.setItems([[UTType.plainText.identifier: path]], options: [.localOnly: true])
                            copied = true
                        }
                    }
                } else {
                    Section {
                        Button("Choose File", systemImage: "folder") { choosing = true }
                            .disabled(upload != nil)
                        if let selected {
                            Text(selected.lastPathComponent)
                            if upload != nil {
                                ProgressView("Uploading…")
                            } else {
                                Button("Upload", systemImage: "lock", action: send)
                            }
                        }
                    } footer: {
                        Text("Choose one file up to 1 MB.")
                    }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Send File to VPS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(path == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    selected = url
                    problem = nil
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        problem = "Riptide couldn’t open the selected file."
                    }
                }
            }
        }
        .interactiveDismissDisabled(upload != nil)
        .onDisappear { upload?.cancel() }
    }

    private func send() {
        guard let selected, upload == nil else { return }
        problem = nil
        upload = Task {
            defer { upload = nil }
            do {
                let data = try await Self.readFile(selected)
                try Task.checkCancellation()
                let receipt = try await transfer.send(name: selected.lastPathComponent, data: data)
                if !Task.isCancelled { path = receipt }
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
        }
    }

    @concurrent private static func readFile(_ url: URL) async throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileReadUnknown)
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: PrivateFileTransfer.byteLimit + 1) ?? Data()
        } catch {
            throw ReadError.unreadable
        }
        guard data.count <= PrivateFileTransfer.byteLimit else { throw ReadError.tooLarge }
        return data
    }

    private enum ReadError: LocalizedError {
        case unreadable, tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: "Riptide couldn’t read the selected file."
            case .tooLarge: "Choose a file up to 1 MB."
            }
        }
    }
}
