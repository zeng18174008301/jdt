#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ruby - "$IOS_DIR/BlueStoneIM/ChatViews.swift" "$IOS_DIR/BlueStoneIM/AppState.swift" <<'RUBY'
chat_path, app_state_path = ARGV
chat = File.read(chat_path)
app_state = File.read(app_state_path)

def function_body(source, signature)
  start = source.index(signature)
  raise "missing #{signature}" unless start
  brace = source.index("{", start)
  raise "missing body for #{signature}" unless brace
  depth = 0
  source[brace..].each_char.with_index do |char, offset|
    depth += 1 if char == "{"
    depth -= 1 if char == "}"
    return source[brace..(brace + offset)] if depth.zero?
  end
  raise "unterminated #{signature}"
end

def require_order(body, signature, tokens)
  cursor = -1
  tokens.each do |token|
    index = body.index(token)
    raise "#{signature} missing #{token}" unless index
    raise "#{signature} order drifted at #{token}" unless index > cursor
    cursor = index
  end
end

def require_absent(body, signature, tokens)
  tokens.each do |token|
    raise "#{signature} contains stale #{token}" if body.include?(token)
  end
end

mention = function_body(chat, "private func insertMention(_ user: IMUser)")
require_order(
  mention,
  "insertMention",
  [
    "let replacement =",
    "let insertionEnd = input[..<range.lowerBound].utf16.count + replacement.utf16.count",
    "input.replaceSubrange(range, with: replacement)",
    "inputSelection = NSRange(location: insertionEnd, length: 0)"
  ]
)

mention_all = function_body(chat, "private func insertMentionAll()")
require_order(
  mention_all,
  "insertMentionAll",
  [
    "let replacement =",
    "let insertionEnd = input[..<range.lowerBound].utf16.count + replacement.utf16.count",
    "input.replaceSubrange(range, with: replacement)",
    "inputSelection = NSRange(location: insertionEnd, length: 0)"
  ]
)

logout = function_body(app_state, "func logout()")
require_order(
  logout,
  "logout",
  [
    "let logoutContext = apiContext",
    "EmojiPickerPreferenceLifecycle.purgePreviousAuthenticatedScope(",
    "IMAPIContext.clearStoredSession(sessionStore: protectedSessionStore)",
    "apiContext = IMAPIContext.load(sessionStore: protectedSessionStore)",
    "resetAuthenticatedRemoteData(showLoading: false)"
  ]
)
require_absent(logout, "logout", ["IMAPIContext.clearStoredSession()"])

switch_enterprise = function_body(app_state, "func switchEnterprise(_ enterprise: Enterprise)")
require_order(
  switch_enterprise,
  "switchEnterprise",
  [
    "let previousContext = apiContext",
    "EmojiPickerPreferenceLifecycle.purgePreviousAuthenticatedScope(",
    "apiContext.clearIMSessionPreservingPlatform(sessionStore: protectedSessionStore)",
    "resetAuthenticatedRemoteData(showLoading: true)",
    "try await switchPlatformTenant("
  ]
)
require_absent(
  switch_enterprise,
  "switchEnterprise",
  ["apiContext.clearIMSessionPreservingPlatform()"]
)

puts "TASK024 iOS P1 lifecycle/selection source smoke passed"
RUBY
