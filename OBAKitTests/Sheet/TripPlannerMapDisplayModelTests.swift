//
//  TripPlannerMapDisplayModelTests.swift
//  OBAKitTests
//
//  Copyright © Open Transit Software Foundation
//  This source code is licensed under the Apache 2.0 license found in the
//  LICENSE file in the root directory of this source tree.
//

import Foundation
import MapKit
import Testing
import CoreLocation
@testable import OBAKit
@testable import OBAKitCore

/// Trip planner map display model: rendered routes, annotations, camera
/// targets, and ambient-stop suppression.
@MainActor
@Suite(.serialized)
final class TripPlannerMapDisplayModelTests {

    @Test
    func `Starts with nothing displayed`() {
        let model = TripPlannerMapDisplayModel()

        #expect(model.isShowingTrip == false)
        #expect(model.routes.isEmpty == true)
        #expect(model.annotations.isEmpty == true)
        #expect(model.cameraTarget == nil)
        #expect(model.wantsUserLocation == false)
    }

    // MARK: - Ambient stop suppression gate

    /// The map layer that shows ambient stops checks `isShowingTrip` to suppress
    /// them while a trip is drawn, matching how search results take over the map.
    @Test
    func `isShowingTrip is true once routes are added`() {
        let model = TripPlannerMapDisplayModel()

        model.addRoute(
            coordinates: [
                CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3),
                CLLocationCoordinate2D(latitude: 47.61, longitude: -122.31)
            ],
            color: .blue,
            lineWidth: 2,
            identifier: "leg_0",
            lineDashPattern: nil
        )

        #expect(model.isShowingTrip == true)
    }

    @Test
    func `isShowingTrip is true once annotations are added`() {
        let model = TripPlannerMapDisplayModel()

        model.addAnnotation(
            coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3),
            title: "Start",
            subtitle: nil,
            identifier: "start",
            type: .origin,
            routeName: nil,
            routeBackgroundColor: nil,
            routeTextColor: nil
        )

        #expect(model.isShowingTrip == true)
    }

    @Test
    func `isShowingTrip becomes false when all routes are removed`() {
        let model = TripPlannerMapDisplayModel()
        model.addRoute(
            coordinates: [CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)],
            color: .blue,
            lineWidth: 2,
            identifier: "leg_0",
            lineDashPattern: nil
        )

        #expect(model.isShowingTrip == true)

        model.removeRoute(identifier: "leg_0")

        #expect(model.isShowingTrip == false)
    }

    @Test
    func `isShowingTrip becomes false when all annotations are removed`() {
        let model = TripPlannerMapDisplayModel()
        model.addAnnotation(
            coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3),
            title: "Start",
            subtitle: nil,
            identifier: "start",
            type: .origin,
            routeName: nil,
            routeBackgroundColor: nil,
            routeTextColor: nil
        )

        #expect(model.isShowingTrip == true)

        model.removeAnnotation(identifier: "start")

        #expect(model.isShowingTrip == false)
    }

    @Test
    func `clear resets everything and makes isShowingTrip false`() {
        let model = TripPlannerMapDisplayModel()
        model.addRoute(
            coordinates: [CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)],
            color: .blue,
            lineWidth: 2,
            identifier: "leg_0",
            lineDashPattern: nil
        )
        model.addAnnotation(
            coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3),
            title: "Start",
            subtitle: nil,
            identifier: "start",
            type: .origin,
            routeName: nil,
            routeBackgroundColor: nil,
            routeTextColor: nil
        )
        model.setRegion(MKCoordinateRegion(), animated: true)

        #expect(model.isShowingTrip == true)
        #expect(model.cameraTarget != nil)

        model.clear()

        #expect(model.isShowingTrip == false)
        #expect(model.routes.isEmpty == true)
        #expect(model.annotations.isEmpty == true)
        #expect(model.cameraTarget == nil)
        #expect(model.wantsUserLocation == false)
    }

    // MARK: - Annotation selection forwarding

    /// OTPKit hands the model a handler for annotation selections. The model
    /// records it and forwards calls from the view (which can't call OTPKit
    /// directly because the planner is a guest on the shared map).
    @Test
    func `handleAnnotationSelection forwards to the registered handler`() {
        let model = TripPlannerMapDisplayModel()
        var received: String?

        model.onAnnotationSelected { identifier in
            received = identifier
        }

        model.handleAnnotationSelection(identifier: "stop_123")

        #expect(received == "stop_123")
    }

    @Test
    func `handleAnnotationSelection with no registered handler is a no-op`() {
        let model = TripPlannerMapDisplayModel()

        // Should not trap.
        model.handleAnnotationSelection(identifier: "stop_123")
    }

    // MARK: - Camera targets

    @Test
    func `setRegion sets a region camera target`() {
        let model = TripPlannerMapDisplayModel()
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )

        model.setRegion(region, animated: true)

        guard case .region(let targetRegion, let animated) = model.cameraTarget else {
            Issue.record("Expected a region camera target")
            return
        }
        #expect(targetRegion.center.latitude == region.center.latitude)
        #expect(animated == true)
    }

    @Test
    func `setVisibleMapRect sets a rect camera target with edge padding`() {
        let model = TripPlannerMapDisplayModel()
        let mapRect = MKMapRect(x: 0, y: 0, width: 100, height: 100)
        let edgePadding = UIEdgeInsets(top: 10, left: 20, bottom: 30, right: 40)

        model.setVisibleMapRect(mapRect, edgePadding: edgePadding, animated: false)

        guard case .rect(let targetRect, let targetPadding, let animated) = model.cameraTarget else {
            Issue.record("Expected a rect camera target")
            return
        }
        #expect(targetRect.origin.x == mapRect.origin.x)
        #expect(targetPadding == edgePadding)
        #expect(animated == false)
    }

    @Test
    func `centerOnUserLocation sets a userLocation camera target`() {
        let model = TripPlannerMapDisplayModel()

        model.centerOnUserLocation(animated: true)

        guard case .userLocation(let animated) = model.cameraTarget else {
            Issue.record("Expected a userLocation camera target")
            return
        }
        #expect(animated == true)
    }

    @Test
    func `consumeCameraTarget clears the target without clearing routes or annotations`() {
        let model = TripPlannerMapDisplayModel()
        model.addRoute(
            coordinates: [CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)],
            color: .blue,
            lineWidth: 2,
            identifier: "leg_0",
            lineDashPattern: nil
        )
        model.setRegion(MKCoordinateRegion(), animated: false)

        #expect(model.cameraTarget != nil)

        model.consumeCameraTarget()

        #expect(model.cameraTarget == nil)
        #expect(model.routes.isEmpty == false)
        #expect(model.isShowingTrip == true)
    }
}
