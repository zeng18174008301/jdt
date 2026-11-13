// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

final class ContactDirectoryNativeCell: UITableViewCell {
    private let card = UIView()
    private let divider = UIView()
    private let avatarImage = UIImageView()
    private let avatarInitials = UILabel()
    private let nameLabel = UILabel()
    private let numberLabel = UILabel()
    private let departmentLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(
        systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
    )?.imageFlippedForRightToLeftLayoutDirection())
    private var avatar: ContactDirectoryAvatarRendering?
    private var avatarLoad: Task<Void, Never>?
    private var avatarGeneration: UInt64 = 0
    private var hasAvatarImage = false
    private var maxPixelSize: Int { max(96, Int(ceil(66 * traitCollection.displayScale))) }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        isAccessibilityElement = true
        accessibilityTraits = .button

        card.backgroundColor = .white.withAlphaComponent(0.88)
        card.layer.cornerCurve = .continuous
        contentView.addSubview(card)
        for view in [avatarImage, avatarInitials, nameLabel, numberLabel, departmentLabel, chevron, divider] {
            card.addSubview(view)
        }
        avatarImage.contentMode = .scaleAspectFill
        avatarImage.clipsToBounds = true
        avatarImage.layer.cornerRadius = 22
        avatarImage.layer.borderWidth = 1
        avatarImage.layer.borderColor = UIColor.white.withAlphaComponent(0.65).cgColor
        avatarInitials.font = .systemFont(ofSize: 15, weight: .bold)
        avatarInitials.textColor = .white
        avatarInitials.textAlignment = .center
        avatarInitials.adjustsFontSizeToFitWidth = true
        avatarInitials.minimumScaleFactor = 0.6
        nameLabel.font = .systemFont(ofSize: 16, weight: .black)
        nameLabel.textColor = UIColor(IMColor.ink)
        numberLabel.lineBreakMode = .byTruncatingMiddle
        numberLabel.textColor = UIColor(IMColor.muted)
        departmentLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        departmentLabel.textColor = UIColor(IMColor.muted)
        chevron.contentMode = .scaleAspectFit
        chevron.tintColor = UIColor(IMColor.muted).withAlphaComponent(0.82)
        divider.backgroundColor = UIColor(IMColor.line).withAlphaComponent(0.72)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func bind(_ row: ContactDirectoryRowInput, avatar: ContactDirectoryAvatarRendering?, captionFont: UIFont,
              isFirst: Bool, isLast: Bool) {
        cancelAvatarLoad()
        avatarGeneration &+= 1
        self.avatar = avatar
        accessibilityIdentifier = "contact_row_\(row.id)"
        accessibilityLabel = row.accessibilityLabel
        nameLabel.text = row.displayName
        numberLabel.text = row.userNumber.map { "用户编号：\($0)" }
        numberLabel.isHidden = row.userNumber == nil
        if numberLabel.font != captionFont { numberLabel.font = captionFont }
        departmentLabel.text = row.departmentSummary
        departmentLabel.isHidden = row.departmentSummary == nil
        divider.isHidden = isLast
        var corners: CACornerMask = []
        if isFirst { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if isLast { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        card.layer.maskedCorners = corners
        card.layer.cornerRadius = corners.isEmpty ? 0 : 22

        let cached = avatar?.cachedImage(maxPixelSize: maxPixelSize)
        let cancelled = row.avatarIsCancelled
        let seed = row.avatarSeed
        avatarImage.backgroundColor = cancelled ? UIColor(white: 0.87, alpha: 1) : UIColor(
            red: CGFloat((seed >> 16) & 255) / 255,
            green: CGFloat((seed >> 8) & 255) / 255,
            blue: CGFloat(seed & 255) / 255,
            alpha: 0.76
        )
        avatarImage.image = cached ?? (cancelled ? UIImage(systemName: "person.fill") : nil)
        avatarImage.contentMode = cancelled ? .center : .scaleAspectFill
        avatarImage.tintColor = UIColor(IMColor.muted)
        hasAvatarImage = cached != nil
        avatarInitials.text = String(row.displayName.prefix(2))
        avatarInitials.isHidden = cached != nil || cancelled
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = contentView.bounds.insetBy(dx: 18, dy: 0)
        let width = card.bounds.width
        let height = card.bounds.height
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func leading(_ inset: CGFloat, width itemWidth: CGFloat) -> CGFloat {
            rtl ? width - inset - itemWidth : inset
        }
        avatarImage.frame = CGRect(x: leading(14, width: 44), y: floor((height - 44) / 2), width: 44, height: 44)
        avatarInitials.frame = avatarImage.frame.insetBy(dx: 3, dy: 0)
        chevron.frame = CGRect(x: rtl ? 14 : width - 24, y: floor((height - 14) / 2), width: 10, height: 14)
        let textWidth = max(0, width - 106)
        let nameHeight = ceil(nameLabel.font.lineHeight)
        let numberHeight = numberLabel.isHidden ? 0 : ceil(numberLabel.font.lineHeight)
        let departmentHeight = departmentLabel.isHidden ? 0 : ceil(departmentLabel.font.lineHeight)
        let numberSpacing: CGFloat = numberHeight == 0 ? 0 : 5
        let departmentSpacing: CGFloat = departmentHeight == 0 ? 0 : 5
        let y = floor((height - nameHeight - numberHeight - departmentHeight - numberSpacing - departmentSpacing) / 2)
        let x = leading(70, width: textWidth)
        nameLabel.frame = CGRect(x: x, y: y, width: textWidth, height: nameHeight)
        numberLabel.frame = CGRect(x: x, y: nameLabel.frame.maxY + numberSpacing, width: textWidth, height: numberHeight)
        departmentLabel.frame = CGRect(x: x, y: numberLabel.frame.maxY + departmentSpacing, width: textWidth, height: departmentHeight)
        let pixel = 1 / max(1, traitCollection.displayScale)
        divider.frame = CGRect(x: rtl ? 0 : 62, y: height - pixel, width: max(0, width - 62), height: pixel)
    }

    func loadAvatarIfNeeded() -> Bool {
        guard !hasAvatarImage, avatarLoad == nil, let avatar else { return false }
        let generation = avatarGeneration
        let pixelSize = maxPixelSize
        avatarLoad = Task { [weak self] in
            let image = await avatar.load(maxPixelSize: pixelSize)
            guard let self, !Task.isCancelled, avatarGeneration == generation else { return }
            avatarLoad = nil
            guard let image, avatar.authorized() else { return }
            avatarImage.image = image
            avatarInitials.isHidden = true
            hasAvatarImage = true
        }
        return true
    }

    func cancelAvatarLoad() {
        avatarLoad?.cancel()
        avatarLoad = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelAvatarLoad()
        avatar = nil
        avatarImage.image = nil
    }
}

final class ContactDirectoryCell: UITableViewCell {
    private var host: UIHostingController<AnyView>?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ rootView: AnyView, parent: UIViewController, selfSizing: Bool = false) {
        if let host {
            if host.parent == nil {
                parent.addChild(host)
                host.didMove(toParent: parent)
            }
            host.rootView = rootView
            if selfSizing { host.view.invalidateIntrinsicContentSize() }
            return
        }
        let host = UIHostingController(rootView: rootView)
        self.host = host
        parent.addChild(host)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
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
}

struct ContactListCardEdge: Shape {
    let roundsTop: Bool
    let roundsBottom: Bool

    func path(in rect: CGRect) -> Path {
        var corners: UIRectCorner = []
        if roundsTop { corners.formUnion([.topLeft, .topRight]) }
        if roundsBottom { corners.formUnion([.bottomLeft, .bottomRight]) }
        guard !corners.isEmpty else { return Path(rect) }
        return Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                                 cornerRadii: CGSize(width: 22, height: 22)).cgPath)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
