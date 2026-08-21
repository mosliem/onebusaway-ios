//
//  TripPlannerMapDisplayModelTests.swift
//  OBAKitTests
//
//  Copyright © Open Transit Software Foundation
//  This source code is licensed under the Apache 2.0 license found in the
//  LICENSE file in the root directory of this source tree.
//

import CoreLocation
import Foundation
import MapKit
import SwiftUI
import Testing
import OTPKit
@testable import OBAKit

/// Tests for `TripPlannerMapDisplayModel`: the `OTPMapProvider` conformance that turns
/// OTPKit's imperative map calls into state the SwiftUI panel can render.
///
/// Everything here drives the model through the protocol, the way `MapCoordinator` will,
/// so the assertions describe the contract OTPKit actually depends on.
@Suite(.serialized)
@MainActor
struct TripPlannerMapDisplayModelTests {

    private let seattle = CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321)
    private let bellevue = CLLocationCoordinate2D(latitude: 47.6101, longitude: -122.2015)

    private func makeModel() -> TripPlannerMapDisplayModel {
        TripPlannerMapDisplayModel()
    }

    private func addRoute(
        to model: TripPlannerMapDisplayModel,
        identifier: String,
        color: Color = .blue,
        lineWidth: CGFloat = 4
    ) {
        model.addRoute(
            coordinates: [seattle, bellevue],
            color: color,
            lineWidth: lineWidth,
            identifier: identifier,
            lineDashPattern: nil
        )
    }

    private func addAnnotation(
        to model: TripPlannerMapDisplayModel,
        identifier: String,
        type: OTPAnnotationType = .origin
    ) {
        model.addAnnotation(
            coordinate: seattle,
            title: identifier,
            subtitle: nil,
            identifier: identifier,
            type: type,
            routeName: nil,
            routeBackgroundColor: nil,
            routeTextColor: nil
        )
    }

    // MARK: - Draw order

    @Test("Routes keep insertion order, which is the z-order OTPKit relies on")
    func routesKeepInsertionOrder() {
        let model = makeModel()

        // The order MapCoordinator uses: a white halo first, then the coloured leg on
        // top. If this ever reordered, halos would paint over the routes.
        addRoute(to: model, identifier: "halo_leg_0")
        addRoute(to: model, identifier: "leg_0")
        addRoute(to: model, identifier: "halo_leg_1")
        addRoute(to: model, identifier: "leg_1")

        #expect(model.routes.map(\.identifier) == ["halo_leg_0", "leg_0", "halo_leg_1", "leg_1"])
    }

    @Test("Annotations keep insertion order")
    func annotationsKeepInsertionOrder() {
        let model = makeModel()

        addAnnotation(to: model, identifier: "origin")
        addAnnotation(to: model, identifier: "station_from_0")
        addAnnotation(to: model, identifier: "destination", type: .destination)

        #expect(model.annotations.map(\.identifier) == ["origin", "station_from_0", "destination"])
    }

    // MARK: - Identifier reuse

    @Test("Re-adding an identifier replaces in place rather than duplicating")
    func reAddingRouteReplacesInPlace() {
        let model = makeModel()

        addRoute(to: model, identifier: "halo_leg_0")
        addRoute(to: model, identifier: "leg_0", color: .blue)
        addRoute(to: model, identifier: "leg_0", color: .red, lineWidth: 8)

        // Still two routes, the updated one still second: OTPKit reuses identifiers
        // across re-renders, so appending would both leak and disturb the z-order.
        #expect(model.routes.count == 2)
        #expect(model.routes.map(\.identifier) == ["halo_leg_0", "leg_0"])
        #expect(model.routes[1].lineWidth == 8)
    }

    @Test("Re-adding an annotation identifier replaces in place")
    func reAddingAnnotationReplacesInPlace() {
        let model = makeModel()

        addAnnotation(to: model, identifier: "origin")
        addAnnotation(to: model, identifier: "destination", type: .destination)
        model.addAnnotation(
            coordinate: bellevue,
            title: "moved",
            subtitle: nil,
            identifier: "origin",
            type: .origin,
            routeName: nil,
            routeBackgroundColor: nil,
            routeTextColor: nil
        )

        #expect(model.annotations.count == 2)
        #expect(model.annotations[0].title == "moved")
        #expect(model.annotations[0].coordinate.latitude == bellevue.latitude)
    }

    // MARK: - Removal

    @Test("Removing by identifier leaves the rest untouched")
    func removalIsScopedToIdentifier() {
        let model = makeModel()

        addRoute(to: model, identifier: "halo_leg_0")
        addRoute(to: model, identifier: "leg_0")
        addAnnotation(to: model, identifier: "origin")
        addAnnotation(to: model, identifier: "destination", type: .destination)

        model.removeRoute(identifier: "halo_leg_0")
        model.removeAnnotation(identifier: "origin")

        #expect(model.routes.map(\.identifier) == ["leg_0"])
        #expect(model.annotations.map(\.identifier) == ["destination"])
    }

    @Test("clearAllRoutes leaves annotations alone, and vice versa")
    func clearAllIsScopedToItsCollection() {
        let model = makeModel()

        addRoute(to: model, identifier: "leg_0")
        addAnnotation(to: model, identifier: "origin")

        model.clearAllRoutes()
        #expect(model.routes.isEmpty)
        #expect(model.annotations.count == 1)

        addRoute(to: model, identifier: "leg_0")
        model.clearAllAnnotations()
        #expect(model.annotations.isEmpty)
        #expect(model.routes.count == 1)
    }

    // MARK: - Trip presence

    @Test("isShowingTrip tracks whether anything is drawn")
    func isShowingTripTracksContent() {
        let model = makeModel()
        #expect(model.isShowingTrip == false)

        addRoute(to: model, identifier: "leg_0")
        #expect(model.isShowingTrip)

        model.clearAllRoutes()
        #expect(model.isShowingTrip == false)

        // An annotation alone still counts — a planner that has set only an origin pin
        // is showing something the ambient stop layer should not fight with.
        addAnnotation(to: model, identifier: "origin")
        #expect(model.isShowingTrip)
    }

    // MARK: - Camera

    @Test("Camera targets are one-shot")
    func cameraTargetIsOneShot() {
        let model = makeModel()
        #expect(model.cameraTarget == nil)

        let rect = MKMapRect(x: 100, y: 200, width: 300, height: 400)
        model.setVisibleMapRect(rect, edgePadding: .zero, animated: true)
        #expect(model.cameraTarget == .rect(rect, edgePadding: .zero, animated: true))

        // Without consumption the view would re-apply this on every unrelated body pass,
        // yanking the map back while the rider is panning.
        model.consumeCameraTarget()
        #expect(model.cameraTarget == nil)
    }

    @Test("centerOnUserLocation is expressed as a camera target, not a direct move")
    func centerOnUserLocationBecomesTarget() {
        let model = makeModel()

        model.centerOnUserLocation(animated: false)

        #expect(model.cameraTarget == .userLocation(animated: false))
    }

    @Test("getCurrentRegion reports what the view last recorded")
    func currentRegionReflectsRecordedViewport() {
        let model = makeModel()

        let region = MKCoordinateRegion(
            center: seattle,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
        model.updateVisibleRegion(region)

        let read = model.getCurrentRegion()
        #expect(read.center.latitude == seattle.latitude)
        #expect(read.span.latitudeDelta == 0.05)
    }

    @Test("getCurrentRegion falls back to the world before the first camera settle")
    func currentRegionFallsBackToWorld() {
        let model = makeModel()

        // A zero-span region would read as a specific — and wrong — place. Reporting the
        // world is the honest answer when the map has not said where it is looking.
        #expect(model.getCurrentRegion().span.latitudeDelta > 100)
    }

    // MARK: - Interaction

    @Test("Map taps reach the handler OTPKit registered")
    func mapTapReachesHandler() {
        let model = makeModel()

        var tapped: CLLocationCoordinate2D?
        model.onMapTap { tapped = $0 }
        model.handleMapTap(at: bellevue)

        #expect(tapped?.latitude == bellevue.latitude)
    }

    @Test("Annotation selection forwards OTPKit's own identifier verbatim")
    func annotationSelectionForwardsIdentifier() {
        let model = makeModel()

        var selected: String?
        model.onAnnotationSelected { selected = $0 }
        model.handleAnnotationSelection(identifier: "station_from_0")

        // The panel never interprets these — they are opaque keys OTPKit assigns and
        // expects back unchanged.
        #expect(selected == "station_from_0")
    }

    @Test("Interaction handlers are safe to invoke before OTPKit registers any")
    func interactionIsSafeWithoutHandlers() {
        let model = makeModel()

        model.handleMapTap(at: seattle)
        model.handleAnnotationSelection(identifier: "leg_0")

        #expect(model.isShowingTrip == false)
    }

    // MARK: - Panel-owned settings

    @Test("Map configuration calls do not disturb panel-wide state")
    func mapConfigurationCallsAreIgnored() {
        let model = makeModel()

        addRoute(to: model, identifier: "leg_0")

        // Basemap style is the rider's own choice, persisted through MapViewModel. OTPKit
        // may reconfigure its private map view on the UIKit surface, but here it is a
        // guest on the panel's shared map.
        model.setMapType(.satellite)
        model.setUserInteractionEnabled(false)
        model.setControlsVisible(false)

        #expect(model.routes.count == 1)
        #expect(model.cameraTarget == nil)
    }

    @Test("showUserLocation is recorded rather than acted on")
    func userLocationPreferenceIsRecorded() {
        let model = makeModel()
        #expect(model.wantsUserLocation == false)

        model.showUserLocation(true)
        #expect(model.wantsUserLocation)
    }

    // MARK: - Teardown

    @Test("clear drops everything the trip drew")
    func clearDropsEverything() {
        let model = makeModel()

        addRoute(to: model, identifier: "leg_0")
        addAnnotation(to: model, identifier: "origin")
        model.showUserLocation(true)
        model.setRegion(
            MKCoordinateRegion(center: seattle, span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)),
            animated: true
        )

        model.clear()

        #expect(model.routes.isEmpty)
        #expect(model.annotations.isEmpty)
        #expect(model.cameraTarget == nil)
        #expect(model.wantsUserLocation == false)
        #expect(model.isShowingTrip == false)
    }
}
