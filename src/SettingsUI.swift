import SwiftUI
import AVFoundation

// MARK: - shared building blocks (Vibe-Island-style settings)

struct IconBadge: View {
    let icon: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(color.gradient)
            Image(systemName: icon)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.055)))
    }
}

struct CardDivider: View {
    var body: some View {
        Divider().opacity(0.5).padding(.leading, 14)
    }
}

struct CardRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .bold))
            .padding(.top, 6)
    }
}

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
    }
}

// MARK: - settings window

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, claude, models, transcripts, hints, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .claude: return "Claude Account"
        case .models: return "Models"
        case .transcripts: return "Transcripts"
        case .hints: return "Live Answers"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .claude: return "sparkles"
        case .models: return "cpu.fill"
        case .transcripts: return "folder.fill"
        case .hints: return "bubble.left.and.bubble.right.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: return .gray
        case .claude: return .orange
        case .models: return .purple
        case .transcripts: return .blue
        case .hints: return .green
        case .permissions: return .red
        case .about: return .cyan
        }
    }
}

struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconBadge(icon: pane.icon, color: pane.color, size: 24)
                Text(pane.title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    @State private var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            // sidebar
            VStack(alignment: .leading, spacing: 2) {
                ForEach([SettingsPane.general, .claude, .models, .transcripts, .hints]) { p in
                    SidebarItem(pane: p, selected: pane == p) { pane = p }
                }
                Text("Advanced")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14).padding(.leading, 10).padding(.bottom, 2)
                SidebarItem(pane: .permissions, selected: pane == .permissions) { pane = .permissions }
                Text("NerdSidekiq")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14).padding(.leading, 10).padding(.bottom, 2)
                SidebarItem(pane: .about, selected: pane == .about) { pane = .about }
                Spacer()
            }
            .padding(10)
            .frame(width: 200)
            .background(Color.primary.opacity(0.03))

            Divider()

            // detail
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        IconBadge(icon: pane.icon, color: pane.color, size: 30)
                        Text(pane.title).font(.system(size: 22, weight: .bold))
                    }
                    .padding(.bottom, 4)

                    detail
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 520)
        }
        .frame(width: 720, height: 520)
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .general: generalPane
        case .claude: claudePane
        case .models: modelsPane
        case .transcripts: transcriptsPane
        case .hints: hintsPane
        case .permissions: permissionsPane
        case .about: aboutPane
        }
    }

    // ---- panes ----

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(text: "System")
            SettingsCard {
                CardRow(title: "Launch at Login") {
                    Toggle("", isOn: $model.launchAtLogin)
                        .toggleStyle(.switch).tint(.blue).labelsHidden()
                }
            }
            SectionHeader(text: "Setup")
            SettingsCard {
                CardRow(title: "Run the setup assistant again",
                        subtitle: "Walks through permissions, Claude, models and folders.") {
                    Button("Restart Setup") {
                        model.onboardingDone = false
                        NSApp.keyWindow?.close()
                    }
                }
            }
        }
    }

    private var claudePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(text: "Account")
            SettingsCard {
                CardRow(title: "Status", subtitle: model.claudeStatus) {
                    StatusDot(ok: model.claudeConnected)
                }
                CardDivider()
                CardRow(title: "Authorization",
                        subtitle: "OAuth in your browser. Tokens stay on this Mac "
                                + "(~/.config/anthropic). Usage bills to your Claude account.") {
                    HStack {
                        if model.claudeBusy { ProgressView().controlSize(.small) }
                        Button("Authorize…") { model.authorizeClaude() }
                            .disabled(model.claudeBusy)
                        Button("Refresh") { model.refreshClaudeStatus() }
                    }
                }
            }
        }
    }

    private var modelsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(text: "Claude models")
            SettingsCard {
                CardRow(title: "Answers + final summary",
                        subtitle: "Interview hints and the end-of-call note.") {
                    Picker("", selection: $model.answerModel) {
                        ForEach(modelChoices, id: \.self) { Text($0) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                CardDivider()
                CardRow(title: "Rolling summary",
                        subtitle: "Runs every ~10 s during a call. "
                                + "Pick claude-haiku-4-5 to lower the cost.") {
                    Picker("", selection: $model.rollingModel) {
                        ForEach(modelChoices, id: \.self) { Text($0) }
                    }
                    .labelsHidden().frame(width: 180)
                }
            }
            SectionHeader(text: "Transcription")
            SettingsCard {
                CardRow(title: "Spoken language",
                        subtitle: "Auto lets whisper guess per chunk and can flip "
                                + "languages mid-call. Lock it if your calls are "
                                + "always in one language.") {
                    Picker("", selection: $model.sttLanguage) {
                        Text("Auto").tag("auto")
                        Text("English").tag("en")
                        Text("Русский").tag("ru")
                    }
                    .labelsHidden().frame(width: 120)
                }
            }
        }
    }

    private var transcriptsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(text: "Storage")
            SettingsCard {
                CardRow(title: "Transcript folder",
                        subtitle: model.transcriptDir) {
                    HStack {
                        Button("Choose…") { model.chooseTranscriptFolder() }
                        Button("Reveal") { model.revealTranscriptFolder() }
                    }
                }
            }
            Text("Each call gets one folder inside: audio (m4a), transcript.txt, "
                 + "summary.md and logs. Notes also go to Notion.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var hintsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(text: "During a call")
            SettingsCard {
                CardRow(title: "Live answers",
                        subtitle: "A floating window with live captions and streamed "
                                + "answers. Questions are detected automatically — "
                                + "no key press.") {
                    Toggle("", isOn: $model.hintsEnabled)
                        .toggleStyle(.switch).tint(.blue).labelsHidden()
                }
            }
        }
    }

    private var permissionsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(text: "macOS permissions")
            SettingsCard {
                CardRow(title: "Microphone",
                        subtitle: micSubtitle) {
                    HStack {
                        StatusDot(ok: model.micStatus == .authorized)
                        if model.micStatus != .authorized {
                            Button("Request") { model.requestMic() }
                        }
                    }
                }
                CardDivider()
                CardRow(title: "System Audio Recording",
                        subtitle: model.probeMessage.isEmpty
                            ? "Needed to hear the other side of the call."
                            : model.probeMessage) {
                    HStack {
                        StatusDot(ok: model.sysAudioVerified)
                        if model.probing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Test") { model.probeSystemAudio() }
                        }
                    }
                }
            }
        }
    }

    private var micSubtitle: String {
        switch model.micStatus {
        case .authorized: return "Granted."
        case .denied: return "Denied — enable it in System Settings → Privacy & Security → Microphone."
        case .restricted: return "Restricted by the system."
        default: return "Not requested yet."
        }
    }

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NerdSidekiq").font(.system(size: 16, weight: .bold))
                        Text("live hints in your interview")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
            }
            SettingsCard {
                CardRow(title: "Local transcription",
                        subtitle: "whisper.cpp on this Mac — audio never leaves the machine "
                                + "except the text sent to your own Claude account.") { EmptyView() }
            }
        }
    }
}

// MARK: - onboarding (first run)

enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, claude, model, folder, hints, done
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var step: OnboardingStep = .welcome

    private var canContinue: Bool {
        switch step {
        case .permissions:
            return model.micStatus == .authorized && model.sysAudioVerified
        case .claude:
            return model.claudeConnected
        default:
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                stepBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)

            Divider().opacity(0.5)

            // footer: dots + back / continue
            HStack {
                Button("Back") {
                    if let prev = OnboardingStep(rawValue: step.rawValue - 1) { step = prev }
                }
                .disabled(step == .welcome)

                Spacer()
                HStack(spacing: 6) {
                    ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                        Circle()
                            .fill(s == step ? Color.primary : Color.primary.opacity(0.2))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()

                if step == .done {
                    Button("Start Using NerdSidekiq") {
                        model.onboardingDone = true
                    }
                    .buttonStyle(.borderedProminent).tint(.blue)
                } else {
                    Button(step == .welcome ? "Get Started" : "Continue") {
                        if let next = OnboardingStep(rawValue: step.rawValue + 1) {
                            step = next
                            stepAppeared(next)
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(.blue)
                    .disabled(!canContinue)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 560)
        .onAppear { stepAppeared(step) }
    }

    private func stepAppeared(_ s: OnboardingStep) {
        switch s {
        case .permissions: model.refreshMicStatus()
        case .claude: model.refreshClaudeStatus()
        default: break
        }
    }

    private func header(_ icon: String, _ color: Color, _ title: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            IconBadge(icon: icon, color: color, size: 52)
            Text(title).font(.system(size: 21, weight: .bold))
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var stepBody: some View {
        switch step {
        case .welcome:
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 96, height: 96)
                Text("Welcome to NerdSidekiq").font(.system(size: 24, weight: .bold))
                Text("Records both sides of your calls, transcribes them locally, "
                     + "and streams live answer hints from your own Claude account.\n\n"
                     + "Setup takes about a minute.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        case .permissions:
            header("lock.shield.fill", .red, "Permissions",
                   "NerdSidekiq needs two macOS permissions. It cannot work without them.")
            SettingsCard {
                CardRow(title: "Microphone", subtitle: "Your side of the call.") {
                    HStack {
                        StatusDot(ok: model.micStatus == .authorized)
                        if model.micStatus != .authorized {
                            Button("Allow…") { model.requestMic() }
                        } else {
                            Text("Granted").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                CardDivider()
                CardRow(title: "System Audio Recording",
                        subtitle: model.probeMessage.isEmpty
                            ? "The other side of the call. Click Test — a short sound plays and must be captured. Allow the macOS prompt if one appears."
                            : model.probeMessage) {
                    HStack {
                        StatusDot(ok: model.sysAudioVerified)
                        if model.probing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(model.sysAudioVerified ? "Test again" : "Test") {
                                model.probeSystemAudio()
                            }
                        }
                    }
                }
            }

        case .claude:
            header("sparkles", .orange, "Connect your Claude",
                   "Answers and summaries run on your own Claude account. "
                 + "Click Authorize — your browser opens, you approve once, "
                 + "and the tokens stay on this Mac.")
            SettingsCard {
                CardRow(title: "Claude account", subtitle: model.claudeStatus) {
                    HStack {
                        StatusDot(ok: model.claudeConnected)
                        if model.claudeBusy {
                            ProgressView().controlSize(.small)
                        } else if !model.claudeConnected {
                            Button("Authorize…") { model.authorizeClaude() }
                        }
                        Button("Refresh") { model.refreshClaudeStatus() }
                    }
                }
            }

        case .model:
            header("cpu.fill", .purple, "Pick your models",
                   "You can change these later in Settings.")
            SettingsCard {
                CardRow(title: "Answers + final summary",
                        subtitle: "Interview hints and the end-of-call note.") {
                    Picker("", selection: $model.answerModel) {
                        ForEach(modelChoices, id: \.self) { Text($0) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                CardDivider()
                CardRow(title: "Rolling summary",
                        subtitle: "Every ~10 s during the call. Haiku = cheapest.") {
                    Picker("", selection: $model.rollingModel) {
                        ForEach(modelChoices, id: \.self) { Text($0) }
                    }
                    .labelsHidden().frame(width: 180)
                }
            }

        case .folder:
            header("folder.fill", .blue, "Where do transcripts go?",
                   "Each call gets one folder: audio, transcript.txt, summary.md.")
            SettingsCard {
                CardRow(title: "Transcript folder", subtitle: model.transcriptDir) {
                    Button("Choose…") { model.chooseTranscriptFolder() }
                }
            }

        case .hints:
            header("bubble.left.and.bubble.right.fill", .green, "Live answers",
                   "During a call a floating window can show live captions and "
                 + "streamed answers when the interviewer asks a question. "
                 + "Detection is automatic.")
            SettingsCard {
                CardRow(title: "Enable live answers",
                        subtitle: "You can toggle this any time in Settings.") {
                    Toggle("", isOn: $model.hintsEnabled)
                        .toggleStyle(.switch).tint(.blue).labelsHidden()
                }
            }

        case .done:
            VStack(spacing: 14) {
                IconBadge(icon: "checkmark", color: .green, size: 52)
                Text("All set").font(.system(size: 24, weight: .bold))
                Text("Click Start Call before your meeting and Finish Call after. "
                     + "Transcripts land in your folder and in Notion"
                     + (model.hintsEnabled ? "; the hint window opens automatically." : "."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
