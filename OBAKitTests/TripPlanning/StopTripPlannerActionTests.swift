//
//  StopTripPlannerActionTests.swift
//  OBAKitTests
//
//  Copyright © Open Transit Software Foundation
//  This source code is licensed under the Apache 2.0 license found in the
//  LICENSE file in the root directory of this source tree.
//

import UIKit
import Testing
@testable import OBAKit
@testable import OBAKitCore

/// Gates the stop-page "Directions to/from Here" affordances on OTP availability
/// and the per-region trip-planning preference.
@MainActor
@Suite(.serialized)
final class StopTripPlannerActionTests: OBATestCase {

    private var queue: OperationQueue!

    override init() async throws {
        try await super.init()
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
    }

    isolated deinit {
        queue.cancelAllOperations()
    }

    @Test func `isAvailable is true when OTP is running and trip planning is enabled`() async throws {
        let dataLoader = MockDataLoader(testName: name)
        let application = buildApplication(queue: queue, dataLoader: dataLoader)
        let maybeRegion = await waitForRegion(application)
        let region = try #require(maybeRegion)

        #expect(region.supportsOTP)
        #expect(application.features.tripPlanning == .running)
        #expect(application.userDataStore.isTripPlanningEnabled(for: region))
        #expect(StopTripPlannerAction.isAvailable(application: application))
        // Tests construct `Application` without a classic tab root, so the
        // stop-page rows stay hidden — same as experimental map-panel mode.
        #expect(!StopTripPlannerAction.canPresent(application: application))
    }

    @Test func `isAvailable is false when trip planning is disabled for the region`() async throws {
        let dataLoader = MockDataLoader(testName: name)
        let application = buildApplication(queue: queue, dataLoader: dataLoader)
        let maybeRegion = await waitForRegion(application)
        let region = try #require(maybeRegion)

        application.userDataStore.setTripPlanningEnabled(false, for: region)

        #expect(application.features.tripPlanning == .running)
        #expect(!StopTripPlannerAction.isAvailable(application: application))
        #expect(!StopTripPlannerAction.canPresent(application: application))
    }

    @Test func `isAvailable is false when the region has no OTP`() async throws {
        let dataLoader = MockDataLoader(testName: name)
        // Seed a non-OTP region before Application init so RegionsService loads it.
        userDefaults.set(2, forKey: "OBACurrentRegionIdentifierUserDefaultsKey") // MTA New York — no OTP
        stubRegions(dataLoader: dataLoader)
        stubAgenciesWithCoverage(dataLoader: dataLoader, baseURL: URL(string: "https://bustime.mta.info/")!)

        let locManager = MockAuthorizedLocationManager(
            updateLocation: TestData.mockSeattleLocation,
            updateHeading: TestData.mockHeading
        )
        let locationService = LocationService(userDefaults: userDefaults, locationManager: locManager)
        let config = AppConfig(
            regionsBaseURL: regionsURL,
            apiKey: apiKey,
            appVersion: appVersion,
            userDefaults: userDefaults,
            analytics: AnalyticsMock(),
            queue: queue,
            locationService: locationService,
            bundledRegionsFilePath: bundledRegionsPath,
            regionsAPIPath: regionsAPIPath,
            dataLoader: dataLoader
        )
        let application = Application(config: config)
        let maybeRegion = await waitForRegion(application)
        let region = try #require(maybeRegion)

        #expect(!region.supportsOTP)
        #expect(application.features.tripPlanning == .off)
        #expect(!StopTripPlannerAction.isAvailable(application: application))
        #expect(!StopTripPlannerAction.canPresent(application: application))
    }

    /// A map-pin stop is a FloatingPanel on the map, not a nav push. `popToRoot`
    /// leaves that sheet up and keeps the tab bar hidden (#883).
    @Test func `present dismisses the map-pin stop sheet before the trip planner`() async throws {
        let dataLoader = MockDataLoader(testName: name)
        stubStopsForLocation(dataLoader: dataLoader)
        let application = buildApplication(queue: queue, dataLoader: dataLoader)
        let region = try #require(await waitForRegion(application))
        #expect(region.supportsOTP)

        let root = ClassicApplicationRootController(application: application)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()

        let map = root.mapController
        #expect(StopTripPlannerAction.canPresent(application: application))

        map.stopSheet.present(UIViewController(), from: map, onDismiss: {})
        #expect(map.stopSheet.isPresenting)
        for _ in 0..<20 {
            if root.isTabBarHidden { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(root.isTabBarHidden)

        let stop = try #require(Fixtures.loadSomeStops().first)
        StopTripPlannerAction.present(.directionsToStop, stop: stop, application: application)

        #expect(!map.stopSheet.isPresenting)
        #expect(!root.isTabBarHidden)

        window.isHidden = true
    }

    private func stubStopsForLocation(dataLoader: MockDataLoader) {
        dataLoader.mock(
            url: URL(string: "https://api.pugetsound.onebusaway.org/api/where/stops-for-location.json")!,
            with: Fixtures.loadData(file: "stops_for_location_seattle.json")
        )
    }

    /// `fixedRegionName` selects the region during Application init; poll briefly
    /// in case regions load finishes after construction.
    private func waitForRegion(_ application: Application) async -> Region? {
        for _ in 0..<40 {
            if let region = application.currentRegion ?? application.regionsService.currentRegion {
                return region
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return application.currentRegion ?? application.regionsService.currentRegion
    }

    // MARK: - Map-panel payload

    /// "Directions to Here" puts the stop on the destination side and leaves the
    /// origin open, so the planner seeds the rider's current location.
    @Test func `Directions to here builds a request with the stop as the destination`() throws {
        let stop = try #require(Fixtures.loadSomeStops().first)

        let request = StopTripPlannerAction.plannerRequest(for: .directionsToStop, stop: stop)

        #expect(request.origin == nil)
        #expect(request.destination?.placemark.coordinate.latitude == stop.coordinate.latitude)
        #expect(request.destination?.placemark.coordinate.longitude == stop.coordinate.longitude)
        #expect(request.destination?.name == stop.title)
        // Neither is a rental trip: the mode stays open and there is no via point.
        #expect(request.viaPoint == nil)
        #expect(request.transportMode == nil)
    }

    /// "Directions from Here" is the mirror image — the stop is where the rider
    /// starts, and the destination is left for them to pick.
    @Test func `Directions from here builds a request with the stop as the origin`() throws {
        let stop = try #require(Fixtures.loadSomeStops().first)

        let request = StopTripPlannerAction.plannerRequest(for: .directionsFromStop, stop: stop)

        #expect(request.destination == nil)
        #expect(request.origin?.placemark.coordinate.latitude == stop.coordinate.latitude)
        #expect(request.origin?.placemark.coordinate.longitude == stop.coordinate.longitude)
        #expect(request.origin?.name == stop.title)
        #expect(request.viaPoint == nil)
        #expect(request.transportMode == nil)
    }

    /// Which end of the trip the stop sits on is the entire difference between the
    /// two actions, so the payloads must not be interchangeable.
    @Test func `The two directions actions put the stop on opposite ends`() throws {
        let stop = try #require(Fixtures.loadSomeStops().first)

        let toStop = StopTripPlannerAction.plannerRequest(for: .directionsToStop, stop: stop)
        let fromStop = StopTripPlannerAction.plannerRequest(for: .directionsFromStop, stop: stop)

        #expect(toStop != fromStop)
        #expect(AppSheetRoute.tripPlanner(toStop).id != AppSheetRoute.tripPlanner(fromStop).id)
    }

    /// The map panel pushes a route instead of presenting on a root controller, so
    /// it gates on `isAvailable` alone. `canPresent` stays false there — it speaks
    /// only for the classic tab — and gating the panel on it is what kept these two
    /// menu items hidden.
    @Test func `Panel availability does not require a classic root controller`() async throws {
        let dataLoader = MockDataLoader(testName: name)
        let application = buildApplication(queue: queue, dataLoader: dataLoader)
        let region = try #require(await waitForRegion(application))

        #expect(region.supportsOTP)
        #expect(application.viewRouter.rootController == nil)
        #expect(StopTripPlannerAction.canPresent(application: application) == false)
        #expect(StopTripPlannerAction.isAvailable(application: application))
    }

    // MARK: - Map-panel handler

    /// The whole point of the follow-up: on the panel these actually push, where
    /// before they were absent because `canPresent` demanded a root controller.
    @Test func `Panel handler pushes the planner with the stop as the destination`() async throws {
        let dataLoader = MockDataLoader(testName: name)
        let application = buildApplication(queue: queue, dataLoader: dataLoader)
        _ = try #require(await waitForRegion(application))
        let stop = try #require(Fixtures.loadSomeStops().first)
        let coordinator = SheetCoordinator<AppSheetRoute>(root: .home)
        coordinator.push(.stopDetails(stopID: stop.id))

        let handler = try #require(StopTripPlannerAction.panelHandler(
            for: .directionsToStop,
            application: application,
            coordinator: coordinator,
            stop: { stop }
        ))
        handler()

        guard case .tripPlanner(let request) = coordinator.stackedRoutes.last else {
            Issue.record("Expected .tripPlanner on top, got \(String(describing: coordinator.stackedRoutes.last))")
            return
        }
        #expect(request.destination?.placemark.coordinate.latitude == stop.coordinate.latitude)
        #expect(request.origin == nil)
    }

    @Test func `Panel handler pushes the planner with the stop as the origin`() async throws {
        let dataLoader = MockDataLoader(testName: name)
        let application = buildApplication(queue: queue, dataLoader: dataLoader)
        _ = try #require(await waitForRegion(application))
        let stop = try #require(Fixtures.loadSomeStops().first)
        let coordinator = SheetCoordinator<AppSheetRoute>(root: .home)
        coordinator.push(.stopDetails(stopID: stop.id))

        let handler = try #require(StopTripPlannerAction.panelHandler(
            for: .directionsFromStop,
            application: application,
            coordinator: coordinator,
            stop: { stop }
        ))
        handler()

        guard case .tripPlanner(let request) = coordinator.stackedRoutes.last else {
            Issue.record("Expected .tripPlanner on top, got \(String(describing: coordinator.stackedRoutes.last))")
            return
        }
        #expect(request.origin?.placemark.coordinate.latitude == stop.coordinate.latitude)
        #expect(request.destination == nil)
    }

    /// The stop sheet is `.large` by default and would otherwise stay full height
    /// behind the planner, hiding the very map the route is drawn on.
    @Test func `Panel handler uncovers the map by dropping the stop sheet to medium`() async throws {
        let dataLoader = MockDataLoader(testName: name)
        let application = buildApplication(queue: queue, dataLoader: dataLoader)
        _ = try #require(await waitForRegion(application))
        let stop = try #require(Fixtures.loadSomeStops().first)
        let coordinator = SheetCoordinator<AppSheetRoute>(root: .home)
        coordinator.push(.stopDetails(stopID: stop.id))
        #expect(coordinator.stackedDetents == [.large])

        let handler = try #require(StopTripPlannerAction.panelHandler(
            for: .directionsToStop,
            application: application,
            coordinator: coordinator,
            stop: { stop }
        ))
        handler()

        // A resize, not a dismissal — the rider still has the stop to come back to.
        #expect(coordinator.stackedRoutes.count == 2)
        #expect(coordinator.stackedDetents == [.medium, .medium])
    }

    /// Visible but inert before the first fetch lands. Nil would make the item
    /// vanish and reappear; `canActOnStop` greys it instead, as it does for every
    /// other stop-dependent action.
    @Test func `Panel handler is offered but inert before the stop loads`() async throws {
        let dataLoader = MockDataLoader(testName: name)
        let application = buildApplication(queue: queue, dataLoader: dataLoader)
        _ = try #require(await waitForRegion(application))
        let coordinator = SheetCoordinator<AppSheetRoute>(root: .home)
        coordinator.push(.stopDetails(stopID: "1"))

        let handler = try #require(StopTripPlannerAction.panelHandler(
            for: .directionsToStop,
            application: application,
            coordinator: coordinator,
            stop: { nil }
        ))
        handler()

        #expect(coordinator.stackedRoutes == [.stopDetails(stopID: "1")])
        #expect(coordinator.stackedDetents == [.large])
    }

    /// The stop arrives after the sheet is built, so the handler has to read it
    /// through the closure rather than capture whatever was there at build time.
    @Test func `Panel handler reads the stop at invocation, not at construction`() async throws {
        let dataLoader = MockDataLoader(testName: name)
        let application = buildApplication(queue: queue, dataLoader: dataLoader)
        _ = try #require(await waitForRegion(application))
        let stop = try #require(Fixtures.loadSomeStops().first)
        let coordinator = SheetCoordinator<AppSheetRoute>(root: .home)
        coordinator.push(.stopDetails(stopID: stop.id))

        var loaded: Stop?
        let handler = try #require(StopTripPlannerAction.panelHandler(
            for: .directionsToStop,
            application: application,
            coordinator: coordinator,
            stop: { loaded }
        ))

        // Built before the fetch returned.
        handler()
        #expect(coordinator.stackedRoutes.count == 1)

        loaded = stop
        handler()
        #expect(coordinator.stackedRoutes.count == 2)
    }

    /// No OTP server means no planner to push into, so the menu item is hidden
    /// rather than offered dead. Seeds the region identifier before `Application`
    /// init instead of writing one: the regions store is shared on disk across the
    /// whole test process.
    @Test func `Panel handler is nil when the region has no OTP`() async throws {
        let dataLoader = MockDataLoader(testName: name)
        userDefaults.set(2, forKey: "OBACurrentRegionIdentifierUserDefaultsKey") // MTA New York — no OTP
        stubRegions(dataLoader: dataLoader)
        stubAgenciesWithCoverage(dataLoader: dataLoader, baseURL: URL(string: "https://bustime.mta.info/")!)

        let locManager = MockAuthorizedLocationManager(
            updateLocation: TestData.mockSeattleLocation,
            updateHeading: TestData.mockHeading
        )
        let locationService = LocationService(userDefaults: userDefaults, locationManager: locManager)
        let config = AppConfig(
            regionsBaseURL: regionsURL,
            apiKey: apiKey,
            appVersion: appVersion,
            userDefaults: userDefaults,
            analytics: AnalyticsMock(),
            queue: queue,
            locationService: locationService,
            bundledRegionsFilePath: bundledRegionsPath,
            regionsAPIPath: regionsAPIPath,
            dataLoader: dataLoader
        )
        let application = Application(config: config)
        let region = try #require(await waitForRegion(application))
        #expect(!region.supportsOTP)

        let coordinator = SheetCoordinator<AppSheetRoute>(root: .home)
        for action in [StopTripPlannerAction.directionsToStop, .directionsFromStop] {
            #expect(StopTripPlannerAction.panelHandler(
                for: action,
                application: application,
                coordinator: coordinator,
                stop: { nil }
            ) == nil)
        }
    }

    /// The rider can turn trip planning off per region; that has to hide these too,
    /// not just the classic tab's copies.
    @Test func `Panel handler is nil when the rider disabled trip planning for the region`() async throws {
        let dataLoader = MockDataLoader(testName: name)
        let application = buildApplication(queue: queue, dataLoader: dataLoader)
        let region = try #require(await waitForRegion(application))
        #expect(region.supportsOTP)

        application.userDataStore.setTripPlanningEnabled(false, for: region)

        let coordinator = SheetCoordinator<AppSheetRoute>(root: .home)
        #expect(StopTripPlannerAction.panelHandler(
            for: .directionsToStop,
            application: application,
            coordinator: coordinator,
            stop: { nil }
        ) == nil)
    }
}
