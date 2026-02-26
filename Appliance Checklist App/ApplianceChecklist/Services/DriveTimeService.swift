import CoreLocation
import MapKit
import SwiftUI

/// Fetches estimated drive time from home address to destination using Apple Maps (MapKit).
@MainActor
class DriveTimeService: ObservableObject {

    static let homeAddressKey = "app.homeAddress"

    @Published var homeAddress: String
    @Published var isFetching = false
    @Published var lastError: String?

    init() {
        self.homeAddress = UserDefaults.standard.string(forKey: Self.homeAddressKey) ?? ""
    }

    func saveHomeAddress() {
        UserDefaults.standard.set(homeAddress, forKey: Self.homeAddressKey)
    }

    /// Returns estimated drive time in minutes from home to destination address, or nil on failure.
    func fetchDriveTimeMinutes(from originAddress: String, to destinationAddress: String) async -> Int? {
        guard !originAddress.isEmpty, !destinationAddress.isEmpty else {
            lastError = "Need both addresses"
            return nil
        }

        isFetching = true
        lastError = nil
        defer { isFetching = false }

        let geocoder = CLGeocoder()

        do {
            let originPlacemarks = try await geocoder.geocodeAddressString(originAddress)
            let destPlacemarks = try await geocoder.geocodeAddressString(destinationAddress)

            guard let originPlacemark = originPlacemarks.first,
                  let destPlacemark = destPlacemarks.first,
                  let originLocation = originPlacemark.location,
                  let destLocation = destPlacemark.location else {
                lastError = "Could not find location for one or both addresses"
                return nil
            }

            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(placemark: originPlacemark))
            request.destination = MKMapItem(placemark: MKPlacemark(placemark: destPlacemark))
            request.transportType = .automobile

            let directions = MKDirections(request: request)
            let response = try await directions.calculate()

            guard let route = response.routes.first else {
                lastError = "No route found"
                return nil
            }

            let minutes = Int(route.expectedTravelTime / 60)
            return max(1, minutes) // at least 1 min
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Fetches drive time from stored home address to destination. Returns nil if home not set.
    func fetchDriveTimeTo(destinationAddress: String) async -> Int? {
        guard !homeAddress.isEmpty else {
            lastError = "Set your home address first in the form"
            return nil
        }
        return await fetchDriveTimeMinutes(from: homeAddress, to: destinationAddress)
    }
}
