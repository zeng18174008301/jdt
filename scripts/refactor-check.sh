#!/usr/bin/env bash
set -euo pipefail

# WDT_IOS1_REFACTOR_CHECK_20261110_BEGIN
app_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  refactor-check.sh <booted-simulator-udid> <baseline.xcresult>
  refactor-check.sh --compare-snapshots <baseline.xcresult> <candidate.xcresult>

Use the same simulator model, system version and fixtures for both result bundles.
CODE_SIGNING_ALLOWED defaults to NO for local simulator testing.
REFACTOR_GUARDS can list completed source stages, for example "2 3 4".
USAGE
}

compare_snapshots() (
  set -euo pipefail
  comparison="$(mktemp -d "${TMPDIR:-/tmp}/ios1-refactor-snapshots.XXXXXX")"
  trap 'rm -rf "$comparison"' EXIT
  for label in baseline candidate; do
    if [[ "$label" == baseline ]]; then bundle="$1"; else bundle="$2"; fi
    xcrun xcresulttool export attachments --path "$bundle" \
      --output-path "$comparison/$label" --filter '*.png'
  done
  cat > "$comparison/CompareSnapshots.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

struct TestAttachments: Decodable {
    let testIdentifier: String
    let attachments: [Attachment]
}

struct Attachment: Decodable {
    let exportedFileName: String
    let suggestedHumanReadableName: String
}

struct Pixels: Equatable {
    let width: Int
    let height: Int
    let rgba: [UInt8]
}

func failure(_ message: String) -> NSError {
    NSError(domain: "IOS1SnapshotComparison", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func snapshots(in directory: URL) throws -> [String: URL] {
    let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
    let tests = try JSONDecoder().decode([TestAttachments].self, from: manifest)
    var result: [String: URL] = [:]
    for test in tests {
        for attachment in test.attachments {
            let name = attachment.suggestedHumanReadableName.replacingOccurrences(
                of: "_([0-9]+)_[0-9A-Fa-f-]{36}\\.png$", with: "_$1.png", options: .regularExpression
            )
            let key = "\(test.testIdentifier)/\(name)"
            guard result[key] == nil else { throw failure("Duplicate snapshot \(key)") }
            result[key] = directory.appendingPathComponent(attachment.exportedFileName)
        }
    }
    return result
}

func pixels(at url: URL) throws -> Pixels {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw failure("Cannot decode \(url.lastPathComponent)")
    }
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
    try rgba.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw failure("Cannot create pixel buffer for \(url.lastPathComponent)") }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return Pixels(width: width, height: height, rgba: rgba)
}

do {
    let baseline = try snapshots(in: URL(fileURLWithPath: CommandLine.arguments[1]))
    let candidate = try snapshots(in: URL(fileURLWithPath: CommandLine.arguments[2]))
    guard !baseline.isEmpty else { throw failure("Baseline contains no PNG snapshots") }
    let missing = Set(baseline.keys).subtracting(candidate.keys)
    let extra = Set(candidate.keys).subtracting(baseline.keys)
    guard missing.isEmpty && extra.isEmpty else {
        throw failure("Snapshot sets differ. Missing \(missing.sorted()). Extra \(extra.sorted()).")
    }
    for key in baseline.keys.sorted() {
        guard let before = baseline[key], let after = candidate[key],
              try pixels(at: before) == pixels(at: after) else {
            throw failure("Snapshot pixels changed for \(key)")
        }
    }
    print("PASS: \(baseline.count) PNG snapshots match pixel for pixel.")
} catch {
    print(error.localizedDescription)
    exit(1)
}
SWIFT
  xcrun swift "$comparison/CompareSnapshots.swift" "$comparison/baseline" "$comparison/candidate"
)

if [[ "${1:-}" == --help ]]; then usage; exit 0; fi
if [[ "${1:-}" == --compare-snapshots && $# == 3 ]]; then
  compare_snapshots "$2" "$3"
  exit
fi
if [[ $# != 2 ]]; then usage >&2; exit 2; fi
udid="$1"
baseline="$2"
if [[ ! "$udid" =~ ^[0-9A-Fa-f-]{36}$ ]] ||
   ! xcrun simctl list devices booted | grep -Fq "($udid) (Booted)"; then
  echo "Specify the UDID of the booted test simulator." >&2
  exit 2
fi
if [[ ! -d "$baseline" ]]; then
  echo "Baseline result bundle does not exist." >&2
  exit 2
fi

source_root="$app_root/WenDaTong"
reject_matches() {
  local stage="$1" rc=0
  shift
  rg -n "$@" || rc=$?
  case "$rc" in
    0) echo "Stage $stage source guard failed." >&2; return 1 ;;
    1) return 0 ;;
    *) return "$rc" ;;
  esac
}

# WDT_IOS1_REFACTOR_CHECK_MODULE_GUARDS_20261111_BEGIN
package_sources="$app_root/Sources"
swift_code='(?://[^\n]*|/\*(?s:.*?)\*/|\x22(?:\\.|[^\x22\\])*\x22)(*SKIP)(*F)|'

check_domain_relay() {
  local bodies rc=0
  bodies="$(rg -n -o -U --pcre2 "${swift_code}(?(DEFINE)(?<body>\{(?:[^{}]++|(?&body))*\}))\bfunc\s+bindDomainStores\s*\([^{}]*\)\s*(?&body)" "$source_root" --glob '*.swift')" || rc=$?
  case "$rc" in
    0) reject_matches 2 -U --pcre2 "${swift_code}\bobjectWillChange\s*\.\s*send\s*\(" <<< "$bodies" ;;
    1) return 0 ;;
    *) return "$rc" ;;
  esac
}

check_conversation_model() {
  local model="$package_sources/IM4Domain/ConversationModels.swift" parsed rc=0
  if [[ ! -r "$model" ]]; then
    echo "Stage 3 source guard could not read IM4Domain/ConversationModels.swift." >&2
    return 2
  fi
  # Inspect declarations so a local value or another model's messages stay legal.
  parsed="$(xcrun swiftc -frontend -dump-parse "$model")" || return $?
  awk '
    /^  \(/ {
      in_conversation = /^  \(struct_decl .* "Conversation"([[:space:])]|$)/
      if (in_conversation) found = 1
    }
    in_conversation && /^    \(var_decl .* "messages"([[:space:])]|$)/ {
      print
      has_messages = 1
    }
    END {
      if (!found) exit 2
      if (has_messages) exit 1
    }
  ' <<< "$parsed" || rc=$?
  case "$rc" in
    1) echo "Stage 3 source guard failed: Conversation has a messages property in $model." >&2 ;;
    2) echo "Stage 3 source guard could not locate Conversation in $model." >&2 ;;
  esac
  return "$rc"
}

check_chat_sources() {
  local features="$package_sources/IM4Features" manifest="$app_root/Package.swift"
  local rc=0
  rg -U --pcre2 -q '(?s)\.target\(\s*name:\s*"IM4Features"(?:(?!\n\s*\.(?:target|testTarget)\().)*?sources:\s*\[[^]]*"Chat(?:/[^"]+)?"' "$manifest" || rc=$?
  case "$rc" in
    0) if [[ ! -d "$features/Chat" ]]; then
         echo "Stage 4 source guard could not locate registered IM4Features/Chat sources." >&2
         return 2
       fi ;;
    1) ;;
    *) return "$rc" ;;
  esac
  # Package views cannot depend on AppState. A package-local `state` is fine.
  reject_matches 4 -U --pcre2 "${swift_code}\bAppState\b" "$features" --glob '*.swift' || return $?
}
# WDT_IOS1_REFACTOR_CHECK_MODULE_GUARDS_20261111_END

# WDT_IOS1_REFACTOR_CHECK_CHAT_LEAF_GUARD_20261111_BEGIN
# WDT_IOS1_REFACTOR_CHECK_CHAT_AST_SCOPE_20261111_BEGIN
check_chat_leaf_sources() {
  local files file parsed rc=0
  local -a syntax=()
  local views='ChatView|MessageBubble|ChatComposer|AttachmentDetailSheet'
  # Let the parser identify declaration names, including intervening comments.
  files="$(rg -l -U --pcre2 "${swift_code}\b(?:struct|class|enum|actor|protocol|extension|typealias)\b" \
    "$source_root/WDTFeatures/Chat/WDTChatViews.swift" "$source_root/WDTFeatures/Chat" "$source_root/App" --glob '*.swift')" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) return "$rc" ;;
  esac
  while IFS= read -r file; do
    parsed="$(xcrun swiftc -frontend -dump-parse "$file")" || return $?
    syntax+=("$parsed")
  done <<< "$files"

  # The frontend retains executable interpolation expressions as AST nodes.
  # String segments and comments do not contribute declarations or member reads.
  printf '%s\n' "${syntax[@]}" | LC_ALL=C awk -v views="^($views)$" '
    function quoted(text, prefix) {
      if (!match(text, prefix "\"[^\"]*\"")) return ""
      return substr(text, RSTART + length(prefix) + 1, RLENGTH - length(prefix) - 2)
    }
    function decl_name(text) {
      sub(/^.* range=\[[^]]*\] /, "", text)
      sub(/^((unbound|trailing_semi) )+/, "", text)
      return quoted(text, "")
    }
    function source_range(text, location) {
      if (!match(text, /:[0-9]+:[0-9]+ - line:[0-9]+:[0-9]+\]/)) return 0
      split(substr(text, RSTART + 1, RLENGTH - 2), location, /[^0-9]+/)
      return location[1]
    }
    function parameter_text(location, row, last, text, column, end) {
      last = location[3]
      for (row = location[1]; row <= last; row++) {
        column = row == location[1] ? location[2] : 1
        end = row == last ? location[4] : length(source[row])
        text = text substr(source[row], column, end - column + 1) "\n"
      }
      sub(/\n$/, "", text)
      return text
    }
    function parameter_type(header, scopeId, colon, name, type) {
      gsub(/`/, "", header)
      colon = index(header, ":")
      if (!colon) return
      name = substr(header, 1, colon - 1)
      sub(/[[:space:]]+$/, "", name)
      sub(/^.*[[:space:]]/, "", name)
      type = substr(header, colon + 1)
      sub(/^[[:space:]]*/, "", type)
      while (sub(/^(inout|borrowing|consuming|isolated|sending)[[:space:]]+/, "", type)) {}
      # Peel the same transparent wrappers accepted for parsed nominal types.
      while (1) {
        sub(/^[[:space:]]*/, "", type)
        sub(/[[:space:]?!]*$/, "", type)
        if (substr(type, 1, 1) != "(" || substr(type, length(type)) != ")") break
        type = substr(type, 2, length(type) - 2)
      }
      sub(/^WenDaTong[[:space:]]*\.[[:space:]]*/, "", type)
      if (type ~ /^[[:alpha:]_][[:alnum:]_]*$/)
        parameterTypes[scopeId, name] = type
    }
    function read_parameter_types(text, scopeId, i, token, header, depth, angles, defaultValue, commentDepth) {
      # The parse dump provides the list range, but omits the parameter types.
      if (substr(text, 1, 1) != "(") return
      for (i = 2; i < length(text); i += length(token)) {
        token = substr(text, i, 2)
        if (token == "/*") {
          if (!commentDepth++ && !defaultValue) header = header " "
          continue
        }
        if (commentDepth && token == "*/") {
          commentDepth--
          continue
        }
        token = substr(text, i, 1)
        if (commentDepth) continue
        if (match(substr(text, i), /^(\/\/[^\n]*|"(\\.|[^"\\])*")/)) {
          token = substr(text, i, RLENGTH)
          if (!defaultValue) header = header (token ~ /^\/\// ? " " : token)
          continue
        }
        if (token == "," && !depth && !angles) {
          parameter_type(header, scopeId)
          header = ""
          defaultValue = 0
          continue
        }
        if (token == "=" && !depth && !angles) defaultValue = 1
        if (token ~ /^[([{]$/) depth++
        if (token ~ /^[)\]}]$/) depth--
        if (!defaultValue && token == "<") angles++
        if (angles && token == ">" && substr(text, i - 1, 1) != "-") angles--
        if (!defaultValue) header = header token
      }
      parameter_type(header, scopeId)
    }
    function type_decl(tag) {
      return tag ~ /^(struct|class|enum|actor|protocol|extension)_decl$/
    }
    function receiver_depth(level) {
      while (node[level] ~ /^(bind_optional_expr|force_value_expr|optional_evaluation_expr|paren_expr)$/) level--
      return level
    }
    function nominal_parent(level) {
      while (node[level] ~ /^type_(optional|implicitly_unwrapped_optional|paren)$/) level--
      return level
    }
    function declaration_type(level, type, parent) {
      parent = nominal_parent(level - 1)
      if (view != "" && node[parent] == "pattern_typed" && patternName[parent] != "")
        pending[scope[level], patternName[parent]] = type
      if (aliasId[parent]) aliasTarget[aliasId[parent]] = type
    }
    function is_file_private(access) {
      return access ~ /^(private|fileprivate)$/
    }
    function scoped_id(declarations, owner, file, name, id) {
      id = declarations[owner, file, name]
      return id ? id : declarations[owner, "", name]
    }
    function is_app_state(type, owner, declaringFile, hops, id) {
      for (hops = 0; type != "" && hops <= aliasCount; hops++) {
        if (type == "AppState") return 1
        id = scoped_id(aliases, owner, declaringFile, type)
        if (!id && owner != "") id = scoped_id(aliases, "", declaringFile, type)
        if (!id) return 0
        type = aliasTarget[id]
        owner = aliasOwner[id]
        declaringFile = aliasFile[id]
      }
      return 0
    }
    function new_binding(type, sourceRef, id) {
      id = ++bindingCount
      bindingType[id] = type
      bindingFile[id] = file
      bindingSource[id] = sourceRef
      return id
    }
    function binding_reference(scopeId, name, explicitSelf, key) {
      if (!explicitSelf)
        for (; scopeId != "" && scopeId != view; scopeId = outer[scopeId]) {
          key = scopeId SUBSEP name
          if (key in bindings) return bindings[key]
        }
      # Member declarations can occur later or in another source file.
      return view SUBSEP file SUBSEP name
    }
    function app_state_binding(ref, owner, memberRef) {
      while (ref != "") {
        if (index(ref, SUBSEP)) {
          split(ref, memberRef, SUBSEP)
          ref = scoped_id(memberBindings, memberRef[1], memberRef[2], memberRef[3])
        }
        if (bindingSource[ref] == "")
          return is_app_state(bindingType[ref], owner, bindingFile[ref])
        ref = bindingSource[ref]
      }
      return 0
    }
    function activate_condition_bindings(scopeId, names, count, i, name, type) {
      count = split(conditionNames[scopeId], names, SUBSEP)
      for (i = 1; i <= count; i++) {
        name = names[i]
        type = pending[scopeId, name]
        bindings[scopeId, name] = new_binding(type, type == "" ? conditionSource[scopeId] : "")
        delete pending[scopeId, name]
      }
      if (guardScope[guardDepth] == scopeId && count)
        guardNames[scopeId] = guardNames[scopeId] == "" ? conditionNames[scopeId] : guardNames[scopeId] SUBSEP conditionNames[scopeId]
      delete conditionNames[scopeId]
      delete conditionSource[scopeId]
    }
    function finish_guards(level, scopeId, names, count, i) {
      # Transfer successful guard bindings after the else body leaves the AST.
      while (guardDepth && guardLevel[guardDepth] >= level) {
        scopeId = guardScope[guardDepth--]
        count = split(guardNames[scopeId], names, SUBSEP)
        for (i = 1; i <= count; i++)
          bindings[outer[scopeId], names[i]] = bindings[scopeId, names[i]]
        delete guardNames[scopeId]
      }
    }
    function record_condition_source(level, name, parent, explicitSelf) {
      parent = level - 1
      explicitSelf = name == "self"
      if (explicitSelf && node[parent] == "unresolved_dot_expr")
        name = member[parent--]
      while (node[parent] == "paren_expr") parent--
      if (node[parent] == "pattern" && conditionList[parent - 1])
        conditionSource[scope[level]] = binding_reference(scope[level], name, explicitSelf)
    }
    function record_read(level, name, parent, explicitSelf) {
      parent = receiver_depth(level - 1)
      if (node[parent] != "unresolved_dot_expr") return
      explicitSelf = name == "self"
      if (explicitSelf) {
        name = member[parent]
        parent = receiver_depth(parent - 1)
        if (node[parent] != "unresolved_dot_expr") return
      }
      if (name == "") return
      reads++
      readView[reads] = view
      readName[reads] = name
      readMember[reads] = member[parent]
      readLocation[reads] = file ":" line[level]
      readBinding[reads] = binding_reference(scope[level], name, explicitSelf)
    }
    /^\(source_file / {
      file = quoted($0, "")
      for (row in source) delete source[row]
      row = 0
      while ((readStatus = (getline sourceLine < file)) > 0) source[++row] = sourceLine
      close(file)
      if (readStatus < 0) {
        print "Stage 4 source guard could not read " file > "/dev/stderr"
        sourceError = 2
        exit sourceError
      }
      view = ""
      guardDepth = 0
      next
    }
    /^ +\(/ {
      match($0, /^ +/)
      level = RLENGTH / 2
      finish_guards(level)
      tag = substr($0, RLENGTH + 2)
      sub(/[[:space:])].*/, "", tag)
      sub(/^.*=/, "", tag)
      parent = level - 1
      node[level] = tag
      member[level] = quoted($0, "field=")
      nominal[level] = quoted($0, "id=")
      startLine = source_range($0, location)
      line[level] = startLine ? startLine : line[parent]
      scope[level] = scope[parent]
      patternName[level] = ""
      environment[level] = 0
      aliasId[level] = 0
      valueId[level] = 0
      conditionScope[level] = 0
      conditionList[level] = 0

      if (level == 1) {
        view = ""
        nested = 0
        extensionAccess = ""
        if (type_decl(tag)) {
          name = decl_name($0)
          sub(/^WenDaTong\./, "", name)
          if (name ~ views) view = name
        }
        scope[level] = view
      }
      if (nested && level > nested) next
      nested = 0
      if (level > 1 && type_decl(tag)) {
        nested = level
        next
      }
      if (tag == "typealias" && (level == 1 || (view != "" && level == 2))) {
        id = ++aliasCount
        aliasId[level] = id
        aliasName[id] = decl_name($0)
        aliasOwner[id] = view
        aliasFile[id] = file
        if (parent == 1) aliasAccess[id] = extensionAccess
      }
      if (tag == "access_control_attr") {
        access = $0
        sub(/^.* access_level=/, "", access)
        sub(/[[:space:])].*/, "", access)
        if (aliasId[parent]) aliasAccess[aliasId[parent]] = access
        else if (valueId[parent] in memberOwner) memberAccess[valueId[parent]] = access
        else if (node[parent] == "extension_decl") extensionAccess = access
      }
      if (tag == "type_unqualified_ident") {
        if (node[parent] != "type_qualified_ident")
          declaration_type(level, nominal[level])
        else if (nominal[level] == "WenDaTong")
          declaration_type(parent, nominal[parent])
      }

      if (view == "" || level == 1) next
      if (node[parent] ~ /^(if_stmt|guard_stmt)$/ && $0 ~ /^ +\(conditions=array/) {
        conditionList[level] = 1
        scope[level] = conditionScope[parent] = ++scopeCount
        outer[scope[level]] = scope[parent]
        if (node[parent] == "guard_stmt") {
          guardLevel[++guardDepth] = parent
          guardScope[guardDepth] = scope[level]
        }
      }
      if (conditionList[parent]) activate_condition_bindings(scope[parent])
      if (tag ~ /^(func_decl|constructor_decl|accessor_decl|closure_expr|brace_stmt)$/) {
        scope[level] = ++scopeCount
        outer[scope[level]] = scope[parent]
        if (tag == "brace_stmt" && conditionScope[parent]) {
          activate_condition_bindings(conditionScope[parent])
          if (node[parent] == "if_stmt") outer[scope[level]] = conditionScope[parent]
          conditionScope[parent] = 0
        }
      }
      if (tag == "pattern_named") {
        name = quoted($0, "")
        if (node[parent] == "pattern_typed") patternName[parent] = name
        pattern = parent
        while (node[pattern] ~ /^pattern_(binding|typed)$/) {
          if (node[pattern] == "pattern_typed") patternName[pattern] = name
          pattern--
        }
        if (node[pattern] == "pattern" && conditionList[pattern - 1]) {
          key = scope[level]
          conditionNames[key] = conditionNames[key] == "" ? name : conditionNames[key] SUBSEP name
        }
      }
      if (tag == "var_decl" && $0 ~ / range=\[/) {
        name = decl_name($0)
        id = valueId[level] = new_binding(pending[scope[level], name])
        if (scope[level] == view) {
          memberIds[++memberCount] = id
          memberOwner[id] = view
          memberName[id] = name
          memberAccess[id] = extensionAccess
        } else {
          bindings[scope[level], name] = id
        }
        delete pending[scope[level], name]
      }
      if (tag == "parameter_list" && startLine)
        read_parameter_types(parameter_text(location), scope[level])
      if (tag == "parameter" && $0 !~ /\(parameter "self"/) {
        name = quoted($0, "")
        bindings[scope[level], name] = new_binding(parameterTypes[scope[level], name])
      }
      if (tag == "type_unqualified_ident" && node[parent] == "custom_attr" && nominal[level] == "Environment")
        environment[parent] = 1
      if (tag == "unresolved_decl_ref_expr") {
        name = quoted($0, "name=")
        # Recognize @Environment(AppState.self), including a qualified type.
        dot = parent
        type = name
        if (name == "WenDaTong" && node[dot] == "unresolved_dot_expr") {
          type = member[dot]
          dot--
        }
        if (node[dot] == "dot_self_expr") {
          attribute = dot - 1
          while (node[attribute] ~ /^(argument|argument_list)$/) attribute--
          if (environment[attribute] && node[attribute - 1] == "var_decl")
            bindingType[valueId[attribute - 1]] = type
        }
        record_condition_source(level, name)
        record_read(level, name)
      }
    }
    END {
      if (sourceError) exit sourceError
      for (id = 1; id <= aliasCount; id++)
        aliases[aliasOwner[id], (is_file_private(aliasAccess[id]) ? aliasFile[id] : ""), aliasName[id]] = id
      for (i = 1; i <= memberCount; i++) {
        id = memberIds[i]
        memberBindings[memberOwner[id], (is_file_private(memberAccess[id]) ? bindingFile[id] : ""), memberName[id]] = id
      }
      for (r = 1; r <= reads; r++) {
        if (!app_state_binding(readBinding[r], readView[r])) continue
        finding = readLocation[r] ": " readView[r] " reads " readName[r] "." readMember[r]
        if (!reported[finding]++) print finding
        failed = 1
      }
      if (failed) {
        print "Stage 4 source guard failed: mounted chat Views read AppState." > "/dev/stderr"
        exit 1
      }
    }
  '
}
# WDT_IOS1_REFACTOR_CHECK_CHAT_AST_SCOPE_20261111_END
# WDT_IOS1_REFACTOR_CHECK_CHAT_LEAF_GUARD_20261111_END

for guard in ${REFACTOR_GUARDS:-}; do
  case "$guard" in
    2)
      reject_matches 2 '@Published\b' "$source_root/App/WDTAppState.swift"
      reject_matches 2 'func scheduleDomainStoreObjectWillChangeForward' "$source_root" --glob '*.swift'
      # WDT_IOS1_REFACTOR_CHECK_MODULE_GUARDS_20261111_BEGIN
      check_domain_relay
      reject_matches 2 -U --pcre2 "${swift_code}\bAppState\b" "$source_root/WDTDesignSystem/WDTDesignSystem.swift" "$source_root/WDTDesignSystem" --glob '*.swift'
      # WDT_IOS1_REFACTOR_CHECK_MODULE_GUARDS_20261111_END
      ;;
    3)
      # WDT_IOS1_REFACTOR_CHECK_MODULE_GUARDS_20261111_BEGIN
      check_conversation_model
      reject_matches 3 -U --pcre2 "${swift_code}\bconversations\s*\[[^\]\n]+\]\s*\.\s*messages(?:\s*\[[^\]\n]+\])?\s*(?:=(?!=)|[+*/%&|^-]=|\.\s*(?:append|insert|remove(?:All|First|Last|Subrange)?|replaceSubrange|reverse|sort|swapAt)\s*\()" \
        "$source_root" "$package_sources" --glob '*.swift'
      # WDT_IOS1_REFACTOR_CHECK_MODULE_GUARDS_20261111_END
      ;;
    4)
      check_chat_sources # WDT_IOS1_REFACTOR_CHECK_MODULE_GUARDS_20261111
      check_chat_leaf_sources # WDT_IOS1_REFACTOR_CHECK_CHAT_LEAF_GUARD_20261111
      ;;
    *) echo "Unknown source guard: $guard" >&2; exit 2 ;;
  esac
done

result="$(mktemp -d "${TMPDIR:-/tmp}/ios1-refactor-check.XXXXXX")"
printf 'Verification evidence: %s\n' "$result"
common=(-project "$app_root/WenDaTong.xcodeproj" -scheme WenDaTong
        -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$result/DerivedData"
        -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution
        "CODE_SIGNING_ALLOWED=${CODE_SIGNING_ALLOWED:-NO}")
status=0
xcodebuild "${common[@]}" -configuration Release build || status=1
xcodebuild "${common[@]}" -configuration Debug -parallel-testing-enabled NO \
  -resultBundlePath "$result/candidate.xcresult" test || status=1
for configuration in Debug Release; do
  plist="$result/DerivedData/Build/Products/$configuration-iphonesimulator/WenDaTong.app/Info.plist"
  if [[ ! -f "$plist" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$plist")" != 15.0 ]]; then
    echo "$configuration product did not verify MinimumOSVersion 15.0." >&2
    status=1
  fi
done
compare_snapshots "$baseline" "$result/candidate.xcresult" || status=1
exit "$status"
# WDT_IOS1_REFACTOR_CHECK_20261110_END
