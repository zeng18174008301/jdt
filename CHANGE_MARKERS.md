# APP 合同改动记录

## 范围与基线

- 工程：`/Users/zen/Desktop/jdt`。
- 依据：`/Users/zen/Downloads/APP改动方案与接口合同.md`，V1.1，2026-10-21。
- 本次开始时工作区干净；基线 commit：`4a5938783f764a1d3c0f953fd4b084bab5ae34e7`。本次没有提交 Git。
- 第 5 项以用户最新说明覆盖文档中的“群名称（人数）”：人数是群名后的独立数字标签，不能被长群名遮挡。
- 未修改 Android、服务端、codemagic、登录/Token 实现、RTC 通话信令或接通/挂断实现。`FilesRTCViews.swift` 的变动仅涉及文件下载/预览/分享。

## 第 5 项最终规则

1. 开关开启、当前作用域策略与服务端总数已就绪：会话列表在群名后展示数字标签；标签固定宽度布局、优先保留，群名可截断。
2. 关闭：会话列表、群聊天顶部、群详情、群成员页隐藏人数；管理员总数等统计也一并隐藏。
3. 策略未知、读取失败或总数未知：不显示人数，不用已加载成员数、预览头像数或旧缓存推算，也不填假 0。
4. 沿用现有账号/企业隔离及 authoritative/generation 合同；切换隐藏状态后刷新相关展示缓存，重新开启时重新获取总数。
5. 人数隐藏时继续使用现有无总数游标分页，不改变成员列表、权限与成员操作规则。

## 标记与对应模块

搜索统一前缀：`WDT_APP_CONTRACT_20261021`。标记位于关键入口，并非每一行修改都有注释；完整范围以本次 Git diff 为准。

| 标记 / 条目 | 内容 | 主要文件 |
| --- | --- | --- |
| `_01_08`、`_01_09`；1–8 | 消息动作严格布尔解析，普通账号操作门禁，当前会话配置刷新，失败策略，提醒开关 | `Core/AppSupport/InteractionPolicy/AppInteractionPolicy.swift`、`AppState.swift`、`RemoteAPIModels.swift`、`Core/AppSupport/AppState+MessageActions.swift`、`AppState+ContactsInboxDevices.swift`、`AppState+GroupAdministration.swift`、`AppState+RemoteErrorHandling.swift` |
| `_05`；5 | 会话数字标签、四处人数隐藏、去除预览数/旧总数推算 | `ConversationViews.swift`、`ContactsViews.swift`、`ChatViews.swift`、`ConversationStore.swift`、`Core/AppSupport/GroupFileMapping/AppState+RemoteGroupFileMapping.swift`、`AppStateLocalSupport.swift` |
| `_08`；8 | 只过滤展示中的删除/撤回占位、编辑标记和成功提示；保留存储状态、确认及错误 | `ChatViews.swift`、`ConversationViews.swift`、`Core/AppSupport/InteractionPolicy/AppInteractionPolicy.swift`、`AppState+MessageActions.swift` |
| `_09_11`、`_09`；9、11 | 群来源加好友开关、revision 更新、成员矩阵与角色标记、复用成员/资料页 | `GroupDetails/GroupDetailMembers.swift`、`ContactsViews.swift`、`ChatViews.swift`、`Models.swift`、`RemoteAPIModels.swift`、`Core/Networking/IMAPIClient+Groups.swift`、`IMAPIClient+Contacts.swift`、`Core/AppSupport/AppState+Realtime.swift` |
| `_10`；10 | 真实字节进度、未知长度状态、保存校验阶段、跨入口任务去重/取消、缓存复用 | `FileStore.swift`、`Core/AppSupport/AppState+FilesAttachments.swift`、`AppStateLocalSupport.swift`、`FilesRTCViews.swift`、`ChatViews.swift`、`ContactsViews.swift` |
| `_12`；12 | 普通群成员邀请入口、按服务端实际结果反馈邀请状态 | `ContactsViews.swift`、`RemoteAPIModels.swift`、`Core/AppSupport/AppState+GroupAdministration.swift` |
| `_13`；13 | 群详情不预加载全部二级数据；成员懒加载布局；复用筛选/排序结果 | `ContactsViews.swift` |
| `_14`；14 | 空白公告/描述仅在展示层使用占位文案 | `ContactsViews.swift` |

文件路径均相对于 `BlueStoneIM/`。作用域重置/前台刷新入口还涉及 `AppState+SearchConversationSettings.swift`、`AppStatePolicySupport.swift`、`RemoteSync/AppState+RemoteRegistrationSnapshotSync.swift`。Xcode 工程仅登记两个新 Swift 文件。

## 保留的边界

- 撤回/编辑/转发开关不替代原有发送者、消息类型、时间窗、revision、幂等与服务端权限检查；关闭的适用菜单保留名称图标并置灰。
- 普通号退群/删好友/拉黑与群角色分开判断；内部号仅按合同豁免这三个普通号限制。解除拉黑、群主转让/解散规则保持原流程。
- 提醒开关仅改变展示，不删除 tombstone，不改同步游标，不匹配用户消息文本来隐藏内容。
- 群来源加好友增加来源参数；非群来源仍走原接口参数。群设置只提交目标布尔值与现有 revision，不整包覆盖其他设置。
- 下载继续复用签名地址刷新、完整性校验和缓存提交；文件传输、校验、预览生成沿用后台 helper，MainActor 负责状态发布。没有给公开媒体入口新增登录门禁。
- 邀请是否需要审批仍由原接口决定，不把选中人数当作已加入人数。

## 后端待联调

文档明确以下为待新增合同，本次只接入 iOS 读取与展示，不表示生产服务端已经支持：

- 第 4/6/7 项：`tenant_policy.group.allow_member_group_leave`、`tenant_policy.relationship.allow_member_friend_delete`、`allow_member_blacklist`。缺失/失败时普通号入口隐藏，不能默认放行。
- 第 8 项：`tenant_policy.message.processing_notice_enabled`。旧服务端缺字段时兼容原提醒；当前会话已收到的 false 不因临时失败或缺字段恢复为 true。
- 上线前核验实际 `/api/tenant/policy`、`/api/tenant/files/config`、群 summary/settings 返回与文档一致。不能将编译成功当作后端联调完成。

## 验证与真机清单

- 应用与 XCTest 目标已通过 `build-for-testing` 编译；没有启动模拟器、安装或运行 App。
- 对实际生产源码中的纯策略/下载进度类型执行了 24 项宿主 Swift 断言，覆盖 effective/旧字段/非法布尔值、账号角色、真实字节/未知长度/保存阶段，全部通过。这不是完整 XCTest 执行。
- 补充了 `RemoteAPIModelsTests`、`DomainStoreTests`、`HTTPTransportTests`、`DesignSystemTests`、`AttachmentDownloadTests`。完整 XCTest 和 UI 自动化尚未运行。
- 第 13 项目前仅针对可见的重复工作做有限优化，尚未做 Instruments 真机采样，不能认定所有卡顿根因已解决。

编译命令（在工程根目录执行）：

```sh
DEVELOPER_DIR=/Users/zen/Downloads/Xcode.app/Contents/Developer xcodebuild -quiet -project BlueStoneIM.xcodeproj -scheme BlueStoneIM -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build-for-testing
```

仍需真机/联调验收：

1. 开关 true/false/缺失/失败；前后台、切换账号企业、迟到响应；菜单已打开后后台修改开关。
2. 长群名、大人数、四处人数同步隐藏；隐藏时管理员/已加载统计不泄露；重新开启后的权威总数。
3. 普通号/内部号与 owner/admin/member 组合；解除拉黑；原有退群、解散、邀请审批和部分成功结果。
4. 消息处理提醒关闭后的当前消息、历史、引用、置顶、搜索和会话摘要；再次开启；确认及失败反馈保留。
5. 群来源与非群来源资料页；互加好友关闭、开启、revision 冲突、后台更新。
6. 大文件已知/未知长度、断网重试、取消后重试、签名过期、校验失败、文件版本变化、缓存命中；聊天/文件/群文件/分享同时下载同一资源；账号切换时任务和 UI 不串状态。
7. 群成员多页滚动、头像矩阵与普通成员邀请；iPhone/iPad 页面布局；群详情与二级页真机性能。

## 按标记回退

- 先保存当前工作副本，再用上述基线与工作区 diff 按功能挑选反向补丁；不要整仓 reset，也不要仅删除标记注释。
- 1–9 的状态模型、接口解码、动作门禁、展示调用与对应测试互相依赖，回退某项时须同时检查这些入口。
- 第 10 项的 `FileStore`、下载 executor、AppState 下载编排和各文件 UI 是一组；不要只回退进度模型。
- 删除新增 Swift 文件时，同步处理 `project.pbxproj` 的引用；保留已有其他修改及旧标记。
- 回退后重新执行编译和对应真机用例。本记录不是自动回滚脚本。

## 群详情布局补充（2026-10-21）

标记：`WDT_GROUP_DETAIL_LAYOUT_20261021`。按用户提供的布局图调整比例与留白，不修改业务条件。

- 保留“群信息 → 成员矩阵 → 操作菜单”顺序及所有已有菜单、动作和权限判断。
- 菜单使用群详情专属行样式，最小高度 72pt；整行可点，分组间添加细分隔线与间距，不修改全局 `SettingsRow`。
- 群名、公告、描述自然换行；角色标记放在群信息文字下方，为长群名保留空间。编辑与关闭按钮点击尺寸为 44pt。
- 成员矩阵继续每行 5 个，最多 19 位成员加成员列表入口；头像 44pt，姓名最多两行，增加行间距。
- 页面区块间距 20pt，宽屏内容居中且限制最大宽度，底部增加留白。解散/退群仍使用原确认与权限流程。
- 本轮仅改 `ContactsViews.swift` 的群详情布局、`GroupDetails/GroupDetailMembers.swift` 的展示样式，新增 `GroupDetails/GroupDetailLayout.swift` 并登记工程引用。
- 回退本轮时只反向应用这些布局改动与工程引用，不回退上一轮 APP 合同功能。仅编译验证，不运行模拟器；视觉效果仍需真机确认。

## 会话列表排序补充（2026-10-21）

标记：`WDT_CONVERSATION_LIST_SORT_20261021`。修改工程仅为 `/Users/zen/Desktop/jdt`；安卓工程仅供读取参考，没有修改。

### 原因与范围

- iOS 原有消息删除流程会更新摘要，但存储排序时间使用 `max(原时间, 剩余消息时间)`，删除末条消息后无法回退。本轮保留该存储流程，只修正会话列表的只读时间计算。
- 生产代码仅修改 `BlueStoneIM/ConversationViews.swift`。不改消息删除、撤回、发送、消息摘要、未读数、同步游标、数据库、接口、通话及置顶分组规则。
- 本地已包含最新消息时，列表按最后一条未删除的已确认消息时间排序；行内时间使用同一来源，避免显示时间与排序依据不一致。
- 撤回占位仍沿用原消息时间，不使用撤回操作发生时间，也不改变撤回占位的展示策略。
- 发送中/失败的本地末条消息、系统会话、未加载最新消息、消息时间缺失时沿用原回退方式。仅用于置顶上下文的消息不参与排序计算。
- 连续删除末条消息时向前寻找剩余消息；遇到序号缺口或未加载的更早历史，不擅自把会话视为空。只有已确认可见历史全部删除时，列表时间归零并清空行内时间，不清空存储字段。
- 缓存签名纳入计算后的消息时间，使删除后的排序变更能触发列表刷新。置顶会话仍在置顶分组，分组内按时间倒序，相同时间继续按原 ID 规则排序。

### 验证

- 新增 8 个 `DomainStoreTests` 用例，覆盖删除、撤回、失败发送删除、历史缺口、置顶上下文、空会话、显示时间和系统会话边界。
- 使用实际生产函数、最小模型桩执行 24 项宿主 Swift 断言，全部通过；这是独立函数检查，不是完整 App/XCTest 运行。
- 应用与测试目标通过 `build-for-testing` 编译，退出码 0。日志：`/tmp/jdt-conversation-sort-build.log`。未启动模拟器，未运行 App 或完整 XCTest。
- 仍需真机验证跨会话时间顺序、删除末条/较早消息、撤回、置顶与取消置顶、重新进入页面，以及历史加载后刷新。未完整加载消息的会话仍依赖原服务端/缓存时间，本轮不改服务端映射或存储同步。

### 单独回退

按 `WDT_CONVERSATION_LIST_SORT_20261021` 标记撤回新增时间函数、列表排序/行时间调用及缓存签名字段，并撤回对应测试区块即可。保留同文件中之前的 `WDT_APP_CONTRACT_20261021` 群人数与提醒开关修改，不回退 `ConversationStore.swift` 的既有群人数修改，不做整文件覆盖或整仓重置。

## 聊天键盘收起补充（2026-10-21）

标记：`WDT_CHAT_KEYBOARD_INSET_20261021`。只修改 `jdt` 的聊天键盘交互和布局；安卓未修改。

- 点击聊天区域空白处继续使用原有收键盘手势，手势限定在消息区域，不包裹输入栏、发送和工具按钮。
- iOS 16 及以上的消息滚动改用 `.scrollDismissesKeyboard(.immediately)`；所有支持版本在识别到纵向拖动开始时显式收起键盘，兼顾短列表不能正常滚动的情况。
- `ComposerTextView` 将开始/结束编辑状态经输入栏回传到 `ChatView`，不通过清空草稿或重新创建消息列表来收起键盘。
- 输入框和聊天搜索框均未编辑时，聊天容器不保留键盘底部避让；任一正在编辑时仍使用系统自动避让。仅处理 `.keyboard`，不忽略设备底部安全区，参见 [Apple 键盘安全区说明](https://developer.apple.com/documentation/swiftui/safearearegions/keyboard)。
- 本轮生产代码只涉及 `ChatViews.swift`。消息发送、删除、撤回、排序、未读处理、历史加载和滚动仲裁业务保持原实现；键盘导致的尺寸变化仍交给原有布局处理。
- 新增 2 个键盘避让策略测试、1 个回调/手势接线测试，并更新原键盘手势接线断言。应用和测试目标 `build-for-testing` 编译成功，日志 `/tmp/jdt-chat-keyboard-build.log`。
- 对生产策略函数及源码接线运行 45 项宿主检查，通过；未启动模拟器，未运行 App/完整 XCTest 或真机 UI 测试。
- 待真机确认：输入草稿后点击空白、轻微上下滑动、消息少时滑动、重复唤起/收起、搜索框输入、表情/工具/语音切换；确认键盘及底部空白收起，输入栏恢复到底部，草稿仍在且按钮可正常使用。

单独回退：按标记撤回 `ChatViews.swift` 的编辑状态回传、键盘安全区处理和拖动收起修改，恢复原 `chatScrollDismissesKeyboardInteractively` 名称/调用与 iOS 版本分支，同步回退对应测试。保留之前的 APP 合同、群详情布局和会话排序修改。

## 消息删除即时刷新（2026-10-21）

标记：`WDT_CHAT_DELETE_REFRESH_20261021`。仅修改 `/Users/zen/Desktop/jdt` 的聊天展示缓存，不修改安卓。

- 问题：行缓存快速复用只检查条数与首尾消息，中间消息变为删除状态时仍可能返回旧行；历史页增量复用也只检查首尾，可能保留中间消息的旧缓存签名。
- 调整：上述两处缓存复用前，逐条核对消息 ID 和删除标记。发现删除或消息身份变化时，使用原有完整重建路径，更新展示快照及时间线缓存标识，不等滑动或重新进入页面。未变化时仍复用缓存，历史分页仍保留增量路径。
- 只比较轻量字段，使用惰性映射和切片，不增加完整消息深比较、请求、轮询、强制滚动或整页重建。
- 不修改删除接口、权限、确认弹窗、服务端成功/失败处理、撤回、未读数、排序、同步及持久化；仍在原删除流程更新数据后刷新展示，不提前假定删除成功。
- 用户已取消的“隐藏原消息已删除提示”修改没有实施。本轮保留原有处理提醒开关和删除占位展示规则，不清除底层删除记录。
- 生产代码仅涉及 `BlueStoneIM/ChatViews.swift`；在 `BlueStoneIMTests/DomainStoreTests.swift` 新增 3 个用例，覆盖中间删除、物理移除、同条数替换、空列表及历史追加期间删除，并确认原提示策略保持不变。
- 应用和测试目标 `build-for-testing` 编译通过，退出码 0；日志 `/tmp/jdt-delete-refresh-build.log`。有既有弃用及并发警告，本轮没有扩大范围处理。
- 从修改前后源码提取实际缓存函数，配合最小模型桩运行 28 项宿主检查，全部通过，并复现旧缓存漏检中间删除状态；这不是完整 XCTest 或真机 UI 测试。检查脚本 `/tmp/jdt-delete-refresh.CAo1Qn/verify.swift`。
- 未启动模拟器、未运行 App。待真机验收：停留聊天页且不滑动，删除中间/首条/末条消息；收到对端删除同步；历史加载期间删除；处理提醒开启/关闭；接口失败时保持原消息和原失败提示。

单独回退：按标记移除 `chatMessageDeletionStateMatches` 及两处缓存复用条件中的调用，撤回对应测试与本记录。不要整文件覆盖，不回退此前的聊天键盘、排序、APP 合同等改动。

## 群成员角色标识样式（2026-10-21）

标记：`WDT_GROUP_ROLE_BADGE_20261021`。

- 对照 Git 原有样式，保留 `GroupRoleBadge` 的皇冠/角色图标、文字、颜色、字号、内边距及胶囊背景；只增加文字单行限制和标识整体的固有尺寸约束，避免长昵称挤压导致换行、块状显示。
- 生产改动仅在 `ContactsViews.swift` 的 `GroupRoleBadge`。该组件同时用于成员列表及成员操作弹层，角色判断、权限、点击动作、成员排序、人数开关和群详情头像矩阵均未修改。
- 新增 1 个源码布局约束回归测试；5 项宿主源码检查通过，确认组件以外的 `ContactsViews.swift` 与本轮修改前完全一致。
- 应用及测试目标 `build-for-testing` 编译通过；日志 `/tmp/jdt-owner-badge-build.log`。未启动模拟器、未运行完整 XCTest；长昵称、小屏幕与实际标识外观仍需真机验收。
- 单独回退：删除角色文字的 `.lineLimit(1)` 和标记处的 `.fixedSize(horizontal: true, vertical: true)`，同步回退对应测试与本记录；保留其他已有改动。

## 聊天已读后红点残留（2026-10-21）

标记：`WDT_CHAT_UNREAD_BADGE_20261021`。本轮生产改动限定为 `ChatViews.swift` 与 `ConversationStore.swift` 的已读链路。

- 截图中的绿色“已读”表示对方读了我发出的消息，列表红点表示本账号未读，二者不能直接互相清零。
- 定位到聊天页原先只测量最后一条对方消息；连续发送回复后，该行可能已经移出屏幕，导致即使实际停留底部也不触发已读。现在测量本次实际渲染的最后一条已确认消息行，包含自己的回复及按原规则展示的撤回/删除占位；不选发送中、失败、无服务端序号、系统消息或仅供置顶上下文的行。
- 保留原可见性函数不变：要求前台、当前账号会话与页面代次一致、实际消息行已布局且可见、内容底部确实进入视口；新消息已入 Store 但尚未显示时不能沿用旧布局确认。没有改为进入页面即无条件清零，也没有改变撤回/删除提示开关。
- `advanceRead` 对“确认位置等于已有已读位置，且覆盖整个已知末尾”的重复确认允许修正普通未读残留。已收敛时不再次发布；未覆盖末尾、存在消息缺口、旧确认或零覆盖仍保持原处理。若相同序号下还有表情回应未读，保守保留，不借此清除。
- 删除、撤回、发送、排序、权限、持久化、已读接口与重试流程未修改；原有未读计数汇总 UI 未修改。
- 新增 6 个回归用例。应用和测试目标 `build-for-testing` 编译通过，日志 `/tmp/jdt-unread-badge-build.log`。未启动模拟器，未运行完整 XCTest。
- 提取修改前后实际已读函数，配合最小模型执行 215 项宿主检查通过：包括旧版计数 4 无法收敛、新版同位置尾部确认可归零，以及其他会话、迟到 ACK、新消息、覆盖缺口、表情回应和可见性保护。临时检查脚本：`/tmp/jdt-unread-badge.9Nsw3u/verify.swift`。这些检查不能替代真机端到端验证。
- 待真机确认：连续回复后停留底部再返回列表；阅读历史时新消息到达；断网/重连；未读表情回应；确认只清理真正已读的当前会话，不误清其他会话。仅凭截图不能证明残留数字 4 全部来自上述代码路径，仍需实际验证。

单独回退：按标记回退聊天页已读目标选择及其 token/测量接线、`advanceRead` 的重复末尾确认分支与对应测试；保留之前的删除即时刷新、键盘、群主标识、会话排序等修改。不要整文件覆盖。

## 已读触发布局与离页时机补充（2026-10-21）

标记：`WDT_CHAT_READ_TRIGGER_20261021`。只修改 `jdt` 的 `ChatViews.swift`；安卓只读参考，生产状态存储、已读接口及未读计数规则不改。

- 用户反馈群聊未读 11、10 在点击“回到底部”后仍残留；不按群名、会话 ID 或具体数字特殊处理。
- 布局边界：原滚动目标在 `LazyVStack` 的外部底部内边距之前，目标底边对齐视口时，内容底边仍可能多出 12pt。滚动状态按宽松阈值认为已到底，但严格已读可见性要求内容底边不超过视口 1pt，因而可能一直拦住上报。把原 12pt 留白移到 `messageListBottomAnchor` 的 `.id(bottomAnchorID)` 之前，使滚动目标包含完整内容底部；总留白和内容高度不变，不放宽可见性判定。
- 离页时机：已读请求未完成即离页时，页面代次已递增，旧完成回调不能再清理 `isClearingUnreadReminder` / `lastVisibleReadAckToken`；同一页面实例再次出现可能被旧标记阻塞。离页时同步释放这两个页面标记，保留旧回调失效及重新测量保护。不在离页时发送已读、不清零未读，也不取消原持久化重试。
- 安卓参考 `MainActivity.kt` 的 `ChatViewportReadAckEffect` / `visibleIncomingReadAckTarget`：按实际可见消息和前台生命周期触发。未搬运安卓整套已读策略，未改安卓。
- 新增 1 个几何边界测试、2 个布局/生命周期接线测试。修改前宿主检查已复现：已显示末行但外部留白阻断确认；旧代次回调被丢弃后请求标记仍为占用。宿主几何输入是测试构造，不代表已在真机复现截图。
- 应用与测试目标 `build-for-testing` 编译通过，退出码 0，日志 `/tmp/jdt-unread-anchor-build.log`；存在既有弃用/并发警告。本轮没有启动模拟器或 App，也没有运行完整 iOS XCTest。
- 修改后执行 162 项宿主断言通过，包括从实际源码提取的可见性函数、离页重置语句，以及用轻量断言执行的 5 个测试方法体；脚本 `/tmp/jdt-unread-anchor.wSGwxY/verify.swift`。上一轮 215 项已读目标/Store 边界检查再次通过。上述检查不是 SwiftUI 实际布局或服务端端到端测试，不能据此断言截图中所有残留都已排除。
- 对比本轮备份，生产差异仅为底部内边距搬移和离页释放两个页面标记。已读接口、会话历史 ACK 编排、Store、远程会话映射及模型文件的校验值与本轮开始时一致。
- 真机待验收：有未读的任意群聊/单聊进入后到底、点击回到底部、键盘收起后到底；请求未完成时离开再回到同一页面；阅读历史时收到新消息应保留未读，其他会话不应被清零。

单独回退：按本标记把 `.padding(.bottom, 12)` 从底部锚点移回消息 `LazyVStack` 外层 `.padding(.top, 12)` 之后，移除本轮 `.onDisappear` 新增的两项标记释放及三个测试。不要撤回上一轮 `WDT_CHAT_UNREAD_BADGE_20261021` 或其他历史改动，不整文件覆盖。
