// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct ContactDirectoryTableContent<Header: View, RichRow: View>: UIViewControllerRepresentable {
    let groups: [ContactDirectoryGroupInput]
    let groupsRevision: String
    let headerRevision: ContactDirectoryHeaderRevision
    let ownerIdentity: ObjectIdentifier
    let avatarRouteIdentity: String?
    let header: Header
    let richRow: (ContactDirectoryRowInput) -> RichRow
    let avatarRenderer: (String) -> ContactDirectoryAvatarRendering?
    let onSelect: (String) -> Void
    let onScrollChange: (Bool) -> Void

    public init(groups: [ContactDirectoryGroupInput], groupsRevision: String, headerRevision: ContactDirectoryHeaderRevision,
                ownerIdentity: ObjectIdentifier, avatarRouteIdentity: String?, header: Header,
                avatarRenderer: @escaping (String) -> ContactDirectoryAvatarRendering?,
                @ViewBuilder richRow: @escaping (ContactDirectoryRowInput) -> RichRow,
                onSelect: @escaping (String) -> Void, onScrollChange: @escaping (Bool) -> Void) {
        self.groups = groups; self.groupsRevision = groupsRevision; self.headerRevision = headerRevision
        self.ownerIdentity = ownerIdentity; self.avatarRouteIdentity = avatarRouteIdentity; self.header = header
        self.avatarRenderer = avatarRenderer; self.richRow = richRow; self.onSelect = onSelect; self.onScrollChange = onScrollChange
    }

    public func makeUIViewController(context: Context) -> ContactDirectoryTableController<Header, RichRow> {
        let controller = ContactDirectoryTableController<Header, RichRow>()
        controller.apply(self)
        return controller
    }

    public func updateUIViewController(_ controller: ContactDirectoryTableController<Header, RichRow>, context: Context) {
        controller.apply(self)
    }

    public static func dismantleUIViewController(_ controller: ContactDirectoryTableController<Header, RichRow>, coordinator: ()) {
        controller.endInteraction(applyingPending: false)
        controller.cancelAvatarLoads()
    }
}

public final class ContactDirectoryTableController<Header: View, RichRow: View>: UIViewController, UITableViewDelegate {
    private enum ItemID: Hashable { case heading(String), contact(String) }

    private enum RowHeight: Hashable, CaseIterable {
        case name, number, department, numberAndDepartment, automatic

        func fixedHeight(captionHeight: CGFloat) -> CGFloat? {
            guard self != .automatic else { return nil }
            var height = ceil(UIFont.systemFont(ofSize: 16, weight: .black).lineHeight)
            if self == .number || self == .numberAndDepartment { height += 5 + captionHeight }
            if self == .department || self == .numberAndDepartment {
                height += 5 + ceil(UIFont.systemFont(ofSize: 11, weight: .semibold).lineHeight)
            }
            return max(44, height) + 22
        }
    }

    private struct Row: Equatable {
        let presentation: ContactDirectoryRowInput
        let isFirst: Bool
        let isLast: Bool

        var heightKind: RowHeight {
            guard presentation.certification == nil else { return .automatic }
            switch (presentation.userNumber != nil, presentation.departmentSummary != nil) {
            case (false, false): return .name
            case (true, false): return .number
            case (false, true): return .department
            case (true, true): return .numberAndDepartment
            }
        }
    }

    private let table = UITableView(frame: .zero, style: .plain)
    private let headerHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var source: UITableViewDiffableDataSource<Int, ItemID>!
    private var rows: [ItemID: Row] = [:]
    private var avatars: [ItemID: ContactDirectoryAvatarRendering] = [:]
    private var input: ContactDirectoryTableContent<Header, RichRow>?
    private var pending: ContactDirectoryTableContent<Header, RichRow>?
    private var isInteracting = false
    private var headerNeedsMeasurement = true
    private var headerWidth: CGFloat = 0
    private var fixedHeights: [RowHeight: CGFloat] = [:]
    private var captionFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
    private var lastScrollMovement: TimeInterval = 0
    private var scrollSettlingTask: Task<Void, Never>?
    private var avatarUpdateTask: Task<Void, Never>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        table.backgroundColor = .clear
        table.accessibilityIdentifier = "contact_directory_table"
        table.showsVerticalScrollIndicator = false
        table.separatorStyle = .none
        table.sectionHeaderTopPadding = 0
        table.contentInset.bottom = 24
        table.contentInsetAdjustmentBehavior = .never
        table.isPrefetchingEnabled = false
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 66
        updateFixedHeights()
        table.delegate = self
        table.register(ContactDirectoryNativeCell.self, forCellReuseIdentifier: "contact")
        table.register(ContactDirectoryCell.self, forCellReuseIdentifier: "richContact")
        table.register(ContactDirectoryCell.self, forCellReuseIdentifier: "heading")
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        addChild(headerHost)
        headerHost.view.backgroundColor = .clear
        table.tableHeaderView = headerHost.view
        headerHost.didMove(toParent: self)

        source = UITableViewDiffableDataSource<Int, ItemID>(tableView: table) { [weak self] table, indexPath, id in
            self?.makeCell(in: table, at: indexPath, id: id)
        }
    }

    func apply(_ next: ContactDirectoryTableContent<Header, RichRow>) {
        loadViewIfNeeded()
        let previous = input
        let routeChanged = previous?.avatarRouteIdentity != next.avatarRouteIdentity
        let stateChanged = previous?.ownerIdentity != next.ownerIdentity
        if isInteracting, !routeChanged, !stateChanged {
            pending = next
            return
        }
        pending = nil
        input = next
        if previous?.headerRevision != next.headerRevision || routeChanged || stateChanged {
            headerHost.rootView = AnyView(next.header)
            headerNeedsMeasurement = true
            measureHeaderIfNeeded()
        }
        guard previous?.groupsRevision != next.groupsRevision || routeChanged || stateChanged else { return }

        var identifiers: [ItemID] = []
        var updatedRows: [ItemID: Row] = [:]
        var updatedAvatars: [ItemID: ContactDirectoryAvatarRendering] = [:]
        for group in next.groups {
            identifiers.append(.heading(group.letter))
            for (index, presentation) in group.rows.enumerated() {
                let id = ItemID.contact(presentation.id)
                guard updatedRows[id] == nil else { continue }
                identifiers.append(id)
                updatedRows[id] = Row(presentation: presentation, isFirst: index == 0,
                                      isLast: index == group.rows.count - 1)
                if !routeChanged, !stateChanged, rows[id]?.presentation.userRevision == presentation.userRevision {
                    updatedAvatars[id] = avatars[id]
                } else {
                    updatedAvatars[id] = next.avatarRenderer(presentation.id)
                }
            }
        }
        let oldIdentifiers = source.snapshot().itemIdentifiers
        let retained = Set(oldIdentifiers)
        let changed = identifiers.filter {
            retained.contains($0) && updatedRows[$0] != nil
                && (routeChanged || stateChanged || rows[$0] != updatedRows[$0])
        }
        let resized = Set(changed.filter { rows[$0]?.heightKind != updatedRows[$0]?.heightKind })
        rows = updatedRows
        avatars = updatedAvatars
        guard oldIdentifiers != identifiers || !changed.isEmpty else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, ItemID>()
        snapshot.appendSections([0])
        snapshot.appendItems(identifiers)
        snapshot.reloadItems(changed.filter { resized.contains($0) })
        snapshot.reconfigureItems(changed.filter { !resized.contains($0) })
        source.apply(snapshot, animatingDifferences: false)
        scheduleVisibleAvatars()
    }

    private func makeCell(in table: UITableView, at indexPath: IndexPath, id: ItemID) -> UITableViewCell {
        switch id {
        case .heading(let letter):
            let cell = table.dequeueReusableCell(withIdentifier: "heading", for: indexPath) as! ContactDirectoryCell
            cell.accessibilityLabel = letter
            cell.accessibilityIdentifier = "contact_group_\(letter)"
            cell.accessibilityTraits = .header
            cell.configure(AnyView(
                Text(letter)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.muted)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            ), parent: self)
            return cell
        case .contact(let userID):
            guard let row = rows[id], let input else { return UITableViewCell() }
            if fixedHeights[row.heightKind] != nil {
                let cell = table.dequeueReusableCell(withIdentifier: "contact", for: indexPath) as! ContactDirectoryNativeCell
                cell.bind(row.presentation, avatar: avatars[id], captionFont: captionFont,
                          isFirst: row.isFirst, isLast: row.isLast)
                return cell
            }
            let cell = table.dequeueReusableCell(withIdentifier: "richContact", for: indexPath) as! ContactDirectoryCell
            cell.accessibilityLabel = row.presentation.accessibilityLabel
            cell.accessibilityIdentifier = "contact_row_\(userID)"
            cell.accessibilityTraits = .button
            cell.configure(AnyView(
                input.richRow(row.presentation)
                    .background {
                        ContactListCardEdge(roundsTop: row.isFirst, roundsBottom: row.isLast)
                            .fill(.white.opacity(0.88))
                    }
                    .overlay(alignment: .bottom) {
                        if !row.isLast { Divider().padding(.leading, 62).opacity(0.72) }
                    }
                    .padding(.horizontal, 18)
                    .id(userID)
            ), parent: self, selfSizing: true)
            return cell
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        measureHeaderIfNeeded()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleVisibleAvatars()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancelAvatarLoads()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateFixedHeights()
            headerNeedsMeasurement = true
            viewIfLoaded?.setNeedsLayout()
            if source != nil { table.reloadData() }
        }
    }

    private func updateFixedHeights() {
        fixedHeights.removeAll(keepingCapacity: true)
        guard !traitCollection.preferredContentSizeCategory.isAccessibilityCategory else { return }
        let captionSize = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traitCollection).pointSize
        captionFont = .systemFont(ofSize: captionSize, weight: .semibold)
        let captionHeight = ceil(captionFont.lineHeight)
        for kind in RowHeight.allCases {
            fixedHeights[kind] = kind.fixedHeight(captionHeight: captionHeight)
        }
    }

    private func measureHeaderIfNeeded() {
        let width = table.bounds.width
        guard width > 0, headerNeedsMeasurement || abs(width - headerWidth) > 0.5 else { return }
        headerNeedsMeasurement = false
        headerWidth = width
        let height = headerHost.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)).height
        guard height.isFinite, height > 0 else { return }
        let frame = CGRect(x: 0, y: 0, width: width, height: ceil(height))
        guard headerHost.view.frame.size != frame.size else { return }
        headerHost.view.frame = frame
        table.tableHeaderView = headerHost.view
    }

    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        fixedHeight(at: indexPath) ?? UITableView.automaticDimension
    }

    public func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        // Most rows already have an exact height. Replacing an estimate while
        // the table is decelerating can shift its scroll position.
        fixedHeight(at: indexPath) ?? 82
    }

    private func fixedHeight(at indexPath: IndexPath) -> CGFloat? {
        guard let id = source.itemIdentifier(for: indexPath) else { return nil }
        if case .heading = id { return 38 }
        return rows[id].flatMap { fixedHeights[$0.heightKind] }
    }

    public func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard !tableView.isDragging, !tableView.isDecelerating,
              case .contact? = source.itemIdentifier(for: indexPath) else { return nil }
        return indexPath
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let id = source.itemIdentifier(for: indexPath), let row = rows[id] else { return }
        input?.onSelect(row.presentation.id)
    }

    public func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if cell is ContactDirectoryNativeCell { scheduleVisibleAvatars() }
    }

    public func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? ContactDirectoryNativeCell)?.cancelAvatarLoad()
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        lastScrollMovement = ProcessInfo.processInfo.systemUptime
        guard !isInteracting else { return }
        isInteracting = true
        cancelAvatarLoads()
        notifyScrollChange(true)
        waitForScrollToSettle()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isInteracting else { return }
        lastScrollMovement = ProcessInfo.processInfo.systemUptime
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { lastScrollMovement = ProcessInfo.processInfo.systemUptime }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        lastScrollMovement = ProcessInfo.processInfo.systemUptime
    }

    private func waitForScrollToSettle() {
        // The last delegate callback can run inside UIKit's final scrolling
        // layout. Release queued work only after the offset has stayed still.
        scrollSettlingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 90_000_000) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if !table.isTracking, !table.isDragging, !table.isDecelerating,
                   ProcessInfo.processInfo.systemUptime - lastScrollMovement >= 0.18 {
                    scrollSettlingTask = nil
                    endInteraction()
                    return
                }
            }
        }
    }

    func endInteraction(applyingPending: Bool = true) {
        scrollSettlingTask?.cancel()
        scrollSettlingTask = nil
        guard isInteracting else { return }
        isInteracting = false
        if let pending, applyingPending { apply(pending) }
        pending = nil
        if applyingPending { scheduleVisibleAvatars() }
        notifyScrollChange(false)
    }

    private func notifyScrollChange(_ isScrolling: Bool) {
        guard let callback = input?.onScrollChange else { return }
        DispatchQueue.main.async { callback(isScrolling) }
    }

    private func scheduleVisibleAvatars() {
        guard !isInteracting, avatarUpdateTask == nil else { return }
        avatarUpdateTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 160_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            defer { if !Task.isCancelled { avatarUpdateTask = nil } }
            guard !isInteracting, table.window != nil else { return }
            for cell in table.visibleCells {
                guard !Task.isCancelled, !isInteracting else { return }
                guard table.indexPath(for: cell) != nil,
                      (cell as? ContactDirectoryNativeCell)?.loadAvatarIfNeeded() == true else { continue }
                // Keep cold avatars from all completing on the first idle frame.
                do { try await Task.sleep(nanoseconds: 45_000_000) } catch { return }
            }
        }
    }

    func cancelAvatarLoads() {
        avatarUpdateTask?.cancel()
        avatarUpdateTask = nil
        for cell in table.visibleCells {
            (cell as? ContactDirectoryNativeCell)?.cancelAvatarLoad()
        }
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
