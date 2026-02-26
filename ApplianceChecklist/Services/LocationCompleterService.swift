import MapKit
import SwiftUI

/// Wraps MKLocalSearchCompleter to provide place/address suggestions for SwiftUI.
@MainActor
final class LocationCompleterService: NSObject, ObservableObject {

    @Published var completions: [MKLocalSearchCompletion] = []
    @Published var isSearching = false

    private let completer = MKLocalSearchCompleter()
    private var currentQuery: String = ""

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Update search query; results arrive asynchronously via delegate.
    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        currentQuery = trimmed
        if trimmed.isEmpty {
            completions = []
            isSearching = false
            return
        }
        isSearching = true
        completer.queryFragment = trimmed
    }

    /// Resolve a completion to a full address string (title + subtitle).
    func addressString(for completion: MKLocalSearchCompletion) -> String {
        let title = completion.title
        let subtitle = completion.subtitle
        if subtitle.isEmpty { return title }
        return "\(title), \(subtitle)"
    }

    /// Cancel current search and clear results.
    func cancel() {
        completer.cancel()
        completions = []
        isSearching = false
    }
}

extension LocationCompleterService: MKLocalSearchCompleterDelegate {

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            completions = completer.results
            isSearching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            completions = []
            isSearching = false
        }
    }
}
