import Foundation
import IM4Domain
import IM4Stores // WDT_IOS1_CALLS_COMPLETE_STATE_FAMILY_20261111

typealias CallRecordDirection = IM4Domain.CallRecordDirection

typealias CallRecord = IM4Domain.CallRecord

typealias IncomingVoiceCall = IM4Domain.IncomingVoiceCall

typealias VideoCallCameraPosition = IM4Domain.VideoCallCameraPosition

typealias VideoCallPreview = IM4Domain.VideoCallPreview

struct VideoCallTerminalPresentation: Hashable {
    let title: String
    let cause: String
    let nextAction: String

    static func resolve(reason: String, fallback: String = "通话已结束") -> Self {
        let value = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func contains(_ candidates: [String]) -> Bool {
            candidates.contains { value.contains($0) }
        }
        if contains(["reject", "已拒绝"]) {
            return Self(title: "对方已拒绝", cause: "对方没有接听本次通话。", nextAction: "返回聊天")
        }
        if contains(["busy", "忙线"]) {
            return Self(title: "对方正在通话中", cause: "对方当前无法接听。", nextAction: "稍后再试")
        }
        if contains(["timeout", "timed_out", "超时", "未接通"]) {
            return Self(title: "无人接听", cause: "呼叫超时，未建立媒体连接。", nextAction: "返回聊天")
        }
        if contains(["permission", "notallowed", "权限"]) {
            return Self(title: "未获得媒体权限", cause: "麦克风或摄像头权限未开启。", nextAction: "检查权限后重试")
        }
        if contains(["media", "capture", "媒体"]) {
            return Self(title: "媒体设备不可用", cause: "未能安全启用麦克风或摄像头。", nextAction: "检查设备后重试")
        }
        if contains(["license", "未开通"]) {
            return Self(title: "视频通话不可用", cause: "当前企业未开通或已停用视频通话。", nextAction: "返回聊天")
        }
        if contains(["session", "scope", "client_scope_changed", "登录"]) {
            return Self(title: "会话已变更", cause: "账号或企业会话已切换，本次通话已安全结束。", nextAction: "返回聊天")
        }
        if contains(["answered_elsewhere", "其他设备"]) {
            return Self(title: "已在其他设备接听", cause: "本设备不会继续连接媒体。", nextAction: "返回聊天")
        }
        if contains(["failed", "failure", "network_error", "ice_", "连接失败", "恢复失败"]) {
            return Self(title: "通话连接失败", cause: "连接未能恢复，媒体已关闭。", nextAction: "检查网络后重试")
        }
        if contains(["remote", "peer", "callee_hangup", "caller_hangup", "server_signal_terminal", "对方已挂断"]) {
            return Self(title: "对方已挂断", cause: "对方结束了本次通话。", nextAction: "返回聊天")
        }
        if contains(["cancel", "已取消"]) {
            return Self(title: "呼叫已取消", cause: "本次呼叫未接通。", nextAction: "返回聊天")
        }
        if contains(["local_hangup", "user_hangup"]) {
            return Self(title: "通话已结束", cause: "你结束了本次通话，媒体已安全关闭。", nextAction: "返回聊天")
        }
        if contains(["missed", "未接"]) {
            return Self(title: "未接来电", cause: "你没有接听本次视频来电。", nextAction: "返回聊天")
        }
        return Self(title: fallback, cause: "本次通话已结束，媒体已安全关闭。", nextAction: "返回聊天")
    }
}

typealias VideoCallTerminalResult = IM4Domain.VideoCallTerminalResult

extension IM4Domain.VideoCallTerminalResult {
    init(callID: String = "", peer: IMUser, reason: String, fallback: String = "通话已结束", durationText: String = "") {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let presentation = VideoCallTerminalPresentation.resolve(reason: reason, fallback: fallback)
        let id = normalizedCallID.isEmpty
            ? "video-terminal-\(UUID().uuidString)"
            : "video-terminal-\(normalizedCallID)"
        self.init(id: id, callID: normalizedCallID, peer: peer, title: presentation.title,
            cause: presentation.cause, nextAction: presentation.nextAction, reason: reason, durationText: durationText)
    }
}

typealias VoiceCallSession = IM4Stores.VoiceCallSession
