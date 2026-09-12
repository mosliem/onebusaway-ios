//
//  TripPlannerEndpoints.swift
//  OBAKit
//
//  Copyright © Open Transit Software Foundation
//  This source code is licensed under the Apache 2.0 license found in the
//  LICENSE file in the root directory of this source tree.
//

import CoreLocation
import MapKit
import OTPKit
import OBAKitCore

/// Converts stop / map / GPS inputs into the shapes `showTripPlanner` already
/// understands, so stop-page menus can prefill origin or destination without
/// touching `MapViewController.view`.
enum TripPlannerEndpoints {

    /// Stop title + coordinate as an `MKMapItem` suitable for the trip planner.
    static func mapItem(from stop: Stop) -> MKMapItem {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: stop.coordinate))
        mapItem.name = stop.title
        return mapItem
    }

    /// Maps a place pin into OTPKit's `Location`.
    ///
    /// The fallback title is localized, unlike the current-location one below: this
    /// one can reach the rider on any pin that arrives without a name, whereas that
    /// one is constructed here and never empty.
    static func location(from mapItem: MKMapItem) -> Location {
        Location(
            title: mapItem.name ?? OBALoc(
                "trip_planner.destination.default_title",
                value: "Destination",
                comment: "Default title for a trip planner endpoint whose map item has no name"
            ),
            subTitle: mapItem.placemark.title ?? "",
            latitude: mapItem.placemark.coordinate.latitude,
            longitude: mapItem.placemark.coordinate.longitude
        )
    }

    /// Hardcoded English titles match the existing `MapViewController` origin
    /// construction; do not expand localization here without need.
    static func location(fromCurrentLocation location: CLLocation) -> Location {
        Location(
            title: "Current Location",
            subTitle: "Your current location",
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
    }

    /// Explicit origin wins; otherwise current location is used when available.
    static func origin(explicit: MKMapItem?, currentLocation: CLLocation?) -> Location? {
        if let explicit {
            return location(from: explicit)
        }
        if let currentLocation {
            return location(fromCurrentLocation: currentLocation)
        }
        return nil
    }

    static func destination(from mapItem: MKMapItem?) -> Location? {
        mapItem.map { location(from: $0) }
    }
}
