import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

struct ComposerInputBox: View {
    @Binding var text: String
    @Binding var dynamicHeight: CGFloat
    @Binding var selection: NSRange
    let isDisabled: Bool
    // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_INPUT_BOX - 修改开始：输入框暴露开始编辑回调
    let onBeginEditing: () -> Void
    // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_INPUT_BOX - 修改结束：输入框暴露开始编辑回调
    // WDT_CHAT_KEYBOARD_INSET_20261021
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ComposerTextView(
                text: $text,
                dynamicHeight: $dynamicHeight,
                selection: $selection,
                isEditable: !isDisabled,
                // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_INPUT_BOX_PASS - 修改开始：传递开始编辑回调
                onBeginEditing: onBeginEditing,
                // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_INPUT_BOX_PASS - 修改结束：传递开始编辑回调
                // WDT_CHAT_KEYBOARD_INSET_20261021
                onEditingChanged: onEditingChanged
            )
                .frame(height: dynamicHeight)
                .padding(.horizontal, 10)
            if text.isEmpty {
                Text("输入消息")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IMColor.muted.opacity(0.42))
                    .padding(.leading, 16)
                    .padding(.top, 11)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 42)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(im4Hex: 0xF3F5FA)))
    }
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var dynamicHeight: CGFloat
    @Binding var selection: NSRange
    let isEditable: Bool
    // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_TEXT_VIEW - 修改开始：UITextView 暴露开始编辑回调
    let onBeginEditing: () -> Void
    // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_TEXT_VIEW - 修改结束：UITextView 暴露开始编辑回调
    // WDT_CHAT_KEYBOARD_INSET_20261021
    let onEditingChanged: (Bool) -> Void

    private let minHeight: CGFloat = 42
    private let maxHeight: CGFloat = 96

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 15, weight: .semibold)
        textView.textColor = UIColor(Color(im4Hex: 0x111827))
        textView.tintColor = UIColor(Color(im4Hex: 0x5B67FF))
        textView.keyboardType = .default
        textView.returnKeyType = .default
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .none
        textView.smartInsertDeleteType = .yes
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.isScrollEnabled = true
        textView.isEditable = isEditable
        textView.selectedRange = boundedSelection(for: textView.text)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        // Binding publication can synchronously reenter SwiftUI before the owner commits.
        guard !context.coordinator.isPublishingUserEdit else { return }
        // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
        // UIKit's programmatic text replacement must not feed its temporary caret back into the shared owner.
        context.coordinator.isUpdatingView = true
        defer { context.coordinator.isUpdatingView = false }
        // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
        if text.isEmpty, textView.text != text {
            textView.text = text
        } else if textView.markedTextRange == nil, textView.text != text {
            textView.text = text
        }
        // JHT_MOD_BEGIN CHAT_INPUT_TYPE_UI_PERF_BEGIN_TEXT_VIEW_PROPERTY_GUARD - 修改开始：避免输入时重复设置 UITextView 属性
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        let nextTextColor = isEditable ? UIColor(Color(im4Hex: 0x111827)) : UIColor(Color(im4Hex: 0x8A93A8))
        if textView.textColor?.isEqual(nextTextColor) != true {
            textView.textColor = nextTextColor
        }
        // JHT_MOD_END CHAT_INPUT_TYPE_UI_PERF_END_TEXT_VIEW_PROPERTY_GUARD - 修改结束：避免输入时重复设置 UITextView 属性
        let nextSelection = boundedSelection(for: textView.text)
        if textView.markedTextRange == nil, textView.selectedRange != nextSelection {
            textView.selectedRange = nextSelection
        }
        // JHT_MOD_BEGIN CHAT_SEND_UI_PERF_BEGIN_HEIGHT_CALL - 修改开始：复用测高缓存减少重复计算
        recalculateHeight(textView, coordinator: context.coordinator)
        // JHT_MOD_END CHAT_SEND_UI_PERF_END_HEIGHT_CALL - 修改结束：复用测高缓存减少重复计算
//        recalculateHeight(textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // JHT_MOD_BEGIN CHAT_SEND_UI_PERF_BEGIN_HEIGHT_RECALC - 修改开始：输入框测高缓存与无动画高度回写
    private func recalculateHeight(_ textView: UITextView, coordinator: Coordinator) {
        let targetWidth = textView.bounds.width
        guard targetWidth > 0 else { return }
        let text = textView.text ?? ""
        guard coordinator.shouldMeasureHeight(text: text, width: targetWidth) else { return }
        // contentSize can still reflect the previous layout during textViewDidChange.
        let fittingHeight = textView.sizeThatFits(
            CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
        ).height
        let clampedHeight = min(max(fittingHeight, minHeight), maxHeight)
        coordinator.recordHeightMeasurement(
            text: text,
            width: targetWidth
        )
        DispatchQueue.main.async {
            guard coordinator.isCurrentHeightMeasurement(text: text, width: targetWidth) else { return }
            guard abs(dynamicHeight - clampedHeight) > 0.5 else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dynamicHeight = clampedHeight
            }
        }
    }
    // JHT_MOD_END CHAT_SEND_UI_PERF_END_HEIGHT_RECALC - 修改结束：输入框测高缓存与无动画高度回写

    private func boundedSelection(for value: String) -> NSRange {
        let utf16Length = (value as NSString).length
        let location = max(0, min(selection.location, utf16Length))
        let length = max(0, min(selection.length, utf16Length - location))
        return NSRange(location: location, length: length)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var isUpdatingView = false // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110
        var isPublishingUserEdit = false
        // JHT_MOD_BEGIN CHAT_SEND_UI_PERF_BEGIN_HEIGHT_CACHE - 修改开始：记录上次输入框测高条件
        private var lastMeasuredText = ""
        private var lastMeasuredWidth: CGFloat = -1
        // JHT_MOD_END CHAT_SEND_UI_PERF_END_HEIGHT_CACHE - 修改结束：记录上次输入框测高条件

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        // JHT_MOD_BEGIN CHAT_SEND_UI_PERF_BEGIN_HEIGHT_CACHE_API - 修改开始：输入框测高缓存判断
        func shouldMeasureHeight(text: String, width: CGFloat) -> Bool {
            text != lastMeasuredText || abs(width - lastMeasuredWidth) > 0.5
        }

        func isCurrentHeightMeasurement(text: String, width: CGFloat) -> Bool {
            text == lastMeasuredText && abs(width - lastMeasuredWidth) <= 0.5
        }

        func recordHeightMeasurement(
            text: String,
            width: CGFloat
        ) {
            lastMeasuredText = text
            lastMeasuredWidth = width
        }
        // JHT_MOD_END CHAT_SEND_UI_PERF_END_HEIGHT_CACHE_API - 修改结束：输入框测高缓存判断

        // JHT_MOD_BEGIN CHAT_INPUT_TYPE_UI_PERF_BEGIN_SELECTION_GUARD - 修改开始：避免文本变化和光标变化重复回写 selection
        private func updateParentSelectionIfNeeded(_ range: NSRange) {
            guard !NSEqualRanges(parent.selection, range) else { return }
            parent.selection = range
        }
        // JHT_MOD_END CHAT_INPUT_TYPE_UI_PERF_END_SELECTION_GUARD - 修改结束：避免文本变化和光标变化重复回写 selection

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdatingView else { return } // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110
            isPublishingUserEdit = true
            defer { isPublishingUserEdit = false }
            // JHT_MOD_BEGIN CHAT_INPUT_TYPE_UI_PERF_BEGIN_TEXT_CHANGE_GUARD - 修改开始：输入时只回写真正变化的文本和光标
            let nextText = textView.text ?? ""
            if parent.text != nextText {
                parent.text = nextText
            }
            updateParentSelectionIfNeeded(textView.selectedRange)
            // JHT_MOD_END CHAT_INPUT_TYPE_UI_PERF_END_TEXT_CHANGE_GUARD - 修改结束：输入时只回写真正变化的文本和光标
            // JHT_MOD_BEGIN CHAT_SEND_UI_PERF_BEGIN_HEIGHT_CHANGE - 修改开始：文本变化时走缓存测高
            parent.recalculateHeight(textView, coordinator: self)
            // JHT_MOD_END CHAT_SEND_UI_PERF_END_HEIGHT_CHANGE - 修改结束：文本变化时走缓存测高

//            parent.recalculateHeight(textView)
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            // WDT_CHAT_KEYBOARD_INSET_20261021
            parent.onEditingChanged(true)
            // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_DELEGATE - 修改开始：UITextView 开始编辑时通知父级滚动
            parent.onBeginEditing()
            // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_DELEGATE - 修改结束：UITextView 开始编辑时通知父级滚动
        }

        // WDT_CHAT_KEYBOARD_INSET_20261021_BEGIN
        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onEditingChanged(false)
        }
        // WDT_CHAT_KEYBOARD_INSET_20261021_END

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isUpdatingView, textView.markedTextRange == nil else { return } // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110
            // UIKit can move the caret before textViewDidChange commits the same edit.
            // Publishing that caret first can synchronously reapply the owner's older text.
            guard parent.text == (textView.text ?? "") else { return }
            isPublishingUserEdit = true
            defer { isPublishingUserEdit = false }
            // JHT_MOD_BEGIN CHAT_INPUT_TYPE_UI_PERF_BEGIN_SELECTION_CHANGE_GUARD - 修改开始：光标未变化时不触发 SwiftUI 状态更新
            updateParentSelectionIfNeeded(textView.selectedRange)
            // JHT_MOD_END CHAT_INPUT_TYPE_UI_PERF_END_SELECTION_CHANGE_GUARD - 修改结束：光标未变化时不触发 SwiftUI 状态更新
        }
    }
}

