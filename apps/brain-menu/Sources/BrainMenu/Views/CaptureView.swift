import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct CaptureView: View {
    @Bindable var controller: CaptureController

    @State private var isChoosingImage = false
    @State private var isChoosingTranscript = false
    @State private var isDropTargeted = false
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityTarget?

    private enum AccessibilityTarget: Hashable {
        case heading
        case primaryField
        case errorSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Capture to Brain")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($accessibilityFocus, equals: .heading)
                Text("Tracked until it reaches the Brain inbox. Librarian processing and site publishing follow separately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("Capture type", selection: $controller.draft.kind) {
                ForEach(CaptureKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch controller.draft.kind {
                case .note:
                    noteFields
                case .link:
                    linkFields
                case .image:
                    imageFields
                case .transcript:
                    transcriptFields
                }
            }
            .disabled(controller.isSubmitting)

            deliveryStatus

            HStack(spacing: 10) {
                Button {
                    _ = controller.pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .help("Brain reads the clipboard only when you click Paste.")
                .disabled(controller.isSubmitting)

                Spacer()

                if controller.canRetry {
                    Button {
                        Task {
                            await controller.retry()
                            focusDirectSubmissionErrorIfNeeded()
                        }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }

                Button {
                    Task {
                        await controller.submit()
                        focusDirectSubmissionErrorIfNeeded()
                    }
                } label: {
                    if controller.isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Sending capture")
                    } else {
                        Label("Send to Brain", systemImage: "paperplane.fill")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canSubmit)
            }

            Text("Text can be typed or inserted by Mac Parakeet or system dictation. Brain.app does not record or retain audio, and it keeps no clipboard history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(minWidth: 540, idealWidth: 600, minHeight: 440)
        .onAppear { accessibilityFocus = .primaryField }
        .fileImporter(
            isPresented: $isChoosingImage,
            allowedContentTypes: [.jpeg, .png, .webP],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                controller.loadImage(from: url)
            }
        }
        .fileImporter(
            isPresented: $isChoosingTranscript,
            allowedContentTypes: Self.transcriptTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                controller.loadTranscript(from: url)
            }
        }
    }

    @ViewBuilder
    private var deliveryStatus: some View {
        switch controller.submissionState {
        case .idle:
            EmptyView()
        case .sending:
            Label("Sending capture", systemImage: "paperplane")
                .foregroundStyle(.secondary)
        case .retrying:
            Label("Retrying capture", systemImage: "arrow.clockwise")
                .foregroundStyle(.secondary)
        case .queued(let id):
            Label("Queued in Brain (\(id))", systemImage: "clock")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .brainAccessibleStatus(.queued, detail: "Capture \(id)")
        case .delivering(let id):
            Label("Delivering to Brain (\(id))", systemImage: "arrow.up.circle")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .waitingForMacMini(let id, let elapsedSeconds, let lastState, let lastError):
            VStack(alignment: .leading, spacing: 8) {
                Label("Waiting for remote runner", systemImage: "macmini.and.arrow.forward")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .brainAccessibleStatus(
                        .waiting,
                        detail: "Capture \(id), \(Self.elapsed(elapsedSeconds)) elapsed"
                    )
                Text("\(Self.elapsed(elapsedSeconds)) elapsed · last state: \(lastState.rawValue)")
                    .foregroundStyle(.secondary)
                Text(lastError ?? "The capture is safe and status monitoring continues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(id).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Check again") { controller.checkAgain() }
                        .accessibilityHint("Checks this capture without sending it again")
                    Button("Open remote runner") { controller.openMacMini() }
                        .accessibilityHint("Opens remote runner health and recovery")
                }
            }
        case .delivered(let id):
            VStack(alignment: .leading, spacing: 4) {
                Label("Delivered to Brain inbox (\(id))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Awaiting Librarian processing. The private site updates after processing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            .brainAccessibleStatus(
                .delivered,
                detail: "Capture \(id). Delivered to the Brain inbox and awaiting Librarian processing"
            )
        case .retryAvailable(let id):
            Label(
                "Retry available for \(id): \(controller.errorMessage ?? "delivery failed")",
                systemImage: "arrow.clockwise.circle"
            )
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        case .needsAttention(let id):
            Label(
                "Needs attention for \(id): \(controller.errorMessage ?? "delivery failed")",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .brainAccessibleStatus(.failed, detail: controller.errorMessage ?? "Delivery failed")
            .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
        case .failed:
            Label(
                controller.errorMessage ?? "Capture could not be sent.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .brainAccessibleStatus(
                .failed,
                detail: controller.errorMessage ?? "Capture could not be sent"
            )
            .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
        }
    }

    private static func elapsed(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }

    private func focusDirectSubmissionErrorIfNeeded() {
        if case .failed = controller.submissionState {
            accessibilityFocus = .errorSummary
        }
    }

    private var noteFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note")
                .font(.headline)
            TextEditor(text: $controller.draft.noteText)
                .font(.body)
                .frame(minHeight: 190)
                .captureEditorBorder()
                .accessibilityLabel("Note text")
                .accessibilityFocused($accessibilityFocus, equals: .primaryField)
        }
    }

    private var linkFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("https://example.com", text: $controller.draft.url)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Bookmark URL")
                .accessibilityFocused($accessibilityFocus, equals: .primaryField)

            VStack(alignment: .leading, spacing: 6) {
                Text("Comment (optional)")
                    .font(.headline)
                TextEditor(text: $controller.draft.comment)
                    .frame(minHeight: 70)
                    .captureEditorBorder()
                    .accessibilityLabel("Bookmark comment")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Selected text (optional)")
                    .font(.headline)
                TextEditor(text: $controller.draft.selectedText)
                    .frame(minHeight: 90)
                    .captureEditorBorder()
                    .accessibilityLabel("Selected text")
            }
        }
    }

    private var imageFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 8) {
                Image(systemName: controller.draft.image == nil ? "photo.badge.plus" : "photo.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                Text(controller.draft.image?.filename ?? "Drop a JPEG, PNG, or WebP here")
                    .lineLimit(1)
                Button("Choose Image…") {
                    isChoosingImage = true
                }
                .accessibilityHint("Opens a file picker for a JPEG, PNG, or WebP image")
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25))
            }
            .onDrop(
                of: [UTType.jpeg.identifier, UTType.png.identifier, UTType.webP.identifier],
                isTargeted: $isDropTargeted,
                perform: receiveImageDrop
            )
            .accessibilityLabel("Image drop target")

            VStack(alignment: .leading, spacing: 6) {
                Text("Searchable context")
                    .font(.headline)
                TextEditor(text: $controller.draft.imageContext)
                    .frame(minHeight: 120)
                    .captureEditorBorder()
                    .accessibilityLabel("Searchable image context")
                    .accessibilityFocused($accessibilityFocus, equals: .primaryField)
                Text("Required for design captures so the visual can be found later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transcriptFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcript")
                        .font(.headline)
                    Text(controller.draft.transcriptFilename ?? "Choose a UTF-8 .md or .txt file")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Transcript…") {
                    isChoosingTranscript = true
                }
                .accessibilityHint("Opens a file picker for a Markdown or text transcript")
            }

            TextEditor(text: $controller.draft.transcriptText)
                .font(.body.monospaced())
                .frame(minHeight: 210)
                .captureEditorBorder()
                .accessibilityLabel("Transcript text")
                .accessibilityFocused($accessibilityFocus, equals: .primaryField)
        }
    }

    private func receiveImageDrop(_ providers: [NSItemProvider]) -> Bool {
        let supported: [(UTType, String)] = [
            (.jpeg, "image/jpeg"),
            (.png, "image/png"),
            (.webP, "image/webp"),
        ]
        for (type, mimeType) in supported {
            guard let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(type.identifier)
            }) else { continue }
            let suggestedName = provider.suggestedName
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    controller.acceptDroppedImage(
                        data: data,
                        mimeType: mimeType,
                        filename: suggestedName
                    )
                }
            }
            return true
        }
        return false
    }

    private static var transcriptTypes: [UTType] {
        [UTType(filenameExtension: "md"), UTType(filenameExtension: "txt")]
            .compactMap { $0 }
    }
}

private extension View {
    func captureEditorBorder() -> some View {
        overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25))
        }
    }
}
