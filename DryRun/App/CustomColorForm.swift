import SwiftUI

/// Adds or edits one user-entered color.
///
/// The LRV is required and no default is offered: a guessed one renders the right hue at the wrong
/// lightness, which is the error the color pipeline exists to avoid.
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

    /// The chip at the size it appears in the swatch row.
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

    /// The typed LRV, or nil if it is not a number in 0 < lrv <= 100.
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

    /// Reads and writes `hexText`, so the picker and the field are one value rather than two.
    private var pickerBinding: Binding<Color> {
        Binding(
            get: { Color(hex: parsedHex ?? 0xC9C4BA) },
            set: { hexText = $0.hexValue.hexString }
        )
    }

    private func save() {
        guard let hex = parsedHex, let lrv = parsedLRV else { return }
        // Editing keeps the original id, so a colour selected on the wall stays selected.
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
