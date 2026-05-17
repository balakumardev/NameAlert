import SwiftUI

struct KeywordsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engine: ListeningEngine
    @State private var newKeyword: String = ""

    var body: some View {
        Form {
            Section("Keywords") {
                List {
                    ForEach(Array(settings.keywords.enumerated()), id: \.offset) { _, word in
                        Text(word)
                    }
                    .onDelete(perform: delete)
                }
                .frame(minHeight: 120)
                HStack {
                    TextField("Add keyword", text: $newKeyword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Matching") {
                Stepper("Fuzzy tolerance: \(settings.fuzzyTolerance) edit\(settings.fuzzyTolerance == 1 ? "" : "s")",
                        value: $settings.fuzzyTolerance, in: 0...3)
                    .onChange(of: settings.fuzzyTolerance) { _, _ in refresh() }
                HStack {
                    Text("Per-keyword cooldown")
                    Slider(value: $settings.perKeywordCooldown, in: 1...60, step: 1)
                    Text("\(Int(settings.perKeywordCooldown))s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .onChange(of: settings.perKeywordCooldown) { _, _ in refresh() }
                HStack {
                    Text("Global cooldown")
                    Slider(value: $settings.globalCooldown, in: 0...30, step: 1)
                    Text("\(Int(settings.globalCooldown))s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .onChange(of: settings.globalCooldown) { _, _ in refresh() }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func add() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return }
        var current = settings.keywords
        guard !current.contains(trimmed) else { newKeyword = ""; return }
        current.append(trimmed)
        settings.keywords = current
        newKeyword = ""
        refresh()
    }

    private func delete(at offsets: IndexSet) {
        var current = settings.keywords
        current.remove(atOffsets: offsets)
        settings.keywords = current
        refresh()
    }

    private func refresh() {
        Task { await engine.refreshConfiguration() }
    }
}
