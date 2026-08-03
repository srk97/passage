import PassageCore
import SwiftUI

struct AgentActivityList: View {
    @Bindable var model: PassageModel
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Access History")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("Handoffs and agent reads get a receipt before release")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear…") { confirmingClear = true }
                    .disabled(model.accessEvents.isEmpty)
            }
            .padding(18)

            Divider().opacity(0.45)

            if model.accessEvents.isEmpty {
                ContentUnavailableView {
                    Label("No access yet", systemImage: "checkmark.shield")
                } description: {
                    Text("Context you copy and valid requests from enabled local apps appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.accessEvents) { event in
                            AccessEventRow(event: event)
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
        .confirmationDialog(
            "Clear access receipts?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear receipts", role: .destructive) { model.clearAccessHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the audit history, not captured moments.")
        }
    }
}

private struct AccessEventRow: View {
    let event: AccessEvent

    private var color: Color {
        switch event.outcome {
        case .success: PassagePalette.mint
        case .denied: PassagePalette.violet
        case .failure: .red
        }
    }

    private var commandLabel: String {
        switch event.command {
        case "copyContext": "Copied context"
        default: event.command.capitalized
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                Circle().fill(color.opacity(0.12))
                Image(systemName: event.outcome == .success ? "checkmark" : "exclamationmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 5) {
                Text(event.client)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .help(event.client)
                HStack(spacing: 6) {
                    Text(commandLabel)
                    Text("·")
                    Text("\(event.returnedFrameCount) source\(event.returnedFrameCount == 1 ? "" : "s")")
                    Spacer(minLength: 6)
                    Text(event.occurredAt, format: .dateTime.hour().minute().second())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                if let query = event.querySummary, !query.isEmpty {
                    Text("“\(query)”")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !event.returnedFrameIDs.isEmpty {
                    Text(event.returnedFrameIDs.map(\.rawValue).joined(separator: "  ·  "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help(event.returnedFrameIDs.map(\.rawValue).joined(separator: "\n"))
                }
            }
        }
        .padding(12)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct AgentActivityDetail: View {
    @Bindable var model: PassageModel

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(PassagePalette.mint.opacity(0.10))
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(PassagePalette.mint)
                    }
                    .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 9) {
                        Text("Inspectable by design")
                            .font(.system(size: 25, weight: .semibold, design: .rounded))
                        Text("Passage records a receipt here before copied context reaches the macOS clipboard or an enabled local app receives evidence. Other apps cannot browse Passage’s database or read its encryption key.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 9) {
                        Circle()
                            .fill(model.agentServiceAvailable ? PassagePalette.mint : .red)
                            .frame(width: 8, height: 8)
                        Text(model.agentServiceAvailable ? "Local agent service available" : "Local agent service unavailable")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())

                    if let error = model.agentServiceError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 480, alignment: .leading)
                .padding(40)
                .frame(
                    maxWidth: .infinity,
                    minHeight: proxy.size.height,
                    alignment: .center
                )
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
