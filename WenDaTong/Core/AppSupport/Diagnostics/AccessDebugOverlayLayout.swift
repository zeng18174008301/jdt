import Foundation
import SwiftUI
import Darwin
#if canImport(UIKit)
import UIKit
#endif

enum AccessDebugOverlayAutoPark {
    static let idleDelay: TimeInterval = 1.8

    static func parkedPosition(bounds: AccessDebugOverlayDragBounds) -> CGPoint {
        bounds.defaultPosition
    }
}

struct AccessDebugOverlayDragRelease {
    static let inertiaMultiplier: CGFloat = 0.26
    static let maxInertiaDistance: CGFloat = 34

    static func settledPosition(
        restingPosition: CGPoint,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        bounds: AccessDebugOverlayDragBounds
    ) -> CGPoint {
        let current = bounds.clamp(
            CGPoint(
                x: restingPosition.x + translation.width,
                y: restingPosition.y + translation.height
            )
        )
        let predicted = bounds.clamp(
            CGPoint(
                x: restingPosition.x + predictedEndTranslation.width,
                y: restingPosition.y + predictedEndTranslation.height
            )
        )
        let impulse = CGSize(
            width: clamp((predicted.x - current.x) * inertiaMultiplier, maxDistance: maxInertiaDistance),
            height: clamp((predicted.y - current.y) * inertiaMultiplier, maxDistance: maxInertiaDistance)
        )
        return bounds.clamp(
            CGPoint(
                x: current.x + impulse.width,
                y: current.y + impulse.height
            )
        )
    }

    private static func clamp(_ value: CGFloat, maxDistance: CGFloat) -> CGFloat {
        min(max(value, -maxDistance), maxDistance)
    }
}

struct AccessDebugOverlayDragBounds: Equatable {
    static let horizontalMargin: CGFloat = 10
    // Keep the floating diagnostics surface below the navigation toolbar. The
    // toolbar owns group-title and trailing more-action hit targets, so neither
    // the capsule nor its expanded panel may enter this reserved strip.
    static let topNavigationControlReserve: CGFloat = 52
    static let bottomNavigationReserve: CGFloat = 58
    static let bottomMargin: CGFloat = 10

    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let overlaySize: CGSize

    var defaultPosition: CGPoint {
        CGPoint(x: maxX, y: minY)
    }

    func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    private var minX: CGFloat {
        Self.horizontalMargin + overlaySize.width / 2
    }

    private var maxX: CGFloat {
        max(minX, containerSize.width - Self.horizontalMargin - overlaySize.width / 2)
    }

    private var minY: CGFloat {
        max(safeAreaInsets.top + Self.topNavigationControlReserve, 12) + overlaySize.height / 2
    }

    private var maxY: CGFloat {
        let reservedBottom = max(safeAreaInsets.bottom + Self.bottomNavigationReserve, 72)
        let rawMax = containerSize.height - reservedBottom - Self.bottomMargin - overlaySize.height / 2
        return max(minY, rawMax)
    }
}

struct AccessDebugOverlayPanelLayout: Equatable {
    static let spacing: CGFloat = 8

    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let capsulePosition: CGPoint
    let capsuleSize: CGSize
    let panelSize: CGSize

    var panelMaxHeight: CGFloat {
        max(1, bottomLimit - topLimit)
    }

    var expansionDirection: AccessDebugOverlayExpansionDirection {
        if availableBelow >= panelSize.height { return .down }
        if availableAbove >= panelSize.height { return .up }
        return availableBelow >= availableAbove ? .down : .up
    }

    var horizontalAlignment: AccessDebugOverlayHorizontalAlignment {
        capsulePosition.x < containerSize.width * 0.5 ? .leading : .trailing
    }

    var transitionAnchor: UnitPoint {
        switch (expansionDirection, horizontalAlignment) {
        case (.up, .leading):
            return .bottomLeading
        case (.up, .trailing):
            return .bottomTrailing
        case (.down, .leading):
            return .topLeading
        case (.down, .trailing):
            return .topTrailing
        }
    }

    var panelPosition: CGPoint {
        CGPoint(
            x: clamp(desiredPanelCenterX, min: panelSize.width / 2 + AccessDebugOverlayDragBounds.horizontalMargin, max: maxPanelCenterX),
            y: clamp(desiredPanelCenterY, min: topLimit + panelSize.height / 2, max: maxPanelCenterY)
        )
    }

    var panelFrame: CGRect {
        CGRect(
            x: panelPosition.x - panelSize.width / 2,
            y: panelPosition.y - panelSize.height / 2,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    var topLimit: CGFloat {
        max(
            safeAreaInsets.top + AccessDebugOverlayDragBounds.topNavigationControlReserve,
            12
        )
    }

    var bottomLimit: CGFloat {
        containerSize.height
            - max(safeAreaInsets.bottom + AccessDebugOverlayDragBounds.bottomNavigationReserve, 72)
            - AccessDebugOverlayDragBounds.bottomMargin
    }

    private var availableBelow: CGFloat {
        bottomLimit - (capsulePosition.y + capsuleSize.height / 2 + Self.spacing)
    }

    private var availableAbove: CGFloat {
        (capsulePosition.y - capsuleSize.height / 2 - Self.spacing) - topLimit
    }

    private var desiredPanelCenterX: CGFloat {
        switch horizontalAlignment {
        case .leading:
            return capsulePosition.x - capsuleSize.width / 2 + panelSize.width / 2
        case .trailing:
            return capsulePosition.x + capsuleSize.width / 2 - panelSize.width / 2
        }
    }

    private var desiredPanelCenterY: CGFloat {
        switch expansionDirection {
        case .down:
            return capsulePosition.y + capsuleSize.height / 2 + Self.spacing + panelSize.height / 2
        case .up:
            return capsulePosition.y - capsuleSize.height / 2 - Self.spacing - panelSize.height / 2
        }
    }

    private var maxPanelCenterX: CGFloat {
        max(panelSize.width / 2 + AccessDebugOverlayDragBounds.horizontalMargin, containerSize.width - AccessDebugOverlayDragBounds.horizontalMargin - panelSize.width / 2)
    }

    private var maxPanelCenterY: CGFloat {
        max(topLimit + panelSize.height / 2, bottomLimit - panelSize.height / 2)
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), maxValue)
    }
}
