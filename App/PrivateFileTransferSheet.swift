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
    @State private var progress: Double?
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
                                if let progress {
                                    ProgressView(value: progress) {
                                        Text("Uploading…")
                                    } currentValueLabel: {
                                        Text(progress.formatted(.percent.precision(.fractionLength(0))))
                                            .monospacedDigit()
                                    }
                                    .accessibilityIdentifier("private-file-upload-progress")
                                } else {
                                    ProgressView("Uploading…")
                                }
                            } else {
                                Button("Upload", systemImage: "lock", action: send)
                            }
                        }
                    } footer: {
                        Text("Choose one file up to 100 MiB.")
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
        progress = nil
        upload = Task {
            defer { upload = nil }
            do {
                let receipt = try await transfer.send(file: selected) { sent, total in
                    await MainActor.run {
                        progress = total > 0 ? Double(sent) / Double(total) : nil
                    }
                }
                if !Task.isCancelled { path = receipt }
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
        }
    }
}
