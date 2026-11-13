import Foundation
import SwiftUI
import Darwin
#if canImport(UIKit)
import UIKit
#endif

private let accessDiagnosticsOverlayBinaryMarker =
    "WXT_ACCESS_DIAGNOSTICS_OVERLAY_BINARY_MARKER_V1"

struct AccessDebugOverlay: View {
    @ObservedObject private var diagnostics: AccessDiagnostics
    let onTap: () -> Void

    init(
        diagnostics: AccessDiagnostics = .shared,
        onTap: @escaping () -> Void
    ) {
        self.diagnostics = diagnostics
        self.onTap = onTap
    }

    var body: some View {
        capsuleContent
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(capsuleBackground)
            .overlay(capsuleBorder)
            .contentShape(Capsule())
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(accessDiagnosticsOverlayBinaryMarker)
            .accessibilityLabel(Text("接入诊断"))
            .accessibilityValue(Text(diagnostics.snapshot.compactText))
            .accessibilityAction {
                onTap()
            }
    }

    private var capsuleContent: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(diagnostics.snapshot.compactText)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(.white)
    }

    private var capsuleBackground: some View {
        Capsule().fill(Color.black.opacity(0.58))
    }

    private var capsuleBorder: some View {
        Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
    }

    private var statusColor: Color {
        switch diagnostics.snapshot.status {
        case .failed:
            return .red
        case .selectedFallback, .usingCache:
            return .yellow
        case .selectedPrimary, .merchantDataPlane:
            return .green
        default:
            return .cyan
        }
    }
}

#if targetEnvironment(simulator)
enum SimulatorAccessEnvironment: String, CaseIterable {
    case local
    case production

    static let modeKey = "im2.simulator.accessEnvironment"
    private static let platformBaseKey = "im2.api.platformBase"
    private static let tenantBaseKey = "im2.api.tenantBase"
    private static let imBaseKey = "im2.api.imBase"
    private static let rtcBaseKey = "im2.api.rtcBase"
    private static let bootstrapBaseKey = "im2.api.bootstrapBase"
    private static let localBase = "http://127.0.0.1:5174"
	private static var productionBootstrapBase: String {
		guard case .configured(let configuration) = IMAppBootstrapHostConfigurationLoader.load(
			info: Bundle.main.infoDictionary ?? [:],
			appID: IMAPIContext.canonicalIOSAppID
		) else { return "" }
		return configuration.primary.absoluteString
	}
    private static let defaultEnvironment: SimulatorAccessEnvironment = .production
    private static let runtimeBaseOverrideKeys = [
        platformBaseKey,
        tenantBaseKey,
        imBaseKey,
        rtcBaseKey
    ]

    var title: String {
        switch self {
        case .local: return "本地"
        case .production: return "生产"
        }
    }

    var subtitle: String {
        switch self {
        case .local: return "127.0.0.1:5174"
        case .production: return "应用专属接入域名"
        }
    }

    static func ensureDefaultSelection(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: modeKey).flatMap(SimulatorAccessEnvironment.init(rawValue:))
        let selected = stored ?? defaultEnvironment
        write(selected, defaults: defaults)
        if stored == nil {
            clearRuntimeState(defaults: defaults)
        }
        defaults.synchronize()
    }

    static func current(defaults: UserDefaults = .standard) -> SimulatorAccessEnvironment {
        if let raw = defaults.string(forKey: modeKey),
           let environment = SimulatorAccessEnvironment(rawValue: raw) {
            return environment
        }
        return defaultEnvironment
    }

    @discardableResult
    static func apply(_ environment: SimulatorAccessEnvironment, defaults: UserDefaults = .standard) -> Bool {
        let previous = current(defaults: defaults)
        write(environment, defaults: defaults)
        if previous != environment {
            clearRuntimeState(defaults: defaults)
        }
        defaults.synchronize()
        return previous != environment
    }

    static func currentSummary(defaults: UserDefaults = .standard) -> String {
        current(defaults: defaults).subtitle
    }

    private static func write(_ environment: SimulatorAccessEnvironment, defaults: UserDefaults) {
        defaults.set(environment.rawValue, forKey: modeKey)
        switch environment {
        case .local:
            for key in runtimeBaseOverrideKeys {
                defaults.set(localBase, forKey: key)
            }
            defaults.set(localBase, forKey: bootstrapBaseKey)
        case .production:
            for key in runtimeBaseOverrideKeys {
                defaults.removeObject(forKey: key)
            }
			if productionBootstrapBase.isEmpty { defaults.removeObject(forKey: bootstrapBaseKey) }
			else { defaults.set(productionBootstrapBase, forKey: bootstrapBaseKey) }
        }
    }

    private static func clearRuntimeState(defaults: UserDefaults) {
        IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
        IMAppPolicyLastGoodStore.clearAll(defaults: defaults)
        IMTenantIMTokenExpiryStore.clear(defaults: defaults)
        AccessDiscoveryStore.clearDefaultStore()
        IMAPIContext.clearStoredSession()
    }
}

#endif

private struct AccessDebugOverlayPanel: View {
    @ObservedObject var diagnostics: AccessDiagnostics
    let maxHeight: CGFloat

    var body: some View {
        ScrollView(.vertical, showsIndicators: estimatedPanelHeight > maxHeight) {
            expandedPanel
        }
        .frame(
            width: 252,
            height: min(estimatedPanelHeight, maxHeight),
            alignment: .topLeading
        )
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.52)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.22), radius: 12, x: 0, y: 6)
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("接入诊断")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
            }

            ForEach(Array(diagnosticGroups.enumerated()), id: \.offset) { _, group in
                diagnosticSection(group.title, rows: group.rows)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 252, alignment: .leading)
    }

    private var diagnosticGroups: [(title: String, rows: [(String, String)])] {
        [("客户端", diagnostics.snapshot.clientIdentityRows),
         ("最近连接结果", diagnostics.snapshot.connectionRows),
         ("TURN地址", diagnostics.snapshot.turnAddresses.rows)] + diagnostics.snapshot.domainSections
    }

    private var estimatedPanelHeight: CGFloat {
        let rowCount = diagnosticGroups.reduce(0) { $0 + $1.rows.count }
        let wrappedRowExtraLines = diagnosticGroups
            .flatMap(\.rows)
            .reduce(0) { $0 + max(0, estimatedLineCount($1.1) - 1) }
        let verticalPadding: CGFloat = 24
        let headerHeight: CGFloat = 17
        let outerSpacing: CGFloat = CGFloat(diagnosticGroups.count) * 10
        let sectionTitleHeights: CGFloat = CGFloat(diagnosticGroups.count) * 14
        let rowHeights: CGFloat = CGFloat(rowCount) * 14
        let rowSpacing: CGFloat = CGFloat(rowCount) * 4
        let wrappedRowExtra: CGFloat = CGFloat(wrappedRowExtraLines) * 14
        return verticalPadding + headerHeight + outerSpacing + sectionTitleHeights + rowHeights + rowSpacing + wrappedRowExtra
    }

    private func estimatedLineCount(_ value: String) -> Int {
        let weightedLength = value.reduce(0) { partial, character in
            let isASCII = character.unicodeScalars.allSatisfy { $0.value < 128 }
            return partial + (isASCII ? 1 : 2)
        }
        return min(4, max(1, Int(ceil(Double(weightedLength) / 34.0))))
    }

    private func diagnosticSection(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(row.0)：")
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(width: 72, alignment: .leading)
                    Text(row.1)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(row.0): \(row.1)"))
            }
        }
    }
}
enum AccessDebugOverlayExpansionDirection: Equatable {
    case up
    case down
}

enum AccessDebugOverlayHorizontalAlignment: Equatable {
    case leading
    case trailing
}

struct AccessDebugOverlayHost: View {
    @ObservedObject private var diagnostics: AccessDiagnostics
    let safeAreaInsets: EdgeInsets

    @State private var basePosition: CGPoint?
    @State private var capsuleSize: CGSize = .zero
    @State private var panelSize: CGSize = .zero
    @State private var isDragging = false
    @State private var isExpanded = false
    @State private var suppressTapAfterDrag = false
    @State private var releaseImpulse: CGSize = .zero
    @State private var autoParkGeneration = 0
    @GestureState private var dragTranslation: CGSize = .zero

    init(diagnostics: AccessDiagnostics = .shared, safeAreaInsets: EdgeInsets) {
        self.diagnostics = diagnostics
        self.safeAreaInsets = safeAreaInsets
    }

    var body: some View {
        GeometryReader { proxy in
            let measuredCapsuleSize = effectiveCapsuleSize
            let dragBounds = AccessDebugOverlayDragBounds(
                containerSize: proxy.size,
                safeAreaInsets: safeAreaInsets,
                overlaySize: measuredCapsuleSize
            )
            let restingPosition = basePosition ?? dragBounds.defaultPosition
            let displayedPosition = dragBounds.clamp(
                CGPoint(
                    x: restingPosition.x + dragTranslation.width,
                    y: restingPosition.y + dragTranslation.height
                )
            )
            let panelLayout = AccessDebugOverlayPanelLayout(
                containerSize: proxy.size,
                safeAreaInsets: safeAreaInsets,
                capsulePosition: displayedPosition,
                capsuleSize: measuredCapsuleSize,
                panelSize: effectivePanelSize(maxHeight: proxy.size.height)
            )
            let capsuleHitFrame = CGRect(
                x: displayedPosition.x - measuredCapsuleSize.width / 2,
                y: displayedPosition.y - measuredCapsuleSize.height / 2,
                width: measuredCapsuleSize.width,
                height: measuredCapsuleSize.height
            )

            ZStack {
                if isExpanded {
                    AccessDebugOverlayPanel(
                        diagnostics: diagnostics,
                        maxHeight: panelLayout.panelMaxHeight
                    )
                    .background(
                        GeometryReader { sizeProxy in
                            Color.clear.preference(
                                key: AccessDebugOverlayPanelSizePreferenceKey.self,
                                value: sizeProxy.size
                            )
                        }
                    )
                    .position(panelLayout.panelPosition)
                    .transition(
                        .opacity.combined(
                            with: .scale(scale: 0.97, anchor: panelLayout.transitionAnchor)
                        )
                    )
                    .zIndex(0)
                }

                AccessDebugOverlay(
                    diagnostics: diagnostics,
                    onTap: { toggleExpandedFromTap(bounds: dragBounds) }
                )
                .fixedSize()
                .background(
                    GeometryReader { sizeProxy in
                        Color.clear.preference(
                            key: AccessDebugOverlayCapsuleSizePreferenceKey.self,
                            value: sizeProxy.size
                        )
                    }
                )
                .contentShape(Rectangle())
                .modifier(
                    AccessDebugOverlayDragDeformation(
                        translation: deformationTranslation,
                        isDragging: isDragging
                    )
                )
                .position(displayedPosition)
                .gesture(dragGesture(bounds: dragBounds, restingPosition: restingPosition))
                .zIndex(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(
                AccessDebugOverlayHitShape(
                    capsuleFrame: capsuleHitFrame,
                    panelFrame: isExpanded ? panelLayout.panelFrame : nil
                )
            )
            .animation(.spring(response: 0.26, dampingFraction: 0.88), value: isExpanded)
            .onAppear {
                basePosition = dragBounds.clamp(restingPosition)
                scheduleAutoPark(bounds: dragBounds)
            }
            .onChangeCompat(of: proxy.size) { _, _ in
                basePosition = dragBounds.clamp(basePosition ?? dragBounds.defaultPosition)
                scheduleAutoPark(bounds: dragBounds)
            }
            .onChangeCompat(of: safeAreaInsets.top) { _, _ in
                basePosition = dragBounds.clamp(basePosition ?? dragBounds.defaultPosition)
                scheduleAutoPark(bounds: dragBounds)
            }
            .onChangeCompat(of: safeAreaInsets.bottom) { _, _ in
                basePosition = dragBounds.clamp(basePosition ?? dragBounds.defaultPosition)
                scheduleAutoPark(bounds: dragBounds)
            }
            .onPreferenceChange(AccessDebugOverlayCapsuleSizePreferenceKey.self) { newSize in
                guard newSize.width > 0, newSize.height > 0 else { return }
                guard !accessDebugOverlaySizeApproximatelyEqual(capsuleSize, newSize) else { return }
                capsuleSize = newSize
                let updatedBounds = AccessDebugOverlayDragBounds(
                    containerSize: proxy.size,
                    safeAreaInsets: safeAreaInsets,
                    overlaySize: newSize
                )
                basePosition = updatedBounds.clamp(basePosition ?? updatedBounds.defaultPosition)
                scheduleAutoPark(bounds: updatedBounds)
            }
            .onPreferenceChange(AccessDebugOverlayPanelSizePreferenceKey.self) { newSize in
                guard newSize.width > 0, newSize.height > 0 else { return }
                guard !accessDebugOverlaySizeApproximatelyEqual(panelSize, newSize) else { return }
                panelSize = newSize
            }
        }
    }

    private var effectiveCapsuleSize: CGSize {
        guard capsuleSize.width > 0, capsuleSize.height > 0 else {
            return CGSize(width: 132, height: 32)
        }
        return capsuleSize
    }

    private func effectivePanelSize(maxHeight: CGFloat) -> CGSize {
        guard panelSize.width > 0, panelSize.height > 0 else {
            return CGSize(width: 252, height: min(maxHeight, 300))
        }
        return panelSize
    }

    private var deformationTranslation: CGSize {
        CGSize(
            width: dragTranslation.width + releaseImpulse.width,
            height: dragTranslation.height + releaseImpulse.height
        )
    }

    private func dragGesture(bounds: AccessDebugOverlayDragBounds, restingPosition: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .updating($dragTranslation) { value, state, _ in
                let proposed = CGPoint(
                    x: restingPosition.x + value.translation.width,
                    y: restingPosition.y + value.translation.height
                )
                let clamped = bounds.clamp(proposed)
                state = CGSize(
                    width: clamped.x - restingPosition.x,
                    height: clamped.y - restingPosition.y
                )
            }
            .onChanged { _ in
                if !isDragging {
                    cancelAutoPark()
                    suppressTapAfterDrag = true
                    withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.78)) {
                        isExpanded = false
                        isDragging = true
                        releaseImpulse = .zero
                    }
                }
            }
            .onEnded { value in
                let proposed = CGPoint(
                    x: restingPosition.x + value.translation.width,
                    y: restingPosition.y + value.translation.height
                )
                let clamped = bounds.clamp(proposed)
                let settle = AccessDebugOverlayDragRelease.settledPosition(
                    restingPosition: restingPosition,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    bounds: bounds
                )
                let impulse = CGSize(width: settle.x - clamped.x, height: settle.y - clamped.y)

                withAnimation(.interpolatingSpring(stiffness: 290, damping: 26)) {
                    basePosition = settle
                    isDragging = false
                    releaseImpulse = impulse
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.interpolatingSpring(stiffness: 260, damping: 20)) {
                        releaseImpulse = .zero
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    suppressTapAfterDrag = false
                    scheduleAutoPark(bounds: bounds)
                }
            }
    }

    private func toggleExpandedFromTap(bounds: AccessDebugOverlayDragBounds) {
        guard !isDragging, !suppressTapAfterDrag else { return }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            isExpanded.toggle()
        }
        if isExpanded {
            cancelAutoPark()
        } else {
            scheduleAutoPark(bounds: bounds)
        }
    }

    private func scheduleAutoPark(bounds: AccessDebugOverlayDragBounds) {
        guard !isExpanded, !isDragging else { return }
        autoParkGeneration += 1
        let generation = autoParkGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + AccessDebugOverlayAutoPark.idleDelay) {
            guard generation == autoParkGeneration, !isExpanded, !isDragging else { return }
            let target = AccessDebugOverlayAutoPark.parkedPosition(bounds: bounds)
            guard basePosition != nil else {
                basePosition = target
                return
            }
            withAnimation(.interpolatingSpring(stiffness: 260, damping: 28)) {
                basePosition = target
            }
        }
    }

    private func cancelAutoPark() {
        autoParkGeneration += 1
    }
}

private struct AccessDebugOverlayHitShape: Shape {
    let capsuleFrame: CGRect
    let panelFrame: CGRect?
    private static let capsuleHitPadding: CGFloat = 3
    private static let panelHitPadding: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: capsuleFrame.insetBy(dx: -Self.capsuleHitPadding, dy: -Self.capsuleHitPadding),
            cornerSize: CGSize(
                width: capsuleFrame.height / 2 + Self.capsuleHitPadding,
                height: capsuleFrame.height / 2 + Self.capsuleHitPadding
            )
        )
        if let panelFrame {
            path.addRoundedRect(
                in: panelFrame.insetBy(dx: -Self.panelHitPadding, dy: -Self.panelHitPadding),
                cornerSize: CGSize(width: 14, height: 14)
            )
        }
        return path
    }
}
private struct AccessDebugOverlayDragDeformation: ViewModifier {
    let translation: CGSize
    let isDragging: Bool

    func body(content: Content) -> some View {
        let distance = hypot(translation.width, translation.height)
        let hasMotion = isDragging || distance > 0.5
        let cappedDistance = min(distance, 150)
        let stretch = hasMotion ? min(cappedDistance / 460, 0.24) : 0
        let horizontalDominant = abs(translation.width) >= abs(translation.height)
        let compression = stretch * 0.34
        let xScale = 1 + (horizontalDominant ? stretch : -compression)
        let yScale = 1 + (horizontalDominant ? -compression : stretch)
        let rotation = hasMotion ? max(min(translation.width / 16, 9), -9) : 0
        let tail = tailOffset(distance: cappedDistance)

        content
            .background {
                if hasMotion, cappedDistance > 2 {
                    Capsule()
                        .fill(Color.black.opacity(isDragging ? 0.28 : 0.16))
                        .frame(width: max(18, cappedDistance * 0.38), height: 16)
                        .offset(tail)
                        .blur(radius: 0.2)
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }
            }
            .scaleEffect(x: xScale, y: yScale, anchor: .center)
            .rotationEffect(.degrees(rotation))
            .shadow(color: Color.black.opacity(isDragging ? 0.28 : 0.16), radius: isDragging ? 14 : 8, x: 0, y: isDragging ? 8 : 4)
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.74, blendDuration: 0.04), value: isDragging)
            .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.72, blendDuration: 0.04), value: translation)
    }

    private func tailOffset(distance: CGFloat) -> CGSize {
        guard distance > 0 else { return .zero }
        let unitX = translation.width / max(distance, 1)
        let unitY = translation.height / max(distance, 1)
        let tailDistance = min(max(distance * 0.12, 4), 14)
        return CGSize(width: -unitX * tailDistance, height: -unitY * tailDistance)
    }
}

private struct AccessDebugOverlayCapsuleSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        guard next.width > 0, next.height > 0 else { return }
        value = next
    }
}

private struct AccessDebugOverlayPanelSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        guard next.width > 0, next.height > 0 else { return }
        value = next
    }
}

private func accessDebugOverlaySizeApproximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
    abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
}
