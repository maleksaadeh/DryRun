import SwiftUI

/// Adds or edits one user-entered colour.
///
/// Two fields are required and the second one is the reason this form exists at all: a hex alone
/// does not describe a paint. The swatch supplies the hue, the LRV supplies the lightness, and the
/// renderer trusts the LRV — so a colour saved with a guessed LRV renders the right hue at the
/// wrong lightness, which is precisely the error the whole colour pipeline was built to avoid.
/// The field is therefore mandatory, with no derived default offered: a pre-filled estimate would
/// be accepted unread by most people, and it is wrong by 25–30% on exactly the deep, saturated
/// colours someone is most likely to want to add.
struct CustomColorForm: View {

    /// The colour being edited, or `nil` when adding.
    let existing: PaintColor?
    let store: CustomPaintStore

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var code: String
    @State private var hexText: String
    @State private var lrvText: String
    @State private var confirmingDelete = false

    init(existing: PaintColor? = nil, store: CustomPaintStore) {
        self.existing = existing
        self.store = store
        _name = State(initialValue: existing?.name ?? "")
        _code = State(initialValue: existing?.code ?? "")
        // A mid-tone default: starting on white makes the preview look empty, and starting on a
        // saturated colour suggests the picker is where the work happens.
        _hexText = State(initialValue: (existing?.hex ?? 0xC9C4BA).hexString)
        _lrvText = State(initialValue: existing.map { String(format: "%.1f", $0.lrv) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { preview }

                Section("Colour") {
                    TextField("Name", text: $name)
                    TextField("Code (optional)", text: $code)
                        .autocorrectionDisabled()
                }

                Section {
                    ColorPicker("Pick a colour", selection: pickerBinding, supportsOpacity: false)
                    LabeledContent("Hex") {
                        TextField("#RRGGBB", text: $hexText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(parsedHex == nil ? Color.red : Color.primary)
                    }
                } footer: {
                    Text("The swatch sets the hue and saturation only. It does not decide how light the colour renders.")
                }

                Section {
                    LabeledContent("LRV") {
                        TextField("0–100", text: $lrvText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(lrvText.isEmpty || parsedLRV != nil ? Color.primary : Color.red)
                    }
                } header: {
                    Text("Light Reflectance Value")
                } footer: {
                    Text("Required. It sets how light the colour renders, and it is what lets a pale colour read pale over a dark wall. Manufacturers publish it on each colour's page, and it is printed on fan-deck chips.")
                }

                if existing != nil {
                    Section {
                        Button("Delete Colour", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Colour" : "Edit Colour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!isValid)
                }
            }
            .confirmationDialog("Delete this colour?",
                                isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let existing { store.delete(existing) }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Preview

    /// The chip as it will appear in the swatch row, at the size it appears there.
    ///
    /// Showing the real size rather than a large block is the point: this is the thing the user
    /// will have to recognise later in a row of chips, and a colour that is distinctive at 200pt
    /// can be indistinguishable from its neighbour at 58.
    private var preview: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: parsedHex ?? 0xC9C4BA))
                .frame(width: 58, height: 58)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.primary.opacity(0.2), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(trimmedName.isEmpty ? "Unnamed" : trimmedName)
                    .font(.headline)
                    .foregroundStyle(trimmedName.isEmpty ? .secondary : .primary)
                if !trimmedCode.isEmpty {
                    Text(trimmedCode).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text(parsedLRV.map { String(format: "LRV %.1f", $0) } ?? "LRV needed")
                    .font(.caption.monospaced())
                    .foregroundStyle(parsedLRV == nil ? .orange : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Values

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedHex: UInt32? { UInt32(hexString: hexText) }

    /// The typed LRV, or nil if it is not a number in range.
    ///
    /// Rejects 0 as well as out-of-range values. An LRV of exactly 0 is a surface that reflects no
    /// light at all, which no paint is, and it would render the wall pure black — much more likely
    /// a half-finished entry than an intent.
    private var parsedLRV: Float? {
        guard let value = Float(lrvText.trimmingCharacters(in: .whitespaces)),
              value > 0, value <= 100 else { return nil }
        return value
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
            && parsedHex != nil
            && parsedLRV != nil
            && !store.isNameTaken(trimmedName, excluding: existing?.id)
    }

    /// Reads and writes `hexText`, so the picker and the field are one value rather than two that
    /// have to be kept in step.
    private var pickerBinding: Binding<Color> {
        Binding(
            get: { Color(hex: parsedHex ?? 0xC9C4BA) },
            set: { hexText = $0.hexValue.hexString }
        )
    }

    private func save() {
        guard let hex = parsedHex, let lrv = parsedLRV else { return }
        // Editing keeps the original id, so a colour currently selected on the wall stays selected
        // through the edit instead of being replaced by a stranger with the same name.
        store.save(PaintColor(id: existing?.id ?? UUID().uuidString,
                              name: trimmedName,
                              code: trimmedCode,
                              hex: hex,
                              lrv: lrv,
                              isCustom: true))
        dismiss()
    }
}

#Preview {
    CustomColorForm(store: CustomPaintStore())
}
