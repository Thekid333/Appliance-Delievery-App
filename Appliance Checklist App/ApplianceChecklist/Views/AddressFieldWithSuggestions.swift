import MapKit
import SwiftUI

/// A text field that shows place/address suggestions in a tappable dropdown as you type.
struct AddressFieldWithSuggestions: View {
    @Binding var text: String
    var placeholder: String
    @StateObject private var completer = LocationCompleterService()
    @State private var justSelectedSuggestion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: $text)
                .textContentType(.fullStreetAddress)
                .onChange(of: text) { _, newValue in
                    if justSelectedSuggestion {
                        justSelectedSuggestion = false
                        return
                    }
                    completer.search(query: newValue)
                }

            if !completer.completions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(completer.completions.prefix(5).enumerated()), id: \.offset) { _, completion in
                        Button {
                            justSelectedSuggestion = true
                            text = completer.addressString(for: completion)
                            completer.cancel()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(completion.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                if !completion.subtitle.isEmpty {
                                    Text(completion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 6)
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var address = ""
        var body: some View {
            Form {
                Section("Address") {
                    AddressFieldWithSuggestions(text: $address, placeholder: "Address")
                }
            }
        }
    }
    return PreviewWrapper()
}
