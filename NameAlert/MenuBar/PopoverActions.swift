import AppKit
import Foundation
import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// Snooze, and "Add keyword" with its inline field: a new keyword becomes a rule of its own with Sound and
/// Notification alerts.
struct PopoverActions: View {
    @Environment(ListeningController.self) private var controller
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isAddingKeyword: Bool
    @State private var isShowingRuleLimit: Bool
    @State private var draft = ""
    @State private var lastAdded: String?
    @FocusState private var isFieldFocused: Bool

    /// `isAddingKeyword` opens the field from the start, and `isShowingRuleLimit` the note about Free's rules, for renders.
    init(isAddingKeyword: Bool = false, isShowingRuleLimit: Bool = false) {
        _isAddingKeyword = State(initialValue: isAddingKeyword)
        _isShowingRuleLimit = State(initialValue: isShowingRuleLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SnoozeMenu()
                Spacer(minLength: 8)
                Button(action: addKeywordTapped) {
                    Label("Add keyword", systemImage: "plus")
                }
                .accessibilityLabel(isAddingKeyword ? "Close the new keyword field" : "Add a keyword")
            }
            .buttonStyle(.bordered)

            if isShowingRuleLimit {
                ruleLimitNote
            } else if isAddingKeyword {
                keywordField
            } else if let lastAdded {
                Label {
                    Text(verbatim: "Added “\(lastAdded)”")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .task(id: lastAdded) {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { self.lastAdded = nil }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var keywordField: some View {
        HStack(spacing: 8) {
            TextField("Name or phrase", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(addKeyword)
                .onExitCommand { setAddingKeyword(false) }
                .accessibilityLabel("New keyword")
            Button("Add", action: addKeyword)
                .buttonStyle(.borderedProminent)
                .disabled(Self.keyword(from: draft) == nil)
                .accessibilityLabel("Add this keyword")
        }
        .onAppear { isFieldFocused = true }
    }

    /// Free has its most rules: a new keyword would be a rule that does not alert.
    private var ruleLimitNote: some View {
        NoticeRow(systemImage: "lock.fill", tint: .accentColor, message: ProCopy.popoverRuleLimit) {
            Button(ProCopy.seeProTitle) {
                router?.openSettings(at: .pro)
                dismiss()
            }
            .accessibilityLabel("See Pro in Settings")
        }
    }

    private func addKeywordTapped() {
        if isAddingKeyword || isShowingRuleLimit {
            isShowingRuleLimit = false
            setAddingKeyword(false)
        } else if controller.proPolicy.canAddRule(to: controller.configuration.rules) {
            setAddingKeyword(true)
        } else {
            isShowingRuleLimit = true
        }
    }

    private func setAddingKeyword(_ adding: Bool) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            isAddingKeyword = adding
            if adding { lastAdded = nil } else { draft = "" }
        }
    }

    private func addKeyword() {
        guard let keyword = Self.keyword(from: draft) else { return }
        let rule = Rule(name: keyword, terms: [keyword])
        setAddingKeyword(false)
        Task {
            if await controller.addRule(rule) {
                lastAdded = keyword
            } else {
                isShowingRuleLimit = true
            }
        }
    }

    /// The keyword typed in `text`: trimmed, with runs of spaces made single; `nil` when there is none.
    static func keyword(from text: String) -> String? {
        let keyword = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return keyword.isEmpty ? nil : keyword
    }
}

/// Snooze for 15 minutes, an hour, or until tomorrow morning; "Resume now" while snoozed.
struct SnoozeMenu: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        Menu {
            Button("15 minutes") { snooze(minutes: 15) }
            Button("1 hour") { snooze(minutes: 60) }
            Button(SnoozeChoice.untilMorningTitle(now: Date())) {
                snooze(minutes: SnoozeChoice.minutesUntilMorning(after: Date()))
            }
            if case .snoozed = controller.state {
                Divider()
                Button("Resume now") { Task { await controller.resume() } }
            }
        } label: {
            Label("Snooze", systemImage: "moon.zzz")
        }
        .menuStyle(.button)
        .fixedSize()
        .accessibilityLabel("Snooze alerts")
    }

    private func snooze(minutes: Int) {
        Task { await controller.snooze(minutes: minutes) }
    }
}

/// The "until tomorrow morning" snooze: until the next 9:00 on this Mac's clock.
enum SnoozeChoice {
    static let morningHour = 9

    /// The next 9:00 after `now`: later today when it is not 9:00 yet, else tomorrow.
    static func nextMorning(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: now, matching: DateComponents(hour: morningHour, minute: 0, second: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(24 * 60 * 60)
    }

    /// Whole minutes from `now` until the next 9:00, rounded up.
    static func minutesUntilMorning(after now: Date, calendar: Calendar = .current) -> Int {
        let seconds = nextMorning(after: now, calendar: calendar).timeIntervalSince(now)
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    /// "Until tomorrow 9:00", or "Until 9:00" before 9:00.
    static func untilMorningTitle(now: Date, calendar: Calendar = .current) -> String {
        let morning = nextMorning(after: now, calendar: calendar)
        let time = morning.formatted(date: .omitted, time: .shortened)
        return calendar.isDate(morning, inSameDayAs: now) ? "Until \(time)" : "Until tomorrow \(time)"
    }
}

/// Settings, History and Quit, along the bottom like the end of a menu.
struct PopoverFooter: View {
    @Environment(WindowRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 4) {
            Button("Settings…") { open(.settings) }
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityLabel("Open Settings")
            Button("History…") { open(.history) }
                .accessibilityLabel("Open History")
            Spacer(minLength: 8)
            Button("Quit \(AppInfo.displayName)") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .accessibilityLabel("Quit \(AppInfo.displayName)")
        }
        .buttonStyle(RowButtonStyle())
        .padding(8)
    }

    private func open(_ destination: WindowRouter.Destination) {
        router.open(destination)
        dismiss()
    }
}
