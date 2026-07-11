import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    /// True while this message is still being generated — keeps a visible
    /// "working" pulse on the bubble through silent stretches (model
    /// thinking, tool lookups) so a slow turn never reads as hung.
    var working: Bool = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 8) {
                if let image = message.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if message.role == .assistant, let verdict = message.verdict {
                    verdictBanner(verdict)
                }
                if message.role == .assistant, message.identification != nil {
                    identificationBlock
                }
                if message.role == .assistant, message.identification != nil,
                    message.verdict == nil
                {
                    // Named it; now looking the name up in the triage table.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking the medical list…").foregroundStyle(.secondary)
                    }
                } else if message.isThinking && message.bodyText.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking…").foregroundStyle(.secondary)
                    }
                } else if message.bodyText.isEmpty && message.image == nil
                    && message.verdict == nil && message.identification == nil
                {
                    ProgressView().controlSize(.small)
                } else if !message.bodyText.isEmpty {
                    Text(message.bodyText)
                        .textSelection(.enabled)
                }
                if working, !message.bodyText.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
                if message.role == .assistant, message.verdict != nil,
                    !message.bodyText.isEmpty
                {
                    disclaimer
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.role == .user
                    ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(.fill.secondary),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .foregroundStyle(message.role == .user ? .white : .primary)

            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }

    /// What the model thinks it is, and why. Shown above the note so a
    /// misidentification is obvious at a glance: the verdict is only as good
    /// as the ID it was looked up from, and the user is the one who can see
    /// both the animal and the name.
    @ViewBuilder
    private var identificationBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let identification = message.identification {
                Text(identification)
                    .font(.headline)
                    .textSelection(.enabled)
            }
            if let observed = message.observed {
                Text("Model saw: \(observed)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    /// Shown under every verdict. A photo first look can be wrong in both
    /// directions, so the app never implies a diagnosis or an all-clear.
    private var disclaimer: some View {
        Text(
            "NOT A DOCTOR. This is an on-device first look, not a diagnosis — AI can be wrong, and a photo can't rule anything out. When in doubt, see a clinician. Emergencies: call 911; poisoning: 1-800-222-1222. Reference answers draw on MedlinePlus (medlineplus.gov), a service of the NIH's National Library of Medicine, which does not endorse this app."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func verdictBanner(_ verdict: ChatMessage.Verdict) -> some View {
        let (label, icon, color): (String, String, Color) =
            switch verdict {
            case .urgent: ("GET CARE NOW", "cross.circle.fill", .red)
            case .soon: ("SEE A DOCTOR SOON", "calendar.badge.exclamationmark", .orange)
            case .watch: ("WORTH A LOOK", "eye.circle.fill", .yellow)
            case .routine: ("USUALLY MINOR", "checkmark.circle.fill", .blue)
            }
        return HStack(spacing: 8) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.headline.bold())
        // Yellow needs dark text for contrast; the rest read best in white.
        .foregroundStyle(verdict == .watch ? Color.black : Color.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color, in: Capsule())
    }
}
