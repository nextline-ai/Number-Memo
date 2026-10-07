import SwiftUI

struct TasteAnalysisExclusionsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var mode: TasteMode
    @State private var input = ""
    init(mode: TasteMode) { _mode = State(initialValue: mode) }
    private var tags: [String] { env.taste.control.analysisExcluded(mode).sorted() }
    var body: some View {
        Form {
            Section {
                Picker(L10n.text("Mode"), selection: $mode) {
                    Text(L10n.text("Images")).tag(TasteMode.booru)
                    Text(L10n.text("Comics")).tag(TasteMode.comics)
                }.pickerStyle(.segmented).accessibilityIdentifier("taste.exclusions.mode")
            }
            Section {
                HStack {
                    TextField(L10n.text("Tag to exclude"), text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done).onSubmit(add).accessibilityIdentifier("taste.exclusions.input")
                    Button(action: add) { Image(systemName: "plus.circle.fill").font(.title2).frame(width: 44, height: 44) }
                        .disabled(TasteControl.normalizeExclusion(input).isEmpty).accessibilityLabel(L10n.text("Add tag"))
                        .accessibilityIdentifier("taste.exclusions.add")
                }
                ForEach(tags, id: \.self) { tag in
                    HStack {
                        Text(tag).textSelection(.enabled)
                        Spacer()
                        Button { remove(tag) } label: { Image(systemName: "minus.circle").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel(L10n.text("Remove") + " " + tag)
                    }
                }.onDelete { offsets in let removed = offsets.map { tags[$0] }; env.taste.change { $0.setAnalysisExcluded(Set(tags).subtracting(removed), mode: mode) } }
            } footer: {
                Text(L10n.text("Excluded tags are removed from taste evidence immediately. Your current works stay in place; refresh to find new recommendations. Original tags and search filters stay available."))
            }
        }.navigationTitle(L10n.text("Analysis excluded tags"))
            .navigationBarTitleDisplayMode(.inline)
    }
    private func add() {
        let value = TasteControl.normalizeExclusion(input)
        guard !value.isEmpty else { return }
        env.taste.change { $0.setAnalysisExcluded(Set(tags).union([value]), mode: mode) }; input = ""
    }
    private func remove(_ tag: String) { env.taste.change { $0.setAnalysisExcluded(Set(tags).subtracting([tag]), mode: mode) } }
}
