//
//  SheetRoute.swift
//  OBAKit
//
//  Copyright © Open Transit Software Foundation
//  This source code is licensed under the Apache 2.0 license found in the
//  LICENSE file in the root directory of this source tree.
//

import SwiftUI
import MapKit
import OBAKitCore
import OTPKit

// MARK: - TripPlannerRequest

/// Parameters for initiating the OTPKit trip planner.
///
/// Both map-item and rental entry points carry payloads to prefill planner state:
/// a map item prefills the destination and leaves the mode open; a rental (later)
/// prefills a via point and locks the mode. All fields are optional so the planner
/// can open empty (all three `nil`), with partial prefill, or fully configured.
nonisolated struct TripPlannerRequest: Hashable, Equatable {
    /// Origin pin, if the entry point knows where the trip starts. Nil leaves the
    /// planner to seed the rider's current location, which is the usual case —
    /// only "Directions from Here" on the stop page fills this in.
    let origin: MKMapItem?

    /// Destination pin on the map, if prefilled by the entry point (e.g., a
    /// tapped map item). The planner uses this to seed the destination field.
    let destination: MKMapItem?

    /// Intermediate point every planned trip must pass through — "plan a trip using
    /// this bike" passes the vehicle's location. `CLLocationCoordinate2D` is not
    /// `Hashable` or `Equatable`, so both are implemented over latitude/longitude.
    let viaPoint: CLLocationCoordinate2D?

    /// Transport mode to preselect or lock. The rental entry point pins this to
    /// `.transitBikeRental`, because OTP will not route through a via point in a
    /// rental-only mode. Every other entry point leaves it `nil` so the rider picks.
    let transportMode: TransportMode?

    /// Initializer with all parameters optional, defaulting to `nil`.
    init(
        origin: MKMapItem? = nil,
        destination: MKMapItem? = nil,
        viaPoint: CLLocationCoordinate2D? = nil,
        transportMode: TransportMode? = nil
    ) {
        // A trip from a place to itself is not a trip. No entry point can build one
        // — each sets exactly one end — so this catches a future caller wiring the
        // same pin into both, which OTP would answer with an empty itinerary and no
        // explanation. Debug-only: a bad prefill is not worth crashing a rider over.
        assert(
            !TripPlannerRequest.sameplace(origin, destination) || origin == nil,
            "TripPlannerRequest origin and destination are the same place"
        )

        self.origin = origin
        self.destination = destination
        self.viaPoint = viaPoint
        self.transportMode = transportMode
    }

    /// Hashes an optional pin by coordinate, matching `AppSheetRoute.mapItem`.
    /// `MKMapItem` is a reference type, so identity would make two requests for
    /// the same place unequal.
    private static func combine(_ mapItem: MKMapItem?, into hasher: inout Hasher) {
        guard let mapItem else {
            hasher.combine(NSNull())
            return
        }
        let coordinate = mapItem.placemark.coordinate
        hasher.combine(coordinate.latitude)
        hasher.combine(coordinate.longitude)
    }

    /// Coordinate equality for two optional pins, nil-equal-nil included.
    private static func sameplace(_ lhs: MKMapItem?, _ rhs: MKMapItem?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.placemark.coordinate.latitude == rhs.placemark.coordinate.latitude
            && lhs.placemark.coordinate.longitude == rhs.placemark.coordinate.longitude
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        Self.combine(origin, into: &hasher)
        Self.combine(destination, into: &hasher)

        // `CLLocationCoordinate2D` is not `Hashable`; hash its components.
        if let viaPoint {
            hasher.combine(viaPoint.latitude)
            hasher.combine(viaPoint.longitude)
        } else {
            hasher.combine(NSNull())
        }

        hasher.combine(transportMode)
    }

    // MARK: - Equatable

    static func == (lhs: TripPlannerRequest, rhs: TripPlannerRequest) -> Bool {
        // For `CLLocationCoordinate2D`, compare latitude and longitude.
        let viaPointEqual: Bool
        if let lhsVia = lhs.viaPoint, let rhsVia = rhs.viaPoint {
            viaPointEqual = (lhsVia.latitude == rhsVia.latitude &&
                            lhsVia.longitude == rhsVia.longitude)
        } else {
            viaPointEqual = (lhs.viaPoint == nil && rhs.viaPoint == nil)
        }

        let transportModeEqual = lhs.transportMode == rhs.transportMode

        return sameplace(lhs.origin, rhs.origin)
            && sameplace(lhs.destination, rhs.destination)
            && viaPointEqual
            && transportModeEqual
    }
}

// MARK: - SheetDetentConfiguration

/// Per-route configuration for detent behaviour, drag indicator, dismiss lock, and background interaction.
nonisolated struct SheetDetentConfiguration {
    let detents: Set<PresentationDetent>
    let initialDetent: PresentationDetent
    let showDragIndicator: Bool
    let isDismissDisabled: Bool
    let backgroundInteraction: PresentationBackgroundInteraction

    /// When set, background interaction is forced to `.disabled` while the sheet
    /// is parked at this detent — useful for the iPhone-landscape case where the
    /// sheet covers the full screen and nothing remains behind it to interact
    /// with. The `upThrough:` form of `PresentationBackgroundInteraction` isn't
    /// honored with custom `.height` detents, hence the explicit field.
    let fullScreenDetent: PresentationDetent?

    init(
        detents: Set<PresentationDetent>,
        initialDetent: PresentationDetent,
        showDragIndicator: Bool = true,
        isDismissDisabled: Bool,
        backgroundInteraction: PresentationBackgroundInteraction = .enabled(upThrough: .medium),
        fullScreenDetent: PresentationDetent? = nil
    ) {
        // `initialDetent` and `fullScreenDetent` must live inside `detents` —
        // both are matched by `==` against the current selection, so a stray
        // value would be silently dead config (initialDetent never seeded,
        // fullScreenDetent never matched). Catch the slip where it happens.
        precondition(detents.contains(initialDetent), "initialDetent must be a member of detents.")
        if let fullScreenDetent {
            precondition(detents.contains(fullScreenDetent), "fullScreenDetent must be a member of detents.")
        }

        self.detents = detents
        self.initialDetent = initialDetent
        self.showDragIndicator = showDragIndicator
        self.isDismissDisabled = isDismissDisabled
        self.backgroundInteraction = backgroundInteraction
        self.fullScreenDetent = fullScreenDetent
    }
}

// MARK: - SheetRouteable

/// Protocol that all sheet route enums must conform to.
/// Each case provides detent configuration and a stacking preference.
/// ViewModel construction lives in `AppSheetViewFactory`, not on the route itself.
nonisolated protocol SheetRouteable: Identifiable, Hashable {
    var detentConfiguration: SheetDetentConfiguration { get }
    /// When `true`, `SheetCoordinator.push(_:)` routes this case to the stacked
    /// layer (a second sheet over the base sheet); otherwise content-swap.
    var prefersStacking: Bool { get }
}

// MARK: - AppSheetRoute

/// All navigable destinations within the floating sheet.
nonisolated enum AppSheetRoute: SheetRouteable {
    // Base layer
    case home
    case search
    case nearbyAll
    case recentStopsAll
    case bookmarksAll

    // Stacked layer
    case stopDetails(stopID: Stop.ID)
    case tripPlanner(TripPlannerRequest)
    case tripDetails(tripID: TripIdentifier)
    case routePicker
    case currentTrip(route: Route)
    case transitAlert(alertID: String)
    case rentalDetail(rentalID: VehicleRental.ID)
    case rentalCluster(memberIDs: [VehicleRental.ID])
    case searchResults(SearchResponse)
    case mapItem(MKMapItem)
    case routeStops(StopsForRoute)
    case nearbyStops(coordinate: CLLocationCoordinate2D)

    case more
    case settings
    case mapSettings

}

nonisolated extension AppSheetRoute {
    // MARK: Identifiable

    /// Case-name prefix only — `String(describing:)` for a case-less enum value
    /// renders the case name (e.g. `"home"`); for cases with associated values
    /// it includes the payload, which we strip and reapply per-case below so
    /// each suffix can be intentionally formatted.
    private var caseName: String {
        let mirror = Mirror(reflecting: self)
        if let label = mirror.children.first?.label {
            return label
        }
        // No associated value → `String(describing:)` is already just the case name.
        return String(describing: self)
    }

    /// Stable identifier used by `Identifiable` and the sheet coordinator.
    /// Prefix is derived mechanically from the case name (typo-proof against
    /// hand-keyed strings); only the associated-value suffix is hand-written
    /// per case so each can pick its own formatting.
    var id: String {
        switch self {
        case .home, .search, .nearbyAll, .recentStopsAll, .bookmarksAll,
             .routePicker, .more, .settings, .mapSettings:
            return caseName
        case .stopDetails(let stopID):
            return "\(caseName)-\(stopID)"
        case .tripPlanner(let request):
            // Every field, coordinates included — the same shape `.mapItem` and
            // `.nearbyStops` use. This is `Identifiable`, and SwiftUI's
            // `.sheet(item:)` re-presents on a change of `id`: two planner routes
            // that differ only in where the rider is going must not share one.
            //
            // Reporting this to analytics would leak rider location. Nothing does
            // — use `analyticsKey`, which is the privacy-preserving form.
            return [
                caseName,
                Self.idComponent(request.origin?.placemark.coordinate),
                Self.idComponent(request.destination?.placemark.coordinate),
                Self.idComponent(request.viaPoint),
                request.transportMode.map(String.init(describing:)) ?? "anyMode"
            ].joined(separator: "-")
        case .tripDetails(let tripID):
            return "\(caseName)-\(tripID)"
        case .currentTrip(let route):
            return "\(caseName)-\(route.id)"
        case .transitAlert(let alertID):
            return "\(caseName)-\(alertID)"
        case .rentalDetail(let rentalID):
            return "\(caseName)-\(rentalID)"
        case .rentalCluster(let memberIDs):
            // Sorted so the id is order-independent — the same pile of vehicles
            // must produce the same route regardless of feed ordering, which is
            // what keeps an open sheet bound to its marker across a camera move.
            return "\(caseName)-\(memberIDs.sorted().joined(separator: ","))"
        case .searchResults(let response):
            return "\(caseName)-\(response.request.searchType.rawValue)-\(response.request.query)"
        case .mapItem(let item):
            let coordinate = item.placemark.coordinate
            return "\(caseName)-\(coordinate.latitude)-\(coordinate.longitude)"
        case .routeStops(let stopsForRoute):
            return "\(caseName)-\(stopsForRoute.id)"
        case .nearbyStops(let coordinate):
            return "\(caseName)-\(coordinate.latitude)-\(coordinate.longitude)"
        }
    }

    /// One coordinate as an `id` component, or `"none"` when absent.
    private static func idComponent(_ coordinate: CLLocationCoordinate2D?) -> String {
        guard let coordinate else { return "none" }
        return "\(coordinate.latitude),\(coordinate.longitude)"
    }

    /// A label safe to report to analytics.
    ///
    /// `id` cannot serve here: it carries coordinates, and where a rider is going is
    /// sensitive. This reports *which fields were prefilled* instead, which is the
    /// thing worth measuring anyway — it separates the entry points (a tapped map
    /// item, a rental vehicle, a stop's "Directions from Here") without saying where
    /// any of them were.
    ///
    /// Only `.tripPlanner` carries a payload private enough to need this; every other
    /// route's `id` is already safe, so they pass theirs straight through.
    var analyticsKey: String {
        guard case .tripPlanner(let request) = self else { return id }

        var parts: [String] = []
        if request.origin != nil {
            parts.append("origin")
        }
        if request.destination != nil {
            parts.append("destination")
        }
        if request.viaPoint != nil {
            parts.append("viaPoint")
        }
        if request.transportMode != nil {
            parts.append("transportMode")
        }
        return "\(caseName)_\(parts.isEmpty ? "blank" : parts.joined(separator: "_"))"
    }

    // MARK: Hashable / Equatable

    static func == (lhs: AppSheetRoute, rhs: AppSheetRoute) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

nonisolated extension AppSheetRoute {
    /// Detail destinations prefer the stacked layer so the base sheet peeks beneath.
    var prefersStacking: Bool {
        switch self {
        case .stopDetails, .tripPlanner, .tripDetails, .currentTrip, .transitAlert, .more, .nearbyAll,
             .recentStopsAll, .bookmarksAll, .settings, .mapSettings, .rentalDetail, .rentalCluster,
             .searchResults, .mapItem, .routeStops, .nearbyStops:
            return true
        case .home, .search, .routePicker:
            return false
        }
    }
}

nonisolated extension AppSheetRoute {

    /// "Almost-full" detent used as the largest stop for the home sheet and
    /// other content-swap routes. `.fraction(0.99)` rather than `.large`
    /// preserves the floating-card look (a sliver of map remains visible at
    /// the top edge) and lets `fullScreenDetent` reliably match — `.large`
    /// reports through a different detent identity that `==` comparison can't
    /// catch.
    static var largeDetent: PresentationDetent {
        return .fraction(0.99)
    }

    /// Height of the home sheet's smallest detent. Shared by `MapPanelRootView`
    /// so the map's bottom safe-area padding matches the collapsed sheet.
    ///
    /// Sized to `HomeSheetView`'s search-bar row and nothing else, so the
    /// collapsed sheet reads as a search field rather than as a list that got
    /// cut off: a body-metrics capsule (~48pt: one line of text plus its 14pt
    /// vertical padding, top and bottom) under the row's own 16pt top and 12pt
    /// bottom padding, less the couple of points the drag indicator already
    /// occupies above it.
    static let homeCollapsedHeight: CGFloat = 75

    /// Height of the trip planner's tip detent — a "peek" rung that leaves the
    /// map dominant when the panel is minimized. OTPKit's
    /// `DirectionsSheetView.tipDetent` collapses its own view when turn-by-turn
    /// directions open, and the panel owns detents centrally, so the trip
    /// planner needs a comparable rung for that handoff. Sized similarly to
    /// `homeCollapsedHeight`: a single row (e.g., just a button bar) with
    /// minimal padding.
    static let tripPlannerTipHeight: CGFloat = 80

    var detentConfiguration: SheetDetentConfiguration {
        switch self {
        case .home:
            // Keep background interaction enabled at small/medium detents so the
            // map and its overlays remain tappable. `upThrough:` isn't honored
            // with custom `.height` detents, so `fullScreenDetent` flips
            // background interaction to `.disabled` only when the sheet is
            // parked at `largeDetent` (covers ~the full screen).
            return SheetDetentConfiguration(
                detents: [.height(AppSheetRoute.homeCollapsedHeight), .medium, AppSheetRoute.largeDetent],
                initialDetent: .height(AppSheetRoute.homeCollapsedHeight),
                isDismissDisabled: true,
                backgroundInteraction: .enabled,
                fullScreenDetent: AppSheetRoute.largeDetent
            )
        case .search:
            // Base-layer: dismiss is locked so the user pops via the back affordance,
            // not by dragging the sheet off-screen.
            return SheetDetentConfiguration(
                detents: [.large],
                initialDetent: .large,
                isDismissDisabled: true,
                backgroundInteraction: .disabled
            )
        case .nearbyAll, .recentStopsAll, .bookmarksAll:
            // Stacked-layer: the OS owns dismissal so storage stays in sync with
            // the drag-down gesture via `truncateStacked`.
            return SheetDetentConfiguration(
                detents: [.large],
                initialDetent: .large,
                isDismissDisabled: false,
                backgroundInteraction: .disabled
            )
        case .stopDetails:
            // Opens full height — departures are the point of this sheet, and it
            // carries its own close button — but `.medium` has to be *reachable*,
            // because "Directions to/from Here" stacks the trip planner on top of
            // it. The planner sits at `.medium` to keep its route visible, which
            // buys nothing if a full-height stop sheet is still covering the map
            // behind it. `StopDetailsSheetView.planTrip(_:)` drives it down on the
            // way in; the rider can drag it back.
            //
            // `backgroundInteraction` stays explicitly `.disabled` rather than
            // falling back to the default `.enabled(upThrough: .medium)`. That
            // default maps to `largestUndimmedDetentIdentifier = .medium`, which
            // would leave this sheet undimmed and non-modal at `.medium` and let
            // every touch fall through to the map — the sheet would render but
            // neither scroll nor respond to taps.
            return SheetDetentConfiguration(
                detents: [.medium, .large],
                initialDetent: .large,
                isDismissDisabled: false,
                backgroundInteraction: .disabled
            )
        case .tripPlanner:
            // Opens at `.medium`: planning a trip is a map task, and the origin and
            // destination fields are what the rider reads first — a full-height sheet
            // hides the very map the trip is being drawn on.
            //
            // OTPKit's trip planner also collapses to its own custom tip detent when
            // directions open. The panel owns detents, so it needs a comparable tip
            // rung to stay in sync with OTPKit's collapsed state.
            return SheetDetentConfiguration(
                detents: [.height(AppSheetRoute.tripPlannerTipHeight), .medium, .large],
                initialDetent: .medium,
                isDismissDisabled: false
            )
        case .tripDetails, .routePicker, .currentTrip, .transitAlert, .more, .settings:
            return SheetDetentConfiguration(
                detents: [.medium, .large],
                initialDetent: .large,
                isDismissDisabled: false
            )
        case .rentalDetail, .rentalCluster:
            // `.medium` first: a rental sheet is a glance, and the map behind it
            // is the context for "is this one near me?".
            return SheetDetentConfiguration(
                detents: [.medium, .large],
                initialDetent: .medium,
                isDismissDisabled: false
            )
        case .mapSettings:
            // Opens at `.medium` so the map stays visible behind the basemap
            // tiles: picking a basemap you cannot see is a guess.
            return SheetDetentConfiguration(
                detents: [.medium, .large],
                initialDetent: .medium,
                isDismissDisabled: false
            )
        case .mapItem:
            // Medium only: the sheet is a detail card over the map, and the map has
            // to stay visible behind it. Long content scrolls inside the detent.
            return SheetDetentConfiguration(
                detents: [.medium],
                initialDetent: .medium,
                isDismissDisabled: false
            )
        case .routeStops:
            // Opens at medium so the route polyline stays on screen; the user can
            // drag to large for the full stop list.
            return SheetDetentConfiguration(
                detents: [.medium, .large],
                initialDetent: .medium,
                isDismissDisabled: false
            )
        case .searchResults:
            return SheetDetentConfiguration(
                detents: [.medium, .large],
                initialDetent: .large,
                isDismissDisabled: false
            )
        case .nearbyStops:
            return SheetDetentConfiguration(
                detents: [.large],
                initialDetent: .large,
                isDismissDisabled: false
            )
        }
    }

}
