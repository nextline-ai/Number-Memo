import SwiftUI

struct ChallengeEditorView: View {
    @State var game: ChallengeDefinition
    let store: ChallengeStore
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var preview: ChallengeSessionController?
    @State private var confirmDiscard = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(L10n.text("Make it yours in three steps"), systemImage: "wand.and.stars")
                        .font(.headline).foregroundStyle(.purple)
                    Text(L10n.text("Start with a ready-to-play example. Add a title, change the choices, and choose a goal."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }.listRowBackground(Color.purple.opacity(0.06))
                Section {
                    TextField(L10n.text("Title"), text: $game.title).accessibilityIdentifier("challenge.title")
                    TextField(L10n.text("Game Instructions"), text: $game.detail, axis: .vertical)
                        .lineLimit(3...6).accessibilityIdentifier("challenge.instructions")
                    NavigationLink {
                        ChallengeHelpEditor(pages: Binding(get: { game.helpPages ?? [] }, set: { game.helpPages = $0 }))
                    } label: {
                        LabeledContent(L10n.text("Help Tabs"), value: "\(game.helpPages?.count ?? 0)")
                    }.accessibilityIdentifier("challenge.editHelp")
                } header: { Text(L10n.text("1. Introduce Your Game")) }
                footer: { Text(L10n.text("Explain how to play. These instructions appear before and during the game and are included in backups.")) }
                Section {
                    ForEach($game.reels) { $group in
                        NavigationLink { ChallengeGroupEditor(group: $group) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.title).font(.headline)
                                Text(group.options.prefix(4).map(\.text).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.padding(.vertical, 4)
                        }
                    }
                } header: { Text(L10n.text("2. Choose What to Draw")) }
                footer: { Text(L10n.text("One choice is drawn from each list. Tap a list to type, paste, or reorder choices.")) }
                Section {
                    Picker(L10n.text("Goal Type"), selection: $game.goal.mode) {
                        ForEach(ChallengeGoalRule.Mode.allCases, id: \.self) { Text(L10n.text($0.rawValue.capitalized)).tag($0) }
                    }.accessibilityIdentifier("challenge.goalMode")
                    if game.goal.mode != .count {
                        NavigationLink { ChallengeRangeEditor(value: $game.goal.time, limit: 86400, title: "Time Range (Seconds)") } label: {
                            LabeledContent(L10n.text("Time Range (Seconds)"), value: "\(game.goal.time.minimum)…\(game.goal.time.maximum)")
                        }
                    }
                    if game.goal.mode != .time {
                        NavigationLink { ChallengeRangeEditor(value: $game.goal.count, limit: 10000, title: "Count Range") } label: {
                            LabeledContent(L10n.text("Count Range"), value: "\(game.goal.count.minimum)…\(game.goal.count.maximum)")
                        }
                    }
                } header: { Text(L10n.text("3. Set a Goal")) }
                footer: { Text(L10n.text("Finish each mission yourself to earn points. The default scoring and endings are ready to use.")) }
                Section {
                    Button(L10n.text("Preview Challenge"), systemImage: "play.circle.fill", action: openPreview)
                        .accessibilityIdentifier("challenge.preview")
                    NavigationLink { advanced } label: {
                        Label(L10n.text("Advanced Rules"), systemImage: "slider.horizontal.3")
                    }.accessibilityIdentifier("challenge.advanced")
                } footer: { Text(L10n.text("Optional: customize mission text, supporting groups, probabilities, points, and endings.")) }
            }
            .tint(.purple)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(L10n.text("Edit Challenge")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { confirmDiscard = true } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openPreview) { Image(systemName: "play.circle") }
                        .accessibilityLabel(L10n.text("Preview Challenge")).accessibilityIdentifier("challenge.previewTop")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Save")) {
                        do { try store.save(game); dismiss() } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("challenge.save")
                }
            }
            .sheet(item: $preview) { preview in NavigationStack { ChallengePreviewView(controller: preview) } }
            .alert(L10n.text("Discard Changes?"), isPresented: $confirmDiscard) {
                Button(L10n.text("Discard"), role: .destructive) { dismiss() }
                Button(L10n.text("Cancel"), role: .cancel) {}
            }
            .challengeError($error)
        }.interactiveDismissDisabled()
    }
    private var advanced: some View {
        Form {
            Section(L10n.text("Supporting Groups")) {
                ForEach($game.groups) { $group in
                    NavigationLink { ChallengeGroupEditor(group: $group) } label: { LabeledContent(group.title, value: String(group.options.count)) }
                }.onDelete { game.groups.remove(atOffsets: $0) }
                    .onMove { game.groups.move(fromOffsets: $0, toOffset: $1) }
                Button(L10n.text("Add Supporting Group")) {
                    game.groups.append(.init(title: L10n.text("Supporting Group"), options: [.init(text: L10n.text("New Option"))]))
                }.disabled(game.groups.count >= 12)
            }
                Section(L10n.text("Mission Text")) {
                    TextEditor(text: $game.template).frame(minHeight: 100).accessibilityIdentifier("challenge.template")
                    ScrollView(.horizontal) {
                        HStack { ForEach(game.variables, id: \.self) { variable in
                            Button(variableTitle(variable)) { game.template += "{\(variable)}" }.buttonStyle(.bordered)
                        } }
                    }
                    Text(L10n.text("Tap a variable to insert a drawn value. Supporting groups use their current order."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            if game.goal.mode == .mixed {
                Section(L10n.text("Goal Probability")) {
                    ChallengeNumberField(title: "Time Weight", value: $game.goal.timeWeight)
                    ChallengeNumberField(title: "Count Weight", value: $game.goal.countWeight)
                }
            }
                Section(L10n.text("Scoring")) {
                    ChallengeNumberField(title: "Target Score", value: $game.target)
                    Picker(L10n.text("Score Multiplier"), selection: $game.multiplier) {
                        ForEach([0.5, 1, 1.5, 2], id: \.self) { Text("\($0, specifier: "%.1f")×").tag($0) }
                    }
                    ForEach($game.bands) { $band in
                        NavigationLink {
                            Form {
                                ChallengeNumberField(title: "Through Score", value: $band.through)
                                ChallengeNumberField(title: "Minimum", value: $band.minimum)
                                ChallengeNumberField(title: "Maximum", value: $band.maximum)
                            }.navigationTitle(L10n.text("Score Band"))
                        } label: { Text("≤ \(band.through): +\(band.minimum)…\(band.maximum)") }
                    }.onDelete { game.bands.remove(atOffsets: $0) }
                    .onMove { game.bands.move(fromOffsets: $0, toOffset: $1) }
                    Button(L10n.text("Add Score Band")) { game.bands.append(.init(through: min(100000, (game.bands.last?.through ?? 0) + 100), minimum: 1, maximum: 5)) }
                    Text(L10n.text("Bands must increase and cover the target score. Points use the score before completion."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.text("Endings")) {
                    Picker(L10n.text("Final Result"), selection: $game.fixedEndingID) {
                        Text(L10n.text("Random")).tag(nil as String?)
                        ForEach(game.endings) { Text($0.title).tag(Optional($0.id)) }
                    }
                    ForEach($game.endings) { $ending in
                        NavigationLink { ChallengeEndingEditor(ending: $ending) } label: { Text(ending.title) }
                    }.onDelete { offsets in
                        let ids = offsets.map { game.endings[$0].id }
                        if let fixed = game.fixedEndingID, ids.contains(fixed) { game.fixedEndingID = nil }
                        game.endings.remove(atOffsets: offsets)
                    }.onMove { game.endings.move(fromOffsets: $0, toOffset: $1) }
                    Button(L10n.text("Add Ending")) { game.endings.append(.init(title: L10n.text("New Ending"), detail: "", badge: "★")) }
                }
        }.navigationTitle(L10n.text("Advanced Rules")).toolbar { EditButton() }
    }
    private func variableTitle(_ variable: String) -> String {
        if variable == "goal" { return L10n.text("Goal") }
        if variable == "reel1" { return game.reels[0].title }
        if variable == "reel2" { return game.reels[1].title }
        if let index = Int(variable.replacingOccurrences(of: "extra", with: "")), game.groups.indices.contains(index - 1) { return game.groups[index - 1].title }
        return variable
    }
    private func openPreview() {
        do { preview = try ChallengeSessionController(game: game) }
        catch { self.error = error.localizedDescription }
    }
}

struct ChallengeNumberField: View {
    let title: String
    @Binding var value: Int
    var body: some View {
        HStack {
            Text(L10n.text(title)); Spacer()
            TextField(L10n.text(title), value: $value, format: .number).keyboardType(.numberPad)
                .multilineTextAlignment(.trailing).frame(minWidth: 70, maxWidth: 120)
        }
    }
}

private struct ChallengeRangeEditor: View {
    @Binding var value: ChallengeRange
    let limit: Int
    let title: String
    var body: some View {
        Form {
            Section {
                Text(value.minimum == value.maximum ? String(value.minimum) : "\(value.minimum)…\(value.maximum)")
                    .font(.largeTitle.monospacedDigit().bold()).foregroundStyle(.purple)
                Text(L10n.text("Choose a fixed goal below, or customize a random range."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section(L10n.text("Quick Goals")) {
                ForEach(limit == 86400 ? [30, 60, 90, 120] : [1, 5, 10, 20], id: \.self) { goal in
                    Button {
                        value = .init(minimum: goal, maximum: goal)
                    } label: {
                        HStack {
                            Text(ChallengeMission.goalText(kind: limit == 86400 ? .time : .count, value: goal))
                            Spacer()
                            if value.minimum == goal && value.maximum == goal { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Section {
                DisclosureGroup(L10n.text("Custom Goal Range")) {
                    ChallengeNumberField(title: "Minimum", value: $value.minimum)
                    ChallengeNumberField(title: "Maximum", value: $value.maximum)
                    ChallengeNumberField(title: "Step", value: $value.step)
                }
                if !value.validate(limit: limit) { Text(L10n.text("Use a positive range with evenly spaced steps.")).foregroundStyle(.red) }
            }
        }.navigationTitle(L10n.text(title))
    }
}

private struct ChallengeGroupEditor: View {
    @Binding var group: ChallengeGroup
    @State private var lines = ""
    var body: some View {
        Form {
            Section {
                TextField(L10n.text("Title"), text: $group.title)
                DisclosureGroup(L10n.text("Advanced Rules")) {
                    TextField(L10n.text("Group Filter (Empty = All)"), text: $group.filter)
                }
            }
            Section(L10n.text("Options")) {
                ForEach($group.options) { $option in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(L10n.text("Text"), text: $option.text, axis: .vertical)
                        DisclosureGroup {
                            TextField(L10n.text("Search Tags"), text: Binding(get: { option.tags.joined(separator: " ") }, set: { option.tags = $0.split(whereSeparator: \.isWhitespace).map(String.init) }))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Text(L10n.text("Use space-separated tags. Rating and servers are chosen when playing.")).font(.caption).foregroundStyle(.secondary)
                            TextField(L10n.text("Group"), text: $option.group)
                            Toggle(L10n.text("Enabled"), isOn: $option.enabled)
                            ChallengeNumberField(title: "Weight", value: $option.weight)
                        } label: {
                            Label(L10n.text("Tags and Probability"), systemImage: option.enabled ? "slider.horizontal.3" : "eye.slash")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button(L10n.text("Duplicate")) { var copy = option; copy.id = UUID().uuidString; group.options.append(copy) }
                    }
                }.onDelete { group.options.remove(atOffsets: $0) }
                .onMove { group.options.move(fromOffsets: $0, toOffset: $1) }
                Button(L10n.text("Add Option")) { group.options.append(.init(text: L10n.text("New Option"))) }
            }
            Section(L10n.text("Add Multiple Options")) {
                TextField(L10n.text("One choice per line"), text: $lines, axis: .vertical).lineLimit(3...8)
                Button(L10n.text("Add Lines")) {
                    let values = lines.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    group.options += values.map { .init(text: $0) }; lines = ""
                }.disabled(lines.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.navigationTitle(group.title).toolbar { EditButton() }
    }
}

private struct ChallengeEndingEditor: View {
    @Binding var ending: ChallengeEnding
    var body: some View {
        Form {
            TextField(L10n.text("Title"), text: $ending.title)
            TextField(L10n.text("Description"), text: $ending.detail, axis: .vertical)
            TextField(L10n.text("Badge"), text: $ending.badge)
            Picker(L10n.text("Color"), selection: $ending.color) {
                ForEach(ChallengeEnding.colors, id: \.self) { Text(L10n.text($0.capitalized)).tag($0) }
            }
            ChallengeNumberField(title: "Weight", value: $ending.weight)
            ChallengeEndingCard(ending: ending)
        }.navigationTitle(L10n.text("Edit Ending"))
    }
}


private struct ChallengeHelpEditor: View {
    @Binding var pages: [ChallengeHelpPage]
    var body: some View {
        Form {
            Section {
                ForEach($pages) { $page in
                    NavigationLink {
                        Form {
                            TextField(L10n.text("Tab Title"), text: $page.title)
                            Section(L10n.text("Game Instructions")) {
                                TextEditor(text: $page.body).frame(minHeight: 240)
                                    .accessibilityIdentifier("challenge.helpBody")
                            }
                        }.navigationTitle(L10n.text("Edit Help Tab"))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(page.title.isEmpty ? L10n.text("New Help Tab") : page.title)
                            Text(page.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }.onDelete { pages.remove(atOffsets: $0) }.onMove { pages.move(fromOffsets: $0, toOffset: $1) }
                Button(L10n.text("Add Help Tab"), systemImage: "plus") {
                    pages.append(.init(title: L10n.text("New Help Tab"), body: ""))
                }.disabled(pages.count >= 12).accessibilityIdentifier("challenge.addHelp")
            } footer: {
                Text(L10n.text("Each page becomes a tab in How to Play. The game instructions appear first when filled in. Add rules, tips, or a glossary."))
            }
        }.navigationTitle(L10n.text("Help Tabs"))
            .toolbar { EditButton() }
    }
}
