import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// How the settings panes change the configuration. Every change goes through `ListeningController.update`, which
/// runs one command at a time in the order they were asked for, so changes made one after another land in that order
/// and a change is always made to the latest configuration, never to a copy a pane read earlier.
extension ListeningController {
    /// Changes the configuration. Returns at once; the change is made in its turn.
    func edit(_ change: @escaping @Sendable (inout AppConfiguration) -> Void) {
        Task { await update(change) }
    }

    /// Changes one rule. Nothing happens if the rule is gone by the time the change runs.
    func edit(rule id: Rule.ID, _ change: @escaping @Sendable (inout Rule) -> Void) {
        edit { configuration in
            guard let index = configuration.rules.firstIndex(where: { $0.id == id }) else { return }
            change(&configuration.rules[index])
        }
    }

    /// A binding to one setting: it shows the current value and changes it through `edit`.
    func binding<Value: Sendable & Equatable>(
        _ keyPath: WritableKeyPath<AppConfiguration, Value> & Sendable
    ) -> Binding<Value> {
        Binding(
            get: { self.configuration[keyPath: keyPath] },
            set: { value in self.edit { $0[keyPath: keyPath] = value } })
    }

    /// Waits until every change made so far with `edit` has been made. The empty change is a task of its own, started
    /// after the tasks of the changes before it, so it takes the last place in the line of commands.
    func finishPendingEdits() async {
        await Task { await update { _ in } }.value
    }
}

extension Rule {
    /// Adds words the rule does not have yet (ignoring case): two quick additions must not repeat a word.
    mutating func addTerms(_ new: [String]) {
        var known = Set(terms.map { $0.lowercased() })
        for term in new where known.insert(term.lowercased()).inserted {
            terms.append(term)
        }
    }
}
