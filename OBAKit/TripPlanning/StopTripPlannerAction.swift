//
//  StopTripPlannerAction.swift
//  OBAKit
//
//  Copyright © Open Transit Software Foundation
//  This source code is licensed under the Apache 2.0 license found in the
//  LICENSE file in the root directory of this source tree.
//

import MapKit
import OBAKitCore

/// Stop-page trip-planner menu actions. Menus and toolbars can gate on
/// `canPresent` without instantiating a view controller.
enum StopTripPlannerAction {
    /// Prefill destination as the stop; origin stays current location.
    case directionsToStop
    /// Prefill origin as the stop; destination left empty for the rider to pick.
    case directionsFromStop

    /// `true` when OTP trip planning is running for the current region and the
    /// rider has not disabled it for that region. Does not imply the classic
    /// map tab can present the planner — see `canPresent`.
    static func isAvailable(application: Application) -> Bool {
        guard application.features.tripPlanning == .running,
              let region = application.regionsService.currentRegion
                ?? application.currentRegion,
              application.userDataStore.isTripPlanningEnabled(for: region) else {
            return false
        }
        return true
    }

    /// Hide the stop-page actions unless the classic tab root can host
    /// `MapViewController.showTripPlanner`. Map-panel mode leaves
    /// `viewRouter.rootController` nil; showing the rows there would be a
    /// dead button.
    ///
    /// The map panel does not go through here at all — it pushes a route rather
    /// than presenting on a root controller, so it gates on `isAvailable` and
    /// builds a request with `plannerRequest(for:stop:)`.
    static func canPresent(application: Application) -> Bool {
        isAvailable(application: application) && application.viewRouter.rootController != nil
    }

    /// The same two actions as a map-panel sheet route payload.
    ///
    /// The UIKit path has to pop to the map tab, unwind its navigation stack and
    /// tear down any open stop sheet before it can hand the stop to
    /// `MapViewController.showTripPlanner`. The panel has no such dance: the
    /// planner is a route, and pushing it stacks a sheet over the stop the way
    /// every other panel action does. So this returns the payload and leaves the
    /// push to the caller, which owns the coordinator.
    ///
    /// Which side the stop lands on is the whole difference between the two
    /// actions — to the stop, or away from it. The other side stays nil so the
    /// planner seeds the rider's current location or waits for them to pick.
    static func plannerRequest(for action: StopTripPlannerAction, stop: Stop) -> TripPlannerRequest {
        let stopMapItem = TripPlannerEndpoints.mapItem(from: stop)
        switch action {
        case .directionsToStop:
            return TripPlannerRequest(destination: stopMapItem)
        case .directionsFromStop:
            return TripPlannerRequest(origin: stopMapItem)
        }
    }

    /// Pops to the map tab and opens the existing trip planner. No-ops (with
    /// a log) when `canPresent` is false.
    static func present(_ action: StopTripPlannerAction, stop: Stop, application: Application) {
        guard canPresent(application: application),
              let rootController = application.viewRouter.rootController else {
            if isAvailable(application: application) {
                Logger.error("StopTripPlannerAction: present dropped — no classic root controller (map-panel mode is active)")
            }
            return
        }

        application.viewRouter.rootNavigateTo(page: .map)

        let mapController = rootController.mapController
        mapController.navigationController?.popToRootViewController(animated: false)
        // Map-pin stops live in `stopSheet`, not the nav stack. Same teardown
        // as opening a map item or another panel (#883).
        mapController.dismissStopSheetForReplacement()

        // Built through the shared payload so the two surfaces cannot disagree
        // about which end of the trip the stop is.
        let request = plannerRequest(for: action, stop: stop)
        mapController.showTripPlanner(origin: request.origin, destination: request.destination)
    }

    /// The map-panel handler for one of these actions, or nil when it should not
    /// be offered at all.
    ///
    /// Lives here rather than inside `StopDetailsSheetView` so the wiring is
    /// testable without inspecting a view — the reason `StopPageActionRowState` and
    /// `AppSheetViewFactory.offersTripPlanning(in:)` are values too.
    ///
    /// Three behaviours, and the difference between the first two matters:
    ///
    /// - **nil when trip planning is unavailable**, which hides the menu item. A
    ///   dead primary action is worse than none.
    /// - **non-nil but inert before the stop loads.** The item stays visible and
    ///   `StopPageActionRowState.canActOnStop` greys it, the same treatment every
    ///   other stop-dependent action gets. Returning nil here instead would make
    ///   the item vanish and reappear as the fetch lands.
    /// - **on invocation**, drops the stop sheet to `.medium` before pushing, so
    ///   the map is already uncovered when the planner settles on top of it.
    ///
    /// `stop` is a closure because the sheet is built before its first fetch
    /// returns; capturing the value would pin whatever was there at build time.
    static func panelHandler(
        for action: StopTripPlannerAction,
        application: Application,
        coordinator: SheetCoordinator<AppSheetRoute>,
        stop: @escaping () -> Stop?
    ) -> (() -> Void)? {
        guard isAvailable(application: application) else { return nil }

        return {
            guard let stop = stop() else { return }

            coordinator.setStackedDetent(.medium) { route in
                if case .stopDetails = route { return true }
                return false
            }
            coordinator.push(.tripPlanner(plannerRequest(for: action, stop: stop)))
        }
    }

    static var directionsToHereTitle: String {
        OBALoc(
            "stops_controller.directions_to_here",
            value: "Directions to Here",
            comment: "Stop Location menu action that opens the trip planner with this stop as the destination."
        )
    }

    static var directionsFromHereTitle: String {
        OBALoc(
            "stops_controller.directions_from_here",
            value: "Directions from Here",
            comment: "Stop Location menu action that opens the trip planner with this stop as the origin."
        )
    }
}
