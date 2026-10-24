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

## 聊天计算与图片资源优化（2026-10-23）

标记：`WDT_CHAT_RESOURCE_PERF_20261023`。仅修改 `/Users/zen/Desktop/jdt`，生产改动限定为 `IMAPIClient.swift` 与 `ChatViews.swift`；不修改其他工程、安卓或 `codemagic`。

- 聊天历史、消息回执、消息扩展三个同步接口的响应解析移至后台任务。保留原 codec、三种响应信封的解析顺序和容错结果；请求参数、错误判断、重试、消息映射/合并及状态提交流程不变。其他接口继续使用原执行方式，不整体移除 `AppState` 的 `MainActor`。
- 修正缩略图限流器交接名额时的竞争窗口：直接把占用名额交给等待者，防止新到任务抢占造成超限。原并发上限仍为 2；本地索引缓存图片的解码也纳入同一限流器。保留远程加载去抖、缓存、签名 URL 恢复、失败重试及取消后的提交检查。
- 本地缩略图优先直接从文件使用 ImageIO 降采样，避免先读入整份源文件；保留原格式兼容回退。需要回传源数据的路径保留原始字节，改用安全内存映射读取，并在后台解码范围增加临时对象释放池。
- 引用贴纸和贴纸静态预览按既有显示尺寸、屏幕倍率解码。不改布局、样式、尺寸、文案、操作入口、原图查看和动画播放逻辑；不改发送、删除、撤回、未读、排序、同步游标或通话业务。
- 这不是全进程内存硬上限：原图、网络压缩数据、视图持有图片和格式回退仍可能占用额外内存。没有真机崩溃日志或性能采样，不能据此确认 iPhone X / iOS 16.7.12 的闪退根因或宣称已消除闪退。

验证：

- 新增 8 个聚焦 XCTest 用例，覆盖接口范围、后台解析和结果一致性、本地缩略图尺寸与源文件不变、无效图片、并发交接及取消释放；补充非聊天接口执行线程断言。
- 应用与测试目标 `build-for-testing` 编译通过，退出码 0，日志 `/tmp/jdt-chat-resource-perf-build.log`。未启动模拟器、未运行 App 或完整 iOS XCTest。
- 宿主检查从当前生产代码提取解析方法、DTO、codec 和限流器，与 Git 修改前的实际解析方法比较。12 项接口范围检查、81 组 JSON/字段映射/加密 codec 的新旧结果比较通过，确认后台解析不在 OS 主线程。20,480 次并发名额交接保持上限，100 次取消等待者检查通过。临时脚本 `/tmp/jdt-resource-perf-verify.rb`；这不代替 iOS 图像或 UI 真机测试。
- 真机待验收：iPhone X 冷启动登录并进入图片较多的聊天；连续翻历史、快速滑动、切换会话和返回；检查预览清晰度、原图、贴纸动画、图片失败重试及原业务行为；采集峰值内存/主线程耗时及对应 `.ips`，确认是否仍有闪退。

单独回退：按本标记恢复三个接口的原同步解析调用及 helper；恢复本地缩略图原加载顺序、限流器交接、文件解码 helper，移除两处预览像素上限；回退对应测试与本记录。保留既有 JHT 标记以及删除刷新、已读、键盘等历史改动，不整文件覆盖。

## 聊天六项修复（2026-10-23）

范围：仅 `/Users/zen/Desktop/jdt`。六项独立标记；保留已有未提交修改、`WDT_CHAT_RESOURCE_PERF_20261023` 及历史修复，不修改安卓、其他工程、`codemagic`。没有提交 Git。

### 1. 普通成员已读隐私

标记：`WDT_CHAT_FIX1_RECEIPT_PRIVACY_20261023`

- 定位：回执详情通过 `canViewDetails || hasReceiptDetails` 判断权限，且旧 `hasReceiptDetails` 包含表情回应，显式拒绝仍可能被绕过；回执同步中包含成员明细也会重新打开权限，接口的 `can_view_read_receipt_details` 未被消费。
- 修复：明确的服务端拒绝优先，表情回应不再推导已读明细权限；无权限时清除已读/未读成员和人数，保留已读状态、表情回应及会话未读数。兼容未提供权限字段但实际提供回执明细的旧接口。同步显式权限按当前会话更新，迟到的成员回执不能自行重新授权。
- 展示：群聊同时按精确群 ID 匹配现有群管理权限，避免普通成员看到缓存人数或同名群串用权限；普通成员弹窗的“已读”“未读”均无人数，只显示“未统计明细”，保留表情回应明细。单聊仍按服务端权限，已读能力关闭时保留原禁用提示。
- 文件：`RemoteAPIModels.swift`、`ConversationStore.swift`、`AppState+RemoteMessageStateMapping.swift`、`AppState+MessageActions.swift`、`ChatViews.swift`；测试 `DomainStoreTests.swift`。
- 回退：按标记一起恢复权限解码、Store 合并与同步接线、UI 权限判断/空态及对应测试，不回退未读徽标处理。

### 2. 删除后立即刷新聊天

标记：`WDT_CHAT_FIX2_DELETE_REFRESH_20261023`

- 定位：消息 Store 变更统一进入合并刷新队列，而界面仍持有消息行缓存；不能靠后续滚动或重新进入页面触发删除行更新。
- 修复：在现有 Store 发布回调中，用发布参数里的新快照识别删除标志变化、撤回或物理移除，立即重建消息行缓存。`@Published` 在存储赋值前发出新值，因此不从旧 Store 状态重新取消息。普通新增、历史加载、已读变化继续走原合并路径。
- 范围：仅 `ChatViews.swift` 和 `DomainStoreTests.swift`。不改删除请求、权限、失败处理、撤回/删除占位展示开关或滚动规则；没有提前假删服务端尚未确认的消息。
- 回退：移除该 helper 和发布回调内的即时刷新分支及对应测试，保留 `WDT_CHAT_DELETE_REFRESH_20261021` 等既有缓存修复。

### 3. 视频使用服务端封面

标记：`WDT_CHAT_FIX3_VIDEO_COVER_20261023`

- 定位：视频无封面时退回视频预览地址，封面失败恢复调用附件本地下载，可能把整段视频交给图片加载器。
- 修复：视频按已有 `thumbnail / cover / poster` 字段顺序优先使用服务端封面；本地只接受真实封面缓存，不以 MP4 预览/下载地址充当图片。封面恢复仅走既有文件元信息刷新，保留账号/企业作用域检查，不下载整段视频。聊天气泡与附件详情封面统一接线。
- 保留：图片原有回退、视频播放与显式下载流程、统一媒体缓存不变；服务端无封面且本地也无有效封面时仍显示原占位/重试状态。
- 文件：`AppState+FilesAttachments.swift`、`AppState+MessageSendingAttachments.swift`、`ChatViews.swift`；测试 `AttachmentDownloadTests.swift`。
- 回退：按标记恢复缩略图 URL 选择、失败恢复及详情接线、移除新 helper 和测试，保留图片资源性能优化。

### 4. 查找用户数字 ID 提示

标记：`WDT_CHAT_FIX4_USER_ID_HINT_20261023`

- 查找用户入口、输入框及空态改为“用户ID的纯数字部分”；根据当前账号真实 ID 展示“你ID是‘…’，对方只需输入‘…’即可找到你。”（界面使用中文双引号）。保留数字前导零，不把企业前缀中的数字混入示例；ID 尚不可用时不编造示例。
- 仅 `ConversationViews.swift` 文案与示例 helper、`DomainStoreTests.swift`；搜索参数、请求接口及好友申请流程不变。
- 回退：按标记移除示例 helper/文本并恢复查找用户文案及对应测试。

### 5. 回到底部入口

标记：`WDT_CHAT_FIX5_RETURN_BOTTOM_20261023`

- 将原顶部通栏入口移到消息区域右下角，改为紧凑胶囊样式，保留新消息数量/消息记录文案及至少 44pt 点击高度。
- 仅 `ChatViews.swift` 和 `DomainStoreTests.swift`；原显示条件、回到底部 action、滚动仲裁、已读触发条件与底部锚点不变。
- 回退：恢复该叠层的顶部对齐、顶部间距和原通栏样式及对应测试，不改滚动逻辑。

### 6. 单会话错误与连接错误分离

标记：`WDT_CHAT_FIX6_REALTIME_ERROR_SCOPE_20261023`

- 定位：通用 `forbidden` 和群成员数量限制均进入 `disconnectRealtime`，会把单次会话操作失败扩大为所有会话的实时连接中断。
- 修复：通用权限拒绝只有命中实际连接握手请求 ID，或明确声明 connection/session/global/account/tenant/workspace 范围时才按连接失败处理；会话/消息范围和无连接级证据的拒绝保留连接。群成员数量限制只保留原业务提示。诊断记录为 `OPERATION_REJECTED_CONNECTION_KEPT`，不再标成连接失败；判断不依赖诊断请求环形缓存。
- 保留：`unauthorized`、`connect_required`、`connect_failed`，以及既有工作区访问限制、其他连接级配额、安全封禁处理不变；不改心跳、重连调度或发送协议。
- 文件：`RealtimeClient.swift`、`AppState+Realtime.swift`；测试 `RealtimeTransportTests.swift`。
- 回退：按标记恢复错误分支和诊断分类，移除 scope policy/握手 ID 比较方法及对应测试，不回退原有连接诊断功能。

### 验证与待验收

- 新增 10 个 XCTest 用例；应用及测试目标 `build-for-testing` 编译通过（退出码 0），日志 `/tmp/jdt-chat-six-fixes-build.log`。有既有弃用/并发警告；未启动模拟器或 App，未执行 iOS XCTest。
- 本机从生产代码提取 DTO、权限更新、删除刷新判断、封面选择/恢复、ID 提示与错误范围策略，用最小依赖模型执行 142 项断言通过，另有 5 项回执空态/按钮接线源码检查通过。脚本 `/tmp/jdt-chat-six-fixes-verify.rb`；不等于 SwiftUI 渲染、真实 HTTP 或 WebSocket 端到端验收。
- 上一轮性能检查重跑通过：12 项接口范围检查、81 组新旧 codec/DTO 比较、20,480 次并发名额交接、100 次取消释放。脚本 `/tmp/jdt-resource-perf-verify.rb`。`git diff --check` 通过。
- 真机验收：普通成员与群管理员分别打开含回应的已读弹窗；删除首/中/末消息和多选删除；视频封面首次加载、过期恢复及播放；查找页核对自己 ID；窄屏/键盘展开时点击右下角入口；模拟单群权限拒绝后确认其他会话仍收消息，并确认登录失效仍走原处理。
- 六项分别回退时连同该项测试撤回；不要整文件覆盖，不要撤回其他标记。


## IOS1 闪退与性能整改（2026-10-23）

基线 `4d66bf345c47d0e542b989221c260f99a103c879`。完整方案见 `IOS1_CRASH_PERFORMANCE_PLAN.md`。本批由当前会话本人实施；不覆盖原 ZIP、不改最低系统版本、依赖版本、签名、数据库、服务端或 IOS2。真实事故根因尚未证实。

### WDT_IOS1_NAV_COMPAT_20261023 — 公开导航 API、单一返回手势生命周期

- `BlueStoneIM/BlueStoneIMApp.swift`：1359–1359（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIM/ChatViews.swift`：2557–2557（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIM/DesignSystem.swift`：658–2564（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIMTests/DesignSystemTests.swift`：104–1347（以各 BEGIN/END、单行标识与完整差分为准）。

### WDT_IOS1_CHAT_STATE_20261023 — 聊天消息弹层状态引用化、空会话挂载回归

- `BlueStoneIM/ChatViews.swift`：1000–2743（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIMTests/DesignSystemTests.swift`：201–212（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIMTests/DomainStoreTests.swift`：13–36（以各 BEGIN/END、单行标识与完整差分为准）。

### WDT_IOS1_SAFE_NUMERIC_20261023 — 数值越界与非法语音时长防 trap

- `BlueStoneIM/ChatViews.swift`：4089–9199（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIM/Core/AppSupport/AppState+FilesAttachments.swift`：953–953（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIM/Core/AppSupport/AppState+MessageActions.swift`：169–169（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIM/Core/AppSupport/AppStateLocalSupport.swift`：737–799（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+RemoteMessageStateMapping.swift`：2020–2020（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteRegistrationSnapshotSync.swift`：6087–6087（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIM/RemoteAPIModels.swift`：1534–1601（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIMTests/RemoteAPIModelsTests.swift`：5–57（以各 BEGIN/END、单行标识与完整差分为准）。

### WDT_IOS1_IMAGE_BUDGET_20261023 — 公共静态图片尺寸、缓存代次与加载并发边界

- `BlueStoneIM/ChatViews.swift`：13185–13260（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIM/DesignSystem.swift`：74–579（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIM/FilesRTCViews.swift`：1609–1609（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIMTests/DesignSystemTests.swift`：9–1362（以各 BEGIN/END、单行标识与完整差分为准）。

### WDT_IOS1_AVATAR_MEMORY_20261023 — 个人和群头像先降采样、共享固定像素裁剪

- `BlueStoneIM/ContactsViews.swift`：4281–4550（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIM/MeSettingsViews.swift`：1303–1632（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIMTests/DesignSystemTests.swift`：82–102（以各 BEGIN/END、单行标识与完整差分为准）。

### WDT_IOS1_RECEIPT_ROLE_20261023 — 修正 jdt4 独审 F1：企业角色与群角色分离

- `BlueStoneIM/Core/AppSupport/AppState+MessageActions.swift`：285–290（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIMTests/DomainStoreTests.swift`：100–111（以各 BEGIN/END、单行标识与完整差分为准）。

### WDT_IOS1_CHANGE_COMPAT_20261023 — iOS 15/16 onChange 真实旧值语义

- `BlueStoneIM/DesignSystem.swift`：2642–2659（以各 BEGIN/END、单行标识与完整差分为准）。
- `BlueStoneIMTests/DesignSystemTests.swift`：183–1327（以各 BEGIN/END、单行标识与完整差分为准）。

### WDT_IOS1_CALL_DURATION_20261023 — 独审 F2：通话历史输入、写入及旧缓存详情的安全时长

- `BlueStoneIM/RTCCallRecordMessage.swift`：345–369。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+VoiceCalls.swift`：7320–7592。
- `BlueStoneIM/FilesRTCViews.swift`：2932–3101。
- `BlueStoneIMTests/DomainStoreTests.swift`：14363–14389。
- `BlueStoneIMTests/FilePreviewTests.swift`：7–27。

整数时长须能精确转为 TimeInterval 并安全往返；历史推算、upsert/历史细化写入都校验非负、有限、可表示。详情共用安全格式化，直接从旧缓存解码的异常值显示“未记录”，不伪造 0 或上限。正常 0/61/3661、缺失与推算时长合同保留。F2 定向 30 项 XCTest 通过（FilePreview 25 + 实际历史消息处理链 5），未重跑原 382/878 或已归因 35 项。

依赖/合并：所有条目一并取完整候选；导航删除旧 GlobalBackSwipeInstaller / ChatBackSwipeInstaller，由 NavigationStackCompat 安装公开系统边缘返回，交互范围由原左半屏收窄为系统边缘。图片 gate 复用已有 AttachmentThumbnailLoadGate；直接远端预览先落临时文件，32 MiB 压缩预览上限，默认最长边 2048 像素，超限返回占位，原附件下载及原文件保留。聊天状态对象必须每个页面单独创建，不能单例。F1 保留服务端 false、作用域检查与既有迟到数据撤权逻辑。

验证：应用/测试目标完整编译已通过；新增图片/数值/状态/手势/旧 onChange 测试已通过；真实导航进退、会话替换与空单聊/群聊 30 次挂载回归已通过。扩展 878 项测试有 35 项失败，未改 jdt4 基线对同 35 项逐项复现；包括 RTC 测试数组越界，不能称整套测试通过。原独审结论 NEEDS_FIX 仅 F2；F2 完整链已修，定向 30 项通过，最终复审结果见交付报告。

回退：按本提交和完整标识块逆向恢复；不删除登录、消息、缓存数据，不对原包全树覆盖。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0。

## iOS17 原生导航增量核对（2026-10-23）

标识 `WDT_IOS1_NATIVE_NAV_REGRESSION_20261023`。新 `jdt 4 (2).zip` 相对原包的导航生产修复已由 `WDT_IOS1_NAV_COMPAT_20261023` 等价覆盖：iOS17 原生 item、iOS16 原生 isPresented、iOS15 旧链接。保留当前 retainedItem/id 隔离和前轮全部修复，不导入包内性能撤回或用户工程状态。

本次仅从新包补入 DesignSystemTests 的原生导航行为探针及用例，窗口绑定现有 UIWindowScene；覆盖空选择不挂载、携带搜索 messageID 进入A、dismiss 清空路由、进入B。测试直接调用实际 navigationDestinationCompat，不把 iOS26.5 结果称为 iOS17 实测。功能范围为测试，不改 AppID/签名/版本/业务代码。合并按标识完整取 helpers 与测试方法；验证结果见交付目录 IOS1-iOS17白屏增量-20261023。

## 点击已读误报群解散（2026-10-23）

标识：`WDT_RECEIPT_DETAIL_SCOPE_20261023`。
依据：`IOS点击已读误报群解散-定位与解决方案.md` 第 5 节 iOS 客户端方案。仅修改 `/Users/zen/Desktop/jdt`，不实施文档中的安卓或后端替代方案。

- 已读菜单和气泡入口统一打开状态/回应面板；私聊以及普通、未知企业角色不请求人员明细。企业管理员/内部角色的群聊也须由当前会话的回执同步明确返回 `can_view_read_receipt_details`，不依赖消息模型默认 true 或群主/群管理员身份。
- 明细能力仅存于当前账号/企业/登录代次/企业角色的运行态；实际 loader 再检查消息归属、功能开关与能力。撤权、换企业、换登录、离开会话后清掉人员/人数并拒绝迟到响应，不改原消息的二值已读状态、真实回应或未读红点。
- 表情回应独立使用既有 extras 同步。明细返回不覆盖已经同步的回应；私聊状态未知时显示“状态待同步”，无明细权限的已读/未读区域保持“未统计明细”、不显示人数。
- 明细接口的预期权限拒绝静默收敛为无明细；功能关闭、404/消息不可见、登录失效、网络故障分别处理。受限 200 响应也不用于推断未知消息为已读或未读。
- 通用 `permission_denied` 改为“无权限执行该操作”；删除全局包含匹配的解散映射。实际解散/解散预览保留原权限提示；真实解散请求、群主判断、确认、成功处理均未改。

涉及文件：`AppState.swift`、`ChatViews.swift`、`ConversationStore.swift`、`AppState+MessageActions.swift`、`AppState+ConversationsHistory.swift`、`AppState+GroupAdministration.swift`、`AppState+RemoteMessageStateMapping.swift`、`AppState+RemoteRegistrationSnapshotSync.swift`，以及 `DomainStoreTests.swift`、`RemoteAPIModelsTests.swift`。

验证：新增 8 项 XCTest，更新已有角色矩阵/错误映射预期；应用与测试目标 `build-for-testing` 编译通过（退出码 0，有既有警告），未启动模拟器或 App，未执行 iOS XCTest。构建日志 `/tmp/jdt-receipt-detail-scope-build.log`。本机提取实际权限/错误分类函数执行 161 项 Swift 断言和 4 项请求接线检查通过，脚本 `/tmp/jdt-receipt-detail-scope-verify.rb`；使用最小依赖模型，不代表线上请求或真机 UI 验收。`git diff --check` 通过。

待真机验收：私聊（普通/内部/管理员）点击已读与表情不发人员明细请求；普通企业账号即使为群主也无人数/名单；授权群可展示真实明细且遵守人数显示配置；撤权、换会话/企业后的迟到响应不恢复旧明细；实际解散群权限和确认仍正常。

回退：以本组完整差分和标识为单位恢复入口、权限运行态、清理钩子、请求/响应检查、错误映射、Store 新增可选参数及测试；不要整文件覆盖，不撤回已有其他标识。保留 `WDT_IOS1_RECEIPT_ROLE_20261023` 的企业角色与群身份分离原则，本组是在该原则上补齐服务端会话能力检查。不修改发送、删除、排序、阅读 ACK、通话、数据库结构、`codemagic.yaml`；未提交或推送 Git。
