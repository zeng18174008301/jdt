// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct DepartmentManagementContent<Chooser: View, Department: View, Members: View>: View {
    @Binding var showDeleteConfirmation: Bool
    let onDelete: () -> Void
    let departmentChooser: () -> Chooser
    let selectedDepartmentPanel: () -> Department
    let memberPanel: () -> Members

    public init(showDeleteConfirmation: Binding<Bool>, onDelete: @escaping () -> Void,
                @ViewBuilder departmentChooser: @escaping () -> Chooser,
                @ViewBuilder selectedDepartmentPanel: @escaping () -> Department,
                @ViewBuilder memberPanel: @escaping () -> Members) {
        _showDeleteConfirmation = showDeleteConfirmation
        self.onDelete = onDelete
        self.departmentChooser = departmentChooser
        self.selectedDepartmentPanel = selectedDepartmentPanel
        self.memberPanel = memberPanel
    }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(symbol: "building.2.fill", title: "部门管理", subtitle: "编辑组织架构和部门成员。", showsCloseButton: true)
                departmentChooser()
                selectedDepartmentPanel()
                memberPanel()
            }
            .padding(20)
        }
        .background(IMColor.page.ignoresSafeArea())
        .confirmationDialog("删除部门", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除并迁移成员", role: .destructive) {
                onDelete()
            }
            Button("取消", role: .cancel) {
                showDeleteConfirmation = false
            }
        } message: {
            Text("该部门成员和子部门会自动迁移到上一级部门。")
        }
    }
}

public struct DepartmentManagementChooserContent<Choices: View>: View {
    let isEmpty: Bool
    let choices: () -> Choices

    public init(isEmpty: Bool, @ViewBuilder choices: @escaping () -> Choices) {
        self.isEmpty = isEmpty
        self.choices = choices
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("部门")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.muted)
            if isEmpty {
                EmptyStateView(symbol: "building.2.crop.circle", title: "暂无组织架构", subtitle: "可先刷新后再管理。")
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        choices()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

public struct DepartmentManagementChoiceContent: View {
    let name: String
    let isVirtual: Bool
    let depth: Int
    let selected: Bool
    let onSelect: () -> Void

    public init(name: String, isVirtual: Bool, depth: Int, selected: Bool, onSelect: @escaping () -> Void) {
        self.name = name
        self.isVirtual = isVirtual
        self.depth = depth
        self.selected = selected
        self.onSelect = onSelect
    }

    public var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isVirtual ? "building.2.fill" : "folder.fill")
                    .font(.system(size: 12, weight: .black))
                Text(name)
                    .font(.system(size: 13, weight: .black))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? .white : IMColor.ink)
            .padding(.leading, 12 + CGFloat(max(depth, 0)) * 6)
            .padding(.trailing, 12)
            .frame(height: 36)
            .background(Capsule().fill(selected ? IMColor.brand : .white.opacity(0.86)))
            .overlay(Capsule().stroke(selected ? IMColor.brand.opacity(0.2) : .white.opacity(0.72), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

public struct DepartmentManagementEditorContent: View {
    @Binding var departmentNameDraft: String
    @Binding var childDepartmentName: String
    let name: String
    let memberCount: Int
    let isCompanySelected: Bool
    let isSaving: Bool
    let onSave: () -> Void
    let onCreate: () -> Void
    let onDelete: () -> Void

    public init(departmentNameDraft: Binding<String>, childDepartmentName: Binding<String>, name: String,
                memberCount: Int, isCompanySelected: Bool, isSaving: Bool, onSave: @escaping () -> Void,
                onCreate: @escaping () -> Void, onDelete: @escaping () -> Void) {
        _departmentNameDraft = departmentNameDraft
        _childDepartmentName = childDepartmentName
        self.name = name
        self.memberCount = memberCount
        self.isCompanySelected = isCompanySelected
        self.isSaving = isSaving
        self.onSave = onSave
        self.onCreate = onCreate
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: isCompanySelected ? "building.2.fill" : "folder.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(isCompanySelected ? IMColor.brand : IMColor.violet)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill((isCompanySelected ? IMColor.brand : IMColor.violet).opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    Text("\(memberCount) 人")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                Spacer()
            }

            if !isCompanySelected {
                FormInput(title: "部门名称", placeholder: "输入部门名称", text: $departmentNameDraft)
                PrimaryButton(title: isSaving ? "保存中..." : "保存部门", systemImage: "checkmark.circle.fill", disabled: isSaving) {
                    onSave()
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除部门", systemImage: "trash.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.danger.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }

            FormInput(title: isCompanySelected ? "新建顶级部门" : "新建子部门", placeholder: "输入部门名称", text: $childDepartmentName)
            PrimaryButton(title: isSaving ? "创建中..." : "添加部门", systemImage: "plus.circle.fill", disabled: isSaving || childDepartmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                onCreate()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.72), lineWidth: 1))
    }
}

public struct DepartmentManagementMembersContent<Rows: View>: View {
    let memberCount: Int
    let isCompanySelected: Bool
    let isSaving: Bool
    let onInvite: () -> Void
    let rows: () -> Rows

    public init(memberCount: Int, isCompanySelected: Bool, isSaving: Bool,
                onInvite: @escaping () -> Void, @ViewBuilder rows: @escaping () -> Rows) {
        self.memberCount = memberCount
        self.isCompanySelected = isCompanySelected
        self.isSaving = isSaving
        self.onInvite = onInvite
        self.rows = rows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("成员")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Spacer()
                Text("\(memberCount)")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.muted)
                if !isCompanySelected {
                    Button {
                        onInvite()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(IMColor.brand))
                            .shadow(color: IMColor.brand.opacity(0.20), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                    .opacity(isSaving ? 0.45 : 1)
                    .accessibilityLabel("邀请成员")
                }
            }

            if memberCount == 0 {
                EmptyStateView(symbol: "person.2.slash", title: "暂无成员", subtitle: isCompanySelected ? "无部门成员会显示在公司下。" : "可从已同步成员中加入。")
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    rows()
                }
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.72), lineWidth: 1))
            }
        }
    }
}

public struct DepartmentManagementMemberRowContent<Avatar: View, Certification: View>: View {
    let displayName: String
    let subtitle: String
    let canRemove: Bool
    let isSaving: Bool
    let onRemove: () -> Void
    let avatar: () -> Avatar
    let certification: () -> Certification

    public init(displayName: String, subtitle: String, canRemove: Bool, isSaving: Bool,
                onRemove: @escaping () -> Void, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification) {
        self.displayName = displayName
        self.subtitle = subtitle
        self.canRemove = canRemove
        self.isSaving = isSaving
        self.onRemove = onRemove
        self.avatar = avatar
        self.certification = certification
    }

    public var body: some View {
        HStack(spacing: 10) {
            avatar()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    certification()
                }
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer()
            if canRemove {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(IMColor.danger)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
