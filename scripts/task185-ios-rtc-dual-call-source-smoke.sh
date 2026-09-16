#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ruby - "$IOS_DIR/BlueStoneIM/FilesRTCViews.swift" <<'RUBY'
source_path = ARGV.fetch(0)
source = File.read(source_path)

def type_body(source, signature)
  start = source.index(signature)
  raise "missing #{signature}" unless start
  brace = source.index("{", start)
  raise "missing body for #{signature}" unless brace
  depth = 0
  source[brace..].each_char.with_index do |character, offset|
    depth += 1 if character == "{"
    depth -= 1 if character == "}"
    return source[brace..(brace + offset)] if depth.zero?
  end
  raise "unterminated #{signature}"
end

def require_exactly_once(source, token)
  count = source.scan(token).length
  raise "expected exactly one #{token.inspect}, found #{count}" unless count == 1
end

def require_tokens(body, signature, tokens)
  tokens.each do |token|
    raise "#{signature} missing #{token.inspect}" unless body.include?(token)
  end
end

entry = type_body(source, "struct RTCEntryView: View")
require_tokens(
  entry,
  "RTCEntryView",
  [
    "requestedCallKind = .voice",
    "requestedCallKind = .video",
    "RTCCallContactPickerSheet(preferredKind: requestedKind)",
    "canStartVoiceCall:",
    "canStartVideoCall:",
    "startCallAfterSheetDismissal(user, kind: selectedKind)"
  ]
)

call_route = type_body(source, "private func scheduleCallAfterSheetDismissal(_ user: IMUser, kind: RTCCallActionKind)")
require_tokens(
  call_route,
  "scheduleCallAfterSheetDismissal",
  [
    "switch kind",
    "case .voice:",
    "state.startOutgoingVoiceCall(to: user)",
    "case .video:",
    "state.startOutgoingVideoCall(to: user)"
  ]
)

picker = type_body(source, "private struct RTCCallContactPickerSheet: View")
require_tokens(
  picker,
  "RTCCallContactPickerSheet",
  [
    "contactCallAction(kind: .voice, user: user)",
    "contactCallAction(kind: .video, user: user)",
    "state.voiceCallUnavailableReason(for: user)",
    "state.videoCallUnavailableReason(for: user)",
    "一对一语音或视频通话"
  ]
)

detail = type_body(source, "private struct RTCCallRecordDetailSheet: View")
require_tokens(
  detail,
  "RTCCallRecordDetailSheet",
  [
    "canStartVoiceCall",
    "canStartVideoCall",
    "voiceUnavailableReason",
    "videoUnavailableReason",
    "redialButton(\n                    kind: .voice",
    "redialButton(\n                    kind: .video",
    "kind.unavailableSystemImage"
  ]
)

call_kind = type_body(source, "private enum RTCCallActionKind")
require_tokens(call_kind, "RTCCallActionKind", ["phone.fill", "video.fill", "phone.slash", "video.slash"])

[
  "rtc_new_voice_call_button",
  "rtc_new_video_call_button",
  "rtc_recent_call_detail_voice_button",
  "rtc_recent_call_detail_video_button"
].each { |identifier| require_exactly_once(source, identifier) }

raise "legacy voice-only picker remained" if source.include?("VoiceCallContactPickerSheet")

puts "TASK185 iOS RTC dual voice/video source smoke passed"
RUBY
