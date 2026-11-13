// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import UIKit

public struct RecycledConversationTableContent<Header: View, Search: View, Filter: View, Footer: View, Row: View, HeaderRevision: Equatable>: UIViewControllerRepresentable {
    let items: [ConversationListItemInput]
    let rowsRevision: Int
    let displaysRows: Bool
    let searchRevision: String
    let rowContext: String
    let header: Header
    let search: Search
    let filter: Filter
    let footer: Footer
    let headerRevision: HeaderRevision
    let filterRevision: String
    let dynamicFooter: Bool
    let interactionChanged: (Bool) -> Void
    let row: (ConversationListItemInput) -> Row

    public init(items: [ConversationListItemInput], rowsRevision: Int, displaysRows: Bool, searchRevision: String,
                rowContext: String, header: Header, search: Search, filter: Filter, footer: Footer,
                headerRevision: HeaderRevision, filterRevision: String, dynamicFooter: Bool,
                interactionChanged: @escaping (Bool) -> Void, @ViewBuilder row: @escaping (ConversationListItemInput) -> Row) {
        self.items = items; self.rowsRevision = rowsRevision; self.displaysRows = displaysRows
        self.searchRevision = searchRevision; self.rowContext = rowContext; self.header = header
        self.search = search; self.filter = filter; self.footer = footer; self.headerRevision = headerRevision
        self.filterRevision = filterRevision; self.dynamicFooter = dynamicFooter
        self.interactionChanged = interactionChanged; self.row = row
    }

    public func makeUIViewController(context: Context) -> RecycledConversationController<Header, Search, Filter, Footer, Row, HeaderRevision> {
        let controller = RecycledConversationController<Header, Search, Filter, Footer, Row, HeaderRevision>()
        controller.apply(self)
        return controller
    }
    public func updateUIViewController(_ controller: RecycledConversationController<Header, Search, Filter, Footer, Row, HeaderRevision>, context: Context) {
        controller.apply(self)
    }
    public static func dismantleUIViewController(_ controller: RecycledConversationController<Header, Search, Filter, Footer, Row, HeaderRevision>, coordinator: ()) {
        controller.stopTrackingScroll()
    }
}

public final class RecycledConversationController<Header: View, Search: View, Filter: View, Footer: View, Row: View, HeaderRevision: Equatable>: UIViewController, UITableViewDelegate {
    private enum Item: Hashable { case filter, conversation(String), footer }
    private let table = UITableView(frame: .zero, style: .plain)
    private let headerHost = UIHostingController(rootView: AnyView(EmptyView()))
    private let searchHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var source: UITableViewDiffableDataSource<Int, Item>!
    private var input: RecycledConversationTableContent<Header, Search, Filter, Footer, Row, HeaderRevision>?
    private var pending: RecycledConversationTableContent<Header, Search, Filter, Footer, Row, HeaderRevision>?
    private var itemsByID: [String: ConversationListItemInput] = [:]
    private var headerNeedsMeasurement = true
    private var measuredHeaderWidth: CGFloat = 0
    private var searchNeedsMeasurement = true
    private var measuredSearchWidth: CGFloat = 0
    private var measuredSearchHeight: CGFloat = 64
    private var lastScrollMovement: TimeInterval = 0
    private var scrollSettlingTask: Task<Void, Never>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.showsVerticalScrollIndicator = false
        table.isPrefetchingEnabled = false
        table.delaysContentTouches = false
        // Existing row geometry: 56pt avatar + 28pt card padding + 12pt separation.
        table.estimatedRowHeight = 96
        table.rowHeight = UITableView.automaticDimension
        table.estimatedSectionHeaderHeight = 64
        table.sectionHeaderTopPadding = 0
        table.delegate = self
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor), table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.topAnchor.constraint(equalTo: view.topAnchor), table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        for host in [headerHost, searchHost] {
            addChild(host); host.view.backgroundColor = .clear; host.didMove(toParent: self)
        }
        table.tableHeaderView = headerHost.view
        source = UITableViewDiffableDataSource<Int, Item>(tableView: table) { [weak self] table, index, id in
            guard let self, let input = self.input else { return UITableViewCell() }
            let reuseID: String
            switch id { case .conversation: reuseID = "conversation"; case .filter: reuseID = "filter"; case .footer: reuseID = "footer" }
            let cell = (table.dequeueReusableCell(withIdentifier: reuseID) as? RecycledConversationCell)
                ?? RecycledConversationCell(style: .default, reuseIdentifier: reuseID)
            let content: AnyView
            switch id {
            case .filter: content = AnyView(input.filter)
            case .footer: content = AnyView(input.footer)
            case .conversation(let key):
                guard let item = self.itemsByID[key] else { return cell }
                content = AnyView(input.row(item).id(item.id))
            }
            cell.configure(content, parent: self)
            return cell
        }
    }

    func apply(_ next: RecycledConversationTableContent<Header, Search, Filter, Footer, Row, HeaderRevision>) {
        loadViewIfNeeded()
        // Never reorder or resize rows under an active finger/deceleration.
        if scrollSettlingTask != nil || table.isDragging || table.isDecelerating { pending = next; return }
        pending = nil
        let previous = input
        input = next
        if previous == nil || previous?.searchRevision != next.searchRevision {
            searchHost.rootView = AnyView(next.search)
            searchNeedsMeasurement = true
        }
        let headerChanged = previous?.headerRevision != next.headerRevision
        let filterChanged = previous?.filterRevision != next.filterRevision
        if headerChanged {
            headerHost.rootView = AnyView(next.header)
            headerNeedsMeasurement = true
            updateHeaderSize()
        }
        let contextChanged = previous?.rowContext != next.rowContext
        let rowsChanged = previous?.rowsRevision != next.rowsRevision
            || previous?.displaysRows != next.displaysRows || contextChanged
        if !rowsChanged {
            let footerChanged = next.dynamicFooter || previous?.dynamicFooter == true
            guard filterChanged || footerChanged else { return }
            var snapshot = source.snapshot()
            if filterChanged {
                // Reconfiguration can leave newly inserted SwiftUI badge text invisible
                // in the existing hosting cell even though its layout already changed.
                snapshot.reloadItems([.filter])
            }
            if footerChanged { snapshot.reconfigureItems([.footer]) }
            source.apply(snapshot, animatingDifferences: false)
            return
        }
        let visibleItems = next.displaysRows ? next.items : []
        let previousItems = itemsByID
        itemsByID = Dictionary(uniqueKeysWithValues: visibleItems.map { ($0.id, $0) })
        let ids: [Item] = [.filter] + visibleItems.map { .conversation($0.id) } + [.footer]
        let oldIDs = source.snapshot().itemIdentifiers
        let existing = Set(oldIDs)
        var changed: [Item] = visibleItems.compactMap { item in
            guard existing.contains(.conversation(item.id)) else { return nil }
            let old = previousItems[item.id]
            return contextChanged || old?.rowModel != item.rowModel || old?.unreadMention != item.unreadMention
                ? .conversation(item.id) : nil
        }
        let reloadFilter = filterChanged && existing.contains(.filter)
        if (next.dynamicFooter || previous?.dynamicFooter == true) && existing.contains(.footer) { changed.append(.footer) }
        if ids != oldIDs || reloadFilter || !changed.isEmpty {
            var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
            snapshot.appendSections([0]); snapshot.appendItems(ids)
            let nextIDSet = Set(ids)
            snapshot.reconfigureItems(changed.filter { nextIDSet.contains($0) })
            if reloadFilter { snapshot.reloadItems([.filter]) }
            source.apply(snapshot, animatingDifferences: false)
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeaderSize()
    }
    private func updateHeaderSize() {
        let width = table.bounds.width
        guard width > 0, headerNeedsMeasurement || abs(measuredHeaderWidth - width) > 0.5 else { return }
        // Clear the dirty flag before measuring: assigning tableHeaderView schedules another layout pass.
        headerNeedsMeasurement = false
        measuredHeaderWidth = width
        #if DEBUG
        ConversationListLayoutDiagnostics.headerMeasurements += 1
        #endif
        let height = headerHost.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)).height
        guard height.isFinite, height > 0,
              abs(headerHost.view.frame.height - height) > 0.5 || abs(headerHost.view.frame.width - width) > 0.5 else { return }
        headerHost.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        table.tableHeaderView = headerHost.view
    }
    public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? { searchHost.view }
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if case .conversation? = source.itemIdentifier(for: indexPath) { return 96 }
        return UITableView.automaticDimension
    }
    public func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        if case .conversation? = source.itemIdentifier(for: indexPath) { return 96 }
        return UITableView.automaticDimension
    }
    public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let width = tableView.bounds.width
        guard width > 0 else { return measuredSearchHeight }
        guard searchNeedsMeasurement || abs(measuredSearchWidth - width) > 0.5 else { return measuredSearchHeight }
        searchNeedsMeasurement = false
        measuredSearchWidth = width
        #if DEBUG
        ConversationListLayoutDiagnostics.searchMeasurements += 1
        #endif
        let height = searchHost.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)).height
        if height.isFinite && height > 0 { measuredSearchHeight = height }
        return measuredSearchHeight
    }
    private func notifyInteraction(_ interacting: Bool) {
        let callback = input?.interactionChanged
        DispatchQueue.main.async { callback?(interacting) }
    }
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        lastScrollMovement = ProcessInfo.processInfo.systemUptime
        guard scrollSettlingTask == nil else { return }
        notifyInteraction(true)
        scrollSettlingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 90_000_000) } catch { return }
                guard let self, !Task.isCancelled else { return }
                guard !table.isTracking, !table.isDragging, !table.isDecelerating,
                      ProcessInfo.processInfo.systemUptime - lastScrollMovement >= 0.18 else { continue }
                scrollSettlingTask = nil
                // Applying a snapshot in UIKit's final layout callback can
                // interrupt the final frames even though isDecelerating is false.
                if let pending { apply(pending) }
                notifyInteraction(false)
                return
            }
        }
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollSettlingTask != nil else { return }
        lastScrollMovement = ProcessInfo.processInfo.systemUptime
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { lastScrollMovement = ProcessInfo.processInfo.systemUptime }
    }
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        lastScrollMovement = ProcessInfo.processInfo.systemUptime
    }
    func stopTrackingScroll() {
        if scrollSettlingTask != nil { notifyInteraction(false) }
        scrollSettlingTask?.cancel()
        scrollSettlingTask = nil
        pending = nil
    }
}

private final class RecycledConversationCell: UITableViewCell {
    private var host: UIHostingController<AnyView>?
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear; contentView.backgroundColor = .clear; selectionStyle = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ content: AnyView, parent: UIViewController) {
        // Fixed-height rows can reuse the same host without asking UIKit to
        // rebuild a hosting configuration or measure its intrinsic height.
        let isConversationRow = reuseIdentifier == "conversation"
        if #available(iOS 16.0, *), !isConversationRow {
            contentConfiguration = UIHostingConfiguration { content }.margins(.all, 0)
            return
        }
        if let host {
            if host.parent == nil { parent.addChild(host); host.didMove(toParent: parent) }
            host.rootView = content
            if !isConversationRow { host.view.invalidateIntrinsicContentSize() }
            return
        }
        let host = UIHostingController(rootView: content)
        self.host = host
        parent.addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: contentView.topAnchor), host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        host.didMove(toParent: parent)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, let host, host.parent != nil {
            host.willMove(toParent: nil)
            host.removeFromParent()
        }
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
        host?.rootView = AnyView(EmptyView())
    }
}

#if DEBUG
@MainActor
public enum ConversationListLayoutDiagnostics {
    public static var rowProjections = 0
    public static var sectionRebuilds = 0
    public static var headerMeasurements = 0
    public static var searchMeasurements = 0
}
#endif
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END
