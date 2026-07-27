import SwiftUI

struct EventTitleEditorView: View {
    let navigationTitle: String
    let saveButtonTitle: String
    let unchangedTitle: String?
    let onSave: (String) async throws -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var title: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    
    init(
        navigationTitle: String,
        saveButtonTitle: String,
        initialTitle: String = "",
        unchangedTitle: String? = nil,
        onSave:
        @escaping (String) async throws -> Void
    ) {
        self.navigationTitle = navigationTitle
        self.saveButtonTitle = saveButtonTitle
        self.unchangedTitle = unchangedTitle
        self.onSave = onSave
        
        _title = State(
            initialValue: initialTitle
        )
    }
    
    private var trimmedTitle: String {
        title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
    
    private var isUnchanged: Bool {
        guard let unchangedTitle else {
            return false
        }
        
        return trimmedTitle == unchangedTitle
    }
    
    private var canSave: Bool {
        !isSaving
        && !trimmedTitle.isEmpty
        && trimmedTitle.count <= 120
        && !isUnchanged
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField(
                        "Event name",
                        text: $title
                    )
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit {
                        save()
                    }
                    
                    HStack {
                        Text(
                            "Use a clear name you will recognize later."
                        )
                        
                        Spacer()
                        
                        Text("\(trimmedTitle.count)/120")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(
                        trimmedTitle.count > 120
                        ? Color.red
                        : Color.secondary
                    )
                }
                
                if let errorMessage {
                    Section {
                        Label(
                            errorMessage,
                            systemImage:
                                "exclamationmark.triangle"
                        )
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                
                ToolbarItem(
                    placement: .confirmationAction
                ) {
                    Button(saveButtonTitle) {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .overlay {
                if isSaving {
                    ProgressView()
                        .controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 16,
                                style: .continuous
                            )
                        )
                }
            }
        }
    }
    
    private func save() {
        guard canSave else {
            return
        }
        
        let titleToSave = trimmedTitle
        
        Task {
            isSaving = true
            errorMessage = nil
            
            defer {
                isSaving = false
            }
            
            do {
                try await onSave(titleToSave)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
