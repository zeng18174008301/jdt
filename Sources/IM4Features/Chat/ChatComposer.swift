import IM4Domain
import IM4DesignSystem
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
import SwiftUI
import UIKit
import UniformTypeIdentifiers

public enum ChatComposerToolAction: String, Equatable {
    case mediaAttachment
    case fileAttachment
    case voiceCall
    case videoCall
    case contactCard
}

public struct ChatComposerToolDescriptor: Identifiable, Equatable {
    public let action: ChatComposerToolAction
    public let symbol: String
    public let title: String
    public let accessibilityIdentifier: String
    public let accessibilityLabel: String

    public var id: ChatComposerToolAction { action }
}

public func chatComposerToolDescriptors(
    allowsVoiceCall: Bool,
    allowsVideoCall: Bool
) -> [ChatComposerToolDescriptor] {
    var tools = [
        ChatComposerToolDescriptor(
            action: .mediaAttachment,
            symbol: "photo.on.rectangle",
            title: "照片/视频",
            accessibilityIdentifier: "chat_tool_media_attachment",
            accessibilityLabel: "选择照片或视频附件"
        ),
        ChatComposerToolDescriptor(
            action: .fileAttachment,
            symbol: "folder",
            title: "文件",
            accessibilityIdentifier: "chat_tool_file_attachment",
            accessibilityLabel: "选择文件附件"
        )
    ]
    if allowsVoiceCall {
        tools.append(ChatComposerToolDescriptor(
            action: .voiceCall,
            symbol: "phone.fill",
            title: "通话",
            accessibilityIdentifier: "chat_tool_voice_call",
            accessibilityLabel: "发起语音通话"
        ))
    }
    if allowsVideoCall {
        tools.append(ChatComposerToolDescriptor(
            action: .videoCall,
            symbol: "video.fill",
            title: "视频",
            accessibilityIdentifier: "chat_tool_video_call",
            accessibilityLabel: "发起视频通话"
        ))
    }
    tools.append(ChatComposerToolDescriptor(
        action: .contactCard,
        symbol: "person.crop.rectangle",
        title: "名片",
        accessibilityIdentifier: "chat_tool_contact_card",
        accessibilityLabel: "发送联系人名片"
    ))
    return tools
}

// WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110: App/ChatComposerAssembly owns business/observation; text entry uses pure values/actions.
