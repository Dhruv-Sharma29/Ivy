import SwiftUI
import IvyCore

/// Proactive Ivy: the master switch, what may notify, when not to, the triggers Ivy is holding, and a log of
/// everything it did on its own initiative. Off unless the user turns it on here.
struct ProactivePanel: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var proactive: ProactiveEngine
    @State private var calendarsText = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Proactive Ivy")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Toggle("Let Ivy notify me first (reminders, heads-ups, briefing)", isOn: $settings.settings.proactiveEnabled)
                .toggleStyle(.checkbox)
            Text("Ivy can only notify or suggest. Nothing runs without your approval.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            if settings.settings.proactiveEnabled {
                options
                triggerList
                activityList
            }
            if let errorText {
                Text(errorText).font(.system(size: 10)).foregroundStyle(.red)
            }
        }
        .font(.system(size: 11))
        .onAppear { calendarsText = settings.settings.headsUpCalendars.joined(separator: ", ") }
    }

    // MARK: - Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Reminders, follow-ups and \u{201C}tell me when\u{201D}", isOn: $settings.settings.proactiveReminders)
            Toggle("Heads-up before calendar events", isOn: $settings.settings.proactiveCalendar)
            if settings.settings.proactiveCalendar {
                HStack {
                    Stepper("\(settings.settings.headsUpMinutes) min before", value: $settings.settings.headsUpMinutes, in: 1...120)
                }
                TextField("Calendars to watch (comma-separated names)", text: $calendarsText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveCalendars)
                    .onChange(of: calendarsText) { saveCalendars() }
                Text("Only these calendars, and only each event's title and start time.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Toggle("Daily briefing", isOn: $settings.settings.proactiveBriefing)
            if settings.settings.proactiveBriefing {
                timePicker("Briefing at", $settings.settings.briefingMinutes)
            }
            Toggle("Quiet hours (held for one digest afterwards)", isOn: $settings.settings.quietHoursEnabled)
            if settings.settings.quietHoursEnabled {
                HStack {
                    timePicker("From", $settings.settings.quietStartMinutes)
                    timePicker("to", $settings.settings.quietEndMinutes)
                }
            }
            Toggle("Open Ivy at login", isOn: $settings.settings.launchAtLogin)
        }
        .toggleStyle(.checkbox)
    }

    private func saveCalendars() {
        let names = calendarsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if names != settings.settings.headsUpCalendars {
            settings.settings.headsUpCalendars = names
        }
    }

    /// Minutes after midnight shown as a time of day.
    private func timePicker(_ label: String, _ minutes: Binding<Int>) -> some View {
        let date = Binding<Date>(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minutes.wrappedValue * 60)) },
            set: { new in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: new)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
        return DatePicker(label, selection: date, displayedComponents: .hourAndMinute)
            .datePickerStyle(.field)
            .controlSize(.small)
    }

    // MARK: - Triggers

    private var triggerList: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Waiting to notify you").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Watch a folder…", action: watchFolder)
                    .font(.system(size: 10))
                    .help("Notify me when something new appears in a folder I choose")
            }
            let pending = proactive.triggers.filter(\.isEnabled)
            if pending.isEmpty {
                Text("Nothing scheduled. Ask Ivy to remind you of something.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            ForEach(pending) { trigger in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(trigger.message).font(.system(size: 10)).lineLimit(2)
                        Text(Self.describe(trigger)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        proactive.remove(trigger.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                    .accessibilityLabel("Remove \(trigger.message)")
                }
            }
        }
    }

    /// The folder is always one the user picked in the open panel; Ivy never chooses it.
    private func watchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try proactive.add(ProactiveTrigger(
                kind: .watch, schedule: .whenCondition, condition: .fileAppeared(folder: url.path),
                message: "New in \(url.lastPathComponent)", createdBy: .user, createdAt: proactive.currentDate))
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    static func describe(_ trigger: ProactiveTrigger) -> String {
        switch (trigger.schedule, trigger.condition) {
        case (.at(let date), _):
            return date.formatted(date: .abbreviated, time: .shortened)
        case (.daily(let hour, let minute, _), _):
            return String(format: "Every day at %02d:%02d", hour, minute)
        case (_, .appLaunched(let app)?): return "When \(app) opens"
        case (_, .appQuit(let app)?): return "When \(app) quits"
        case (_, .batteryBelow(let percent)?): return "When the battery drops below \(percent)%"
        case (_, .fileAppeared(let folder)?): return "When something new appears in \(folder)"
        case (.whenCondition, nil): return "Waiting"
        }
    }

    // MARK: - Activity

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Recent activity").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            let recent = Array(proactive.activity.suffix(10).reversed())
            if recent.isEmpty {
                Text("Ivy hasn't spoken first yet.").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            ForEach(recent) { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.message).font(.system(size: 10)).lineLimit(2)
                    Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(Self.outcome(entry.outcome)) · \(entry.reason)")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    static func outcome(_ outcome: ProactiveActivity.Outcome) -> String {
        switch outcome {
        case .delivered: return "shown"
        case .deferred: return "held for the digest"
        case .duplicate: return "skipped (already shown)"
        case .disabled: return "skipped (turned off)"
        }
    }
}
