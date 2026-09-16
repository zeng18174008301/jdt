# BlueStoneIM iOS 启动性能优化 — 实现规格 & 验收标准

> 角色分工:本文档由方案方产出,**执行方 AI 据此改代码**,方案方负责验收。
> 工程路径:`apps/ios-chat/BlueStoneIM/`,SwiftUI / iOS 17 / 应用名 BlueStoneIM(X01)。
> 约束:不引入新依赖、不改 UI 外观、不改功能语义(消息不丢、顺序正确、未读数正确);纯 iOS 改动可不跑 `codegraph sync`。
> 行号基于当前版本,执行方改前请以**函数名/符号**为准定位(行号会随改动漂移)。

---

## 0. 背景与已确诊根因

启动后首页要卡 5–6 秒才能操作。根因是 **session 恢复时,首页 ready 被一条串行 await 链 gate 住**:

```
AppState.swift:252  恢复 Task
  → refreshRemoteSnapshot(silent:false, force:true)        :3817
    → syncPrimaryConversationData(...)                      :3847
      → await api.syncConversations(...)                    :3850   (1 次往返,会话列表)
      → applyRemoteConversations(...)                       :3854   ← 列表此刻已就绪
      → await refreshConversationHistories(conversations)   :3856   ← 瓶颈
        → for remote in candidates.prefix(12) { ... }       :6013   串行
            await api.syncMessages(...)                      :6016   每会话 1 次往返
            await syncReadReceiptsForConversation(...)       :6025   命中再 1 次往返
```

**量级**:最坏 `1 + 12×2 ≈ 25` 次串行往返 × ~200ms ≈ 5s,与现象吻合。

**放行标志**(两者都被 gate):
- `isInitialDataLoading` 在 `refreshRemoteSnapshot` 的 `defer` 清除(`:3827`)——等 primary(含 histories)全部完成;
- `isRestoringSession` 在恢复 Task `:260` 清除——等 `refreshRemoteSnapshot` 返回;
- UI 据 `BlueStoneIMApp.swift:22` `isShowingLaunchSplash || (isAuthenticated && isRestoringSession)` 决定是否还盖 `SessionRestoreView`。

**关键前提(降低改动风险)**:打开会话时已有按需拉取历史的现成路径——`ChatViews.swift:579` `state.syncConversationMessagesIfNeeded(conversationID, force: conversation.messages.isEmpty)`,且有现成 loading 态 `conversationHistoryLoadingIDs`(`AppState.swift:121`)。因此把首屏历史预取挪到后台,点进任何会话都会自补,不会出现永久空白。

**二级数据已后台化**(无需改):`refreshSecondarySnapshotInBackground`(`:3843/:3878`)已并行拉取群/联系人/文件/租户资料。本次只处理 histories + 已读回执这一段。

**主线程阻塞排查结论**:无 `DispatchSemaphore` / `.sync` / `Thread.sleep`;`IMAPIClient` 为非 `@MainActor` 普通 class(`:6993`),网络与 JSON 解码在协作线程池、不在主线程。主线程开销只在 `@MainActor` 的模型组装与列表重算(见 Batch 2)。

---

## 1. 已确认决策基线

| 决策点 | 结论 |
|---|---|
| 首页放行策略 | **会话列表(syncConversations)到达即放行**;单会话历史后台补;补齐前消息区用现有「加载中」骨架 |
| 历史预取并发上限 | **6** |
| 历史预取范围 | 保持**最近 12 个会话**(`prefix(12)`) |
| 机型基线 | **iPhone 12 / iOS 17**;登录页动效无需额外降级,本次不动动效 |
| 本地缓存 | **允许加轻量缓存**,实现冷启动「秒开」(Batch 3) |

---

## 2. Batch 1 — 启动 gate:列表到达即放行 + 历史预取并行化(最高优先级,最低风险)

### 2.1 改动 A:`syncPrimaryConversationData` 不再 await 历史

文件 `AppState.swift`,函数 `syncPrimaryConversationData(context:scope:refreshID:generation:silent:)`(当前 `:3847`)。

**当前**(节选):
```swift
applyRemoteConversations(data.conversations, replacing: requestedVersion == 0)
hasLoadedRemoteSnapshot = true
let historiesSynced = await refreshConversationHistories(data.conversations)   // ← gate
guard isCurrentRemoteRefresh(refreshID, generation: generation),
      isCurrentRemoteScope(scope) else { return false }
if historiesSynced { syncFailureMessage = nil }
return true
```

**目标**:`applyRemoteConversations` + `hasLoadedRemoteSnapshot = true` 后**立即返回 true**(列表就绪即放行);历史预取改为后台 `Task` 触发,不参与本函数的返回时序。

**要点**:
- 历史预取后台 Task 必须**保留 generation / scope 守卫**(`isCurrentRemoteRefresh(refreshID, generation:)` 与 `isCurrentRemoteScope(scope)`),在每次 `await` 之后再次校验,避免切租户/重登后把过期历史写入当前数据。
- `syncFailureMessage` 的清除逻辑:**会话列表同步成功**即视为首屏成功(清除/不报错);历史预取失败保持**静默**(沿用现有 `logSyncEndpointFailure` + `silent` 路径),不得因历史失败把首页打回失败态。
- 返回后,`refreshRemoteSnapshot` 的 `defer` 立即清 `isInitialDataLoading`、`refreshSecondarySnapshotInBackground` 照常触发;恢复 Task `:260` 立即清 `isRestoringSession` → 首页放行。

参考形态(示意,执行方按现有命名/守卫风格落地):
```swift
applyRemoteConversations(data.conversations, replacing: requestedVersion == 0)
hasLoadedRemoteSnapshot = true
syncFailureMessage = nil
// 历史预取移后台,不 gate 首屏
Task { [weak self] in
    guard let self else { return }
    await self.prefetchConversationHistories(
        data.conversations, scope: scope, refreshID: refreshID, generation: generation
    )
}
return true
```

### 2.2 改动 B:`refreshConversationHistories` 串行 → 并发(上限 6)

文件 `AppState.swift`,函数 `refreshConversationHistories(_:)`(当前 `:5997`)。

**当前**:`for remote in candidates.prefix(12)` 串行,每个会话内 `await api.syncMessages` 后再 `await syncReadReceiptsForConversation`。

**目标**:
- 候选筛选逻辑(`:6000–6010`,按 `lastMessageID` 是否已在本地判断是否需要拉)**保持不变**。
- 改为 `withTaskGroup` 拉取,**in-flight 并发上限 6**;`prefix(12)` 范围不变。
- **网络拉取并行,模型写入串行回主线程**:`api.syncMessages` 在 group 内并发执行;拿到结果后,`applyRemoteMessages(...)` 必须回到 `@MainActor` 串行执行(`AppState` 已是 `@MainActor`,从子任务回写需 `await MainActor.run { ... }` 或经一个 `@MainActor` 收口方法),以保证写入顺序、去重与未读数正确。
- 每个子任务 `await` 后校验 generation/scope,过期则丢弃结果不写入。
- 失败计数/日志(`:6037–6038`)保留;整体仍为静默。

并发上限实现方式(示意,不用信号量也可,用"先填满 6 个再每完成一个补一个"的窗口式 task group):
```swift
let targets = Array(candidates.prefix(12))
let maxConcurrent = 6
var index = 0
await withTaskGroup(of: PrefetchResult?.self) { group in
    func addNext() {
        guard index < targets.count else { return }
        let remote = targets[index]; index += 1
        group.addTask { [weak self] in
            guard let self else { return nil }
            // 仅网络:syncMessages(+可选 receipts 数据),不在此写入 @MainActor 状态
            return await self.fetchHistoryPayload(for: remote, scope: scope, generation: generation)
        }
    }
    for _ in 0..<min(maxConcurrent, targets.count) { addNext() }
    for await result in group {
        if let result { await applyPrefetched(result, scope: scope, generation: generation) } // @MainActor 串行写
        addNext()
    }
}
```

### 2.3 改动 C:已读回执移出首屏

- 预取循环内的 `syncReadReceiptsForConversation`(`:6024–6026`)**不在首屏预取路径里 await**。
- 移到 Batch 1 的后台历史 Task 之后、或更低优先级的独立后台批处理中执行(可用 `Task(priority: .utility)`)。
- `shouldSyncReadReceipts` 判定逻辑不变;回执写入仍走现有 `applyRemoteReadReceipts`。

### 2.4 Batch 1 边界与不变量(执行方必须保证)

1. 消息写入仍走 `applyRemoteMessages`(按 seq 合并去重),**不得**新增并发写主线程状态的路径。
2. 切租户 / 重登(generation 或 scope 变化)后,在途的历史/回执结果一律丢弃。
3. 会话列表同步失败时,首页失败态/重试入口(`ConversationViews.swift:125` 的 `syncFailureMessage` 分支、`retryRemoteSync`)行为不变。
4. 不改 `ChatViews.swift:579` 的按需拉取路径。

### 2.5 Batch 1 验收标准

- **功能**:冷启动恢复登录后,(a) 首页会话列表正常显示且可交互;(b) 点进任一会话历史正常加载(空历史显示加载骨架后补齐);(c) 未读数、消息顺序、最后一条消息与改前一致;(d) 弱网/历史接口故障时首页仍可用,不被打回失败态。
- **性能**:**首页可交互时间从 5–6s 降到 ≤1.5s**(理想 ≤1s,取决于 syncConversations 单次往返)。
- **回归**:切企业/重登后无串数据;实时消息到达后列表/未读更新正常。

### 2.6 Batch 1 验证方法(Instruments / 打点)

- 在三处加 `os_signpost`(或临时 `CFAbsoluteTimeGetCurrent()` 打点 + `print`):①恢复 Task 起点 `:253` 前;②`applyRemoteConversations` 后(= 列表就绪);③后台历史预取全部完成。用 **Instruments → Points of Interest / Time Profiler** 读 ①→② 间隔即"首页可交互时延"。
- **Time Profiler**:确认 main thread 在恢复期间无长时间占用;**Hangs** 应无 >250ms 卡顿。
- 对比测量需在同机型、同网络下取改前基线一次、改后一次。

---

## 3. Batch 2 — 会话列表渲染(高收益,中低风险)

### 3.1 问题

文件 `ConversationViews.swift`,`ConversationListView.body`(当前 `:87` 起)。
- `:96` 外层 `ScrollView` + `:97` `LazyVStack`,但实际行被包进 `:144` 普通 `VStack(spacing:12){ ForEach(...) }` —— **懒加载被破坏**,所有行一次性构建。
- `body` 每次重算 `matchingConversations`(filter)并两次 `sortedConversationSection`(sort,`:91–92`);实时消息每到一条触发整列表重过滤+重排+重建。

### 3.2 目标

- 让会话行真正懒加载:行直接置于 `LazyVStack`(分 pinned / regular 两段,或两个 section),**去掉包裹行的中间 `VStack`**;顶部卡片/横幅可单独成段。
- filter / sort 结果**缓存**(例如在 `AppState` 侧维护派生的已排序数组,或用 `onChange(of: conversations)` 重算并存 `@State`),不在 `body` 每帧重算。
- 行内不做重复格式化(日期/头像/initials):预计算或缓存。

### 3.3 约束
- 不改外观与交互(置顶、长按菜单、@我 筛选、未读角标)。
- 排序规则(`sortedConversationSection`)结果必须与现状一致。

### 3.4 验收标准 & 验证
- **功能**:列表内容/顺序/置顶/筛选/角标与改前一致。
- **性能**:大量会话(≥50)滚动 **Animation Hitches** 显著下降;`body` 重算次数明显减少(可在 `body` 内打点计数)。
- 验证:**Instruments → Animation Hitches** 滚动录制;body 打点对比改前后调用次数。

---

## 4. Batch 3 — 轻量本地缓存:冷启动「秒开」(中风险,独立验证)

### 4.1 目标

冷启动(含杀进程后)**先用磁盘缓存即时渲染会话列表 + 各会话最近若干条消息(可交互)**,再后台 `refreshRemoteSnapshot` 合并刷新。把"等首个网络往返"也省掉。

### 4.2 存储设计(执行方注意)

- **域模型未实现 `Codable`**:`Conversation` / `ChatMessage` / `IMUser` / `ConversationKind` / `MessageStatus` 等均仅 `Identifiable, Hashable`(`Models.swift:513 / 355 / 200 / 42 ...`)。
- **不要**直接给域模型加 `Codable`(易引入解码歧义、污染领域层)。改用**独立的轻量缓存 DTO**:定义 `CachedSnapshot`(会话列表元信息 + 每会话最近 N 条消息的精简字段),与域模型显式互转。
- 存储介质:**文件**(JSON,写入 app 的 Caches/Application Support 目录),**按 scope 分文件**;不要用 UserDefaults(消息体量偏大)。
- `N` 建议 = 单会话最近 **30–50** 条(够首屏渲染即可,其余仍走打开会话按需拉)。

### 4.3 一致性约束(必须满足)

1. **scope 隔离**:缓存 key = `remoteDataScopeKey`(租户|用户)。读写只认当前 scope;切租户/换账号读不到他人缓存。
2. **服务端为准**:`refreshRemoteSnapshot` 返回后,以服务端数据覆盖缓存渲染结果——**未读数、最后消息、置顶状态**一律以服务端为准,缓存仅用于"首帧占位"。
3. **失效清理**:退出登录、切租户、清除 session(`apiContext.clearSession`)时**删除对应 scope 缓存**。
4. **写入时机**:在 `applyRemoteConversations` / 历史预取写入成功后异步持久化(`Task(priority:.background)`),不得阻塞主线程或首屏。
5. **版本/损坏兜底**:缓存带 schema version,解析失败或版本不符时静默忽略、走正常网络流程(绝不因坏缓存崩溃或卡死)。

### 4.4 启动流程改动(与 Batch 1 协同)

- 恢复 session 时(`AppState.swift:230` 分支):在 `isRestoringSession = true` 之后、网络返回之前,**若当前 scope 有有效缓存则先 `applyCachedSnapshot` 并提前放行首页**(可交互),网络数据到达后再合并。
- 若无缓存,退回 Batch 1 行为(列表到达即放行)。

### 4.5 验收标准 & 验证

- **功能**:杀进程冷启动→秒见会话列表(可交互);网络到达后未读数/最后消息无跳变错误;切账号/切租户**绝不串数据**;清除缓存或坏缓存时走正常流程无异常。
- **性能**:有缓存时**首页可交互 ≤ 300ms**(本地读取+渲染);无缓存时退化为 Batch 1 表现。
- 验证:杀进程多次冷启动测时延;切账号回归;手动写坏缓存文件验证兜底。

---

## 5. Batch 4 —(可选)收尾项

- **WS 重连去重/节流**:`scheduleRealtimeReconnect` 重连成功后 `:1481` 又 `refreshRemoteSnapshot(force:true)` 触发整轮 primary;建议重连后只增量补当前会话 + 整轮 refresh 加节流,避免与轮询/WS 重复拉取。验证:Network instrument 看重连后请求数下降。
- **头像预解码**:列表/聊天头像 `AsyncImage`(`DesignSystem.swift:220/659`)解码到位图默认主线程绘制时发生;快速滚动可能掉帧。建议解码后 `byPreparingForDisplay` 预解码再上屏。验证:滚动 Hitches。

---


---

## 5c. Batch 6 — 会话名显示成 ID(十几秒后才变名称)

### 5c.1 现状(Batch 1/3 已落地后的实测链路)

执行方已实现提前放行 + 本地缓存 + 后台并发预取。会话名显示成 ID 是独立问题,根因三层叠加:

1. **服务端 `conversations/sync` 不返回名字。** `server/internal/im/model.go` 的 `Conversation`(:145)只有 `PeerIMUID`/`PeerUserID`/`TargetID`,无对端昵称/群名;客户端 `RemoteConversation`(`AppState.swift:17973`)也未解析名字。标题只能靠本地数据现查:`titleForRemoteConversation`(`:11608`)——单聊 `user(for: peerID)?.name ?? peerID`,群聊 `groups.first…?.name ?? channelID`,查不到回退成 ID。
2. **联系人/群被延迟 2.2s 才加载。** `refreshSecondarySnapshotInBackground`(`:6597`)里 `Task.sleep(mainShellSecondarySnapshotDelayNs)`,`mainShellSecondarySnapshotDelayNs = 2_200_000_000`(`:554`)。列表先画(contacts/groups 为空)→ 2.2s 后才拉群+好友关系 → 各自 1–2 次往返。名单大/网络慢累积到十几秒,期间全是 ID。
3. **缓存把 ID 固化。** `scheduleRemoteSnapshotCacheWrite`(`:7028`)在 `applyRemoteConversations` 后立即写(`:6580`),此刻 title 还是 ID;`CachedConversation.title`(`:18669`)存的就是 ID,下次冷启动读出来仍是 ID。

### 5c.2 排查前提(执行方先确认,可能是"卡半天"的主因之一)

`AppState.init()`(`:616–633`):**DEBUG 构建下** `shouldResetAuthOnLaunch = !launchArguments.contains("--preserve-auth")`,即每次启动清 session+清缓存、强制重登。若用 Xcode 直接 Run(未传 `--preserve-auth`),每次都是无缓存最冷冷启动且全程 ID。**先在 Scheme → Run → Arguments 加 `--preserve-auth` 复测**;若卡顿/ID 明显缓解,则部分问题仅存在于开发态,Release 包不受影响。此项不需改代码,仅需确认。

### 5c.3 已确认决策:服务端 + 客户端两者都做

### 5c.4 服务端改动(根治)

目标:`/api/im/conversations/sync` 每个会话直接带上可显示名字。

- `server/internal/im/model.go` `Conversation` 增加字段:
  - `PeerName string `json:"peer_name,omitempty"`(单聊对端昵称/备注名)
  - `GroupName string `json:"group_name,omitempty"`(群聊群名)
  - (可选)`PeerAvatar` / `GroupAvatar`,便于头像也即时显示。
- 填充位置:构建会话列表的 store/handler(`server/internal/im/store.go` / `postgres.go` 中组装 `Conversation` 的查询)。单聊按 `PeerIMUID` join 租户用户表取昵称;群聊按 `TargetID`(群 channelID)join 群表取群名。优先返回租户内显示名/备注名,保证与通讯录一致。
- 不改变现有字段与语义,纯新增可选字段(老客户端忽略,向后兼容)。
- 改完在项目根跑 `codegraph sync .`;服务端需重新部署。

### 5c.5 客户端改动

1. **解析新字段并优先用作 title。** `RemoteConversation`(`AppState.swift:17973`)增加 `peer_name`/`group_name` 解析;`titleForRemoteConversation` / `conversationTitle`(`:11608`/`:11620`)改为:**服务端名字非空 → 直接用**;否则回退到现有本地解析。这样首次/首装即正确,不依赖 contacts/groups。
2. **不再延迟 contacts/groups(兜底,也利于无服务端名字的旧数据)。** 把 `refreshGroupsInBackground` 与好友关系/contacts 加载从 2.2s 延迟的二级包中提出,与会话同步**并行或紧随**触发;`mainShellSecondarySnapshotDelayNs` 仅保留给真正非关键的二级数据(文件、租户资料等)。
3. **缓存不写 ID、不被 ID 覆盖。**
   - `conversationTitle`(`:11620`)在 `replacing` 且 `resolvedTitle` 为 identifier-like 时,优先沿用缓存/previous 的真实名字(已有 `isIdentifierLikeDisplayName` 判定,扩展覆盖 replacing 分支)。
   - `scheduleRemoteSnapshotCacheWrite`:仅在 title 已解析(非 identifier-like)时写入对应会话的 title,或在 contacts/groups 到达、标题重解析后再补写缓存,避免把 ID 固化。

### 5c.6 约束与不变量
- 不改未读数、排序、消息语义;只改"名字来源与时序"。
- 服务端新增字段为可选,保持向后兼容。
- 切租户/重登仍按 scope 隔离;缓存失效规则不变。

### 5c.7 验收标准 & 验证
- **功能**:(a) 冷启动(含首装、无缓存)会话列表**首帧即显示正确名称**,不出现 ID 占位;(b) 单聊显示对端昵称/备注名、群聊显示群名,与通讯录/群资料一致;(c) 切租户/换账号名称正确、无串数据;(d) 服务端未返回名字的兜底路径下,contacts/groups 到达后名称在 ~1–2s 内补正,而非十几秒。
- **性能**:名称解析不再 gate 在 2.2s 延迟之后;开发态加 `--preserve-auth` 后冷启动明显变快。
- **验证**:抓一次 `/api/im/conversations/sync` 响应确认含 `peer_name`/`group_name`;杀进程冷启动观察首帧名称;断网仅用缓存时名称仍正确;DEBUG 加/不加 `--preserve-auth` 对比启动时延与是否显示 ID。

---

## 5d. Batch 7 — 恢复登录时整屏卡死不能操作

### 5d.1 根因
恢复登录时全屏显示 `SessionRestoreView`(`BlueStoneIMApp.swift:22`、:87),其**无任何可交互控件**。由 `isRestoringSession` 控制放行:
- 缓存命中 → 立即 false,秒进首页(`AppState.swift:656`);
- **缓存未命中 → 等 `refreshRemoteSnapshot` 内 `syncConversations` 网络往返返回才放行(`:669`)**,最长卡到 **8s 超时**(`request.timeoutInterval = 8`,`:13642`)。

因此首装/缓存过期/后端慢或不可达时,封面盖死整屏数秒~8s,完全不能操作。

次要:
- `applyCachedRemoteSnapshotIfAvailable` 在 `init` 内**同步**读盘+JSON 解码(`:7012-7013`,@MainActor),缓存大时卡首帧。
- API base 默认 `localhost:8081-8083`(`:7002`);测试设备不可达时每次同步卡满 8s。

### 5d.2 改动
1. **恢复期进可交互骨架,不盖全屏封面。** `BlueStoneIMApp.swift:22` 的条件去掉 `(isAuthenticated && isRestoringSession)`,改为:已认证即进 `MainShellView`;`isRestoringSession` 仅驱动一个顶部轻量加载指示/会话区骨架(沿用 `isInitialDataLoading` 既有占位)。`isShowingLaunchSplash` 仍可保留作首帧封面(已 950ms 自动收起,`:702`)。
2. **缓存解码移出主线程。** `applyCachedRemoteSnapshotIfAvailable` 的 `Data(contentsOf:)`+`decode` 放到后台,解析完回 `@MainActor` 赋值 `conversations`;init 内不做同步 IO。
3. **首屏超时兜底。** 恢复用更短的首屏超时(如 5s);失败进入可操作空列表+重试入口,不停在封面。可单独给会话同步设较短超时,与其他请求区分。
4. **核对后端 base URL。** 确认测试设备上 `im2.api.*Base`(UserDefaults,`:7002-7004`)指向可达服务;不可达会让每次同步卡满超时。此项为配置核对,非代码改动。

### 5d.3 约束与验收
- 不改认证/同步语义;仅改"恢复期 UI 是否可交互"与解码线程。
- **验收**:恢复登录(含缓存未命中、后端慢)时,首页 tabs **立即可点**、可切换,不再出现整屏不可操作;弱网/后端不可达时不卡满 8s 封面而是进可操作占位+重试;Time Profiler/Hangs 下 init 无主线程同步 IO 长卡顿。

---

## 6. 执行顺序与回归清单

**顺序**:Batch 1 → Batch 2 → Batch 3 →(可选)Batch 4;**Batch 5 独立**(只动 auth 文件);**Batch 6 独立但建议优先**(直接影响"打开就显示 ID"的核心体验,服务端+客户端各自可单独发布)。每批独立提交、独立验收、可单独回退。

**每批通用回归清单**:
- 冷启动恢复登录:首页可用、会话列表正确、点进会话历史正确。
- 实时消息到达:列表、未读、最后一条消息更新正确。
- 切企业 / 退出再登录:无串数据、无残留 loading。
- 弱网 / 后端 5xx:首页不被历史失败打回失败态,失败有静默日志。

---

### 2026-06-21 / iOS 性能优化专项 Batch 1-3 首批落地

本轮按产品任务聚焦消息列表/会话滚动、头像/图片缓存、会话详情历史分页,未改登录/注册界面。

**Batch 1:消息列表/会话滚动卡顿根因与首批优化**
- `ConversationListView` 去掉会话行外层普通 `VStack`,让会话行成为 `LazyVStack` 的直接子节点,避免中间容器破坏懒加载。
- 会话列表筛选/置顶/普通分段收口为 `ConversationRenderSections`,同一次 body 计算只生成一份 matching/pinned/regular 结果,降低重复 filter/sort。
- `ChatView` 为消息行建立一次性 `MessageSenderResolver`,把发送人昵称/头像用户解析提前到 `ChatMessageRenderRow`,避免每个 `MessageBubble` 滚动渲染时重复扫描 participants、contacts、groups.members。

**Batch 2:头像/附件/图片加载缓存与占位**
- `AvatarImageCache` 增加同 URL in-flight 合并、后台下载、`UIImage.byPreparingForDisplay()` 预解码和 UIImage 直接存储。
- `AvatarView`、`EnterpriseLogoView` 从 `AsyncImage` 切换为项目内 `CachedRemoteImage`,保留原有 fallback 占位和后端返回 URL 逻辑。
- 自定义头像上传后的 `AvatarImageCache.store(data, for:)` 继续有效,不改变个人/群头像本地闭环和 OSS/CDN URL 消费方式。

**Batch 3:会话详情进入/历史分页性能**
- `loadOlderMessagesIfAvailable` 增加按会话历史 scope 的短窗口节流,避免顶部锚点/快速滚动期间重复发起旧记录分页。
- `ChatView` 旧记录加载触发从顶部第 1 条提前到顶部 3 条内预取,并在当前会话已处于 history loading 时直接返回,减少进入旧记录区域后的等待和滚动锚点抖动。

---

## 9. 专题:进入后卡一阵 + 名称即显(最终措施汇总)

> 针对"登录→选企业→进入后列表空转一阵 + 名字先显示成 ID"两个体验问题的收口清单。
> 关键发现:**登录后选企业进入的路径(`selectEnterprise` Task,`AppState.swift:967`)与会话恢复路径不同,旧版本曾主动清缓存且串行等两次网络**,所以无法秒显。2026-06-23 最终缓存策略已改为:退出登录、切账号、切企业、token 失效、安全封禁、企业访问阻断和启动恢复都不物理删除长期内容缓存,只清凭证/session、连接和当前活跃内存视图,再用 scope gate 防串号。

### 9.1 进入路径现状(实测链路)
`selectEnterprise` 的进入 Task:
1. 旧版本曾在进入前清远端快照缓存——**进入即清本地缓存**(故无缓存可秒显)。当前代码已移除该物理删除路径。
2. `resetAuthenticatedRemoteData(showLoading: true)`(`:973`)——清空会话列表、进 loading 态。
3. `await switchPlatformTenant(tenantID:)`(`:974`)——**第 1 次网络往返**(8s 超时)。
4. `enterIM(showToast:false)`(`:984`)——进主界面(列表此刻空、转圈)。
5. `await refreshRemoteSnapshot(force:true)`(`:985`)——**第 2 次网络往返**,`syncConversations` 回来才填列表。
→ 进入后要等 **两次串行网络** 列表才出现 = "卡一阵";出现后名字是 ID(contacts/groups 延迟 2.2s 加载,`:6597`/`:554`)。

### 9.2 目标 A:降低"进入后卡一阵"

| # | 措施 | 位置 | 收益 / 风险 |
|---|---|---|---|
| A1 | **进入路径也接缓存秒显**:不在进入时物理删除远端快照缓存;`switchPlatformTenant` 成功后,先按**目标租户 scope** `applyCachedRemoteSnapshotIfAvailable` 即时渲染列表,再后台 `refreshRemoteSnapshot` 合并。重进同企业即秒显。 | `selectEnterprise`、`applyCachedRemoteSnapshotIfAvailable` | 高 / 中(需按目标 scope 读缓存,注意切租户隔离) |
| A2 | **两次网络解耦**:`switchPlatformTenant` 与首屏渲染解耦——能用缓存先渲染;无缓存时也让 `enterIM` + 骨架尽早出现,`syncConversations` 在后台填充。 | `:974`–`:985` | 中 / 低 |
| A3 | **首屏更短超时 + 兜底**:`syncConversations` 用较短超时(如 5s);失败给可操作空列表 + 重试,不停在转圈/不卡满 8s。 | `request.timeoutInterval`(`:13699`) | 中 / 低 |
| A4 | **长期内容缓存不被产品路径物理删除**:退出登录、切账号、切企业、安全封禁、token 失效只清凭证/session、连接和当前活跃内存视图;会话快照/媒体/缩略图/下载缓存靠 scope gate 防串号,切回原 scope 可复用。 | `resetAuthenticatedRemoteData`、`applyCachedRemoteSnapshotIfAvailable`、内容缓存 scope key | 高 / 中 |

### 9.3 目标 B:进入后"立马看到名称"

| # | 措施 | 位置 | 收益 / 风险 |
|---|---|---|---|
| B1 | **服务端在 `conversations/sync` 返回名字(根治)**:`Conversation` 增 `peer_name`/`group_name`(按 `PeerIMUID`/`TargetID` join 用户/群表)。一次 `syncConversations` 即带名字,首装/首次进入都立刻正确。 | `server/internal/im/model.go:145`、组装查询(im/store.go/postgres.go) | 最高 / 中(改 Go + `codegraph sync .` + 部署) |
| B2 | **客户端解析并优先用服务端名字**,无则回退本地解析。 | `RemoteConversation:17973`、`titleForRemoteConversation:11608`、`conversationTitle:11620` | 高 / 低 |
| B3 | **contacts + groups 不再延迟 2.2s**,与 `conversations` 并行加载(无服务端名字时的兜底),名字 ~1s 内补正而非十几秒。 | `refreshSecondarySnapshotInBackground:6597`、`mainShellSecondarySnapshotDelayNs:554` | 高 / 低 |
| B4 | **缓存写入含已解析真名、且 title 像 ID 时不覆盖真名**:进入路径接缓存(A1)后即显真名;`scheduleRemoteSnapshotCacheWrite` 在名字解析后再写或补写。 | `conversationTitle:11620`、`scheduleRemoteSnapshotCacheWrite:7028` | 中 / 低 |

### 9.4 推荐落地顺序(收益优先)
1. **B1 + B2**(服务端补名字 + 客户端解析)→ 首次进入即正确名称,根治。
2. **B3**(contacts/groups 去 2.2s 延迟)→ 兜底,且让旧数据也快速正确。
3. **A1 + A4**(进入路径接缓存、产品路径不物理删长期内容缓存)→ 重进同企业秒显列表 + 真名。
4. **A2 + A3**(解耦两次网络 + 短超时兜底)→ 首次进入也尽快可用。

> 仅做客户端(B2+B3+A1+A2+A3)即可大幅改善;B1 是"首装/首次进入也立刻有名字"的根治项,建议纳入。

### 9.5 验收
- 进入(选企业后)→ **列表在 ≤1.5s 内出现**(有缓存时 ≤300ms),不长时间空转。
- 进入后会话名**首帧即为真实姓名/群名**(B1 上线后含首次进入);未上线 B1 时,名字 ≤1–2s 内补正,不再十几秒。
- 切租户/换账号:名称正确、零串数据;缓存按 scope 隔离。
- 验证:Xcode 控制台读 `[JHT Perf] main_shell_appeared_ms` / `conversation_list_ready_ms`;抓 `conversations/sync` 响应确认 `peer_name`/`group_name`;杀进程冷启动 + 重进同企业计时。

### 9.6 本轮落地(2026-06-22 / 客户端)
已直接实现以下客户端措施(纯 iOS、不改 UI 外观/语义、不引入依赖):
- **B3 — 群/联系人去 2.2s 延迟**:`refreshSecondarySnapshotInBackground`(`AppState.swift`)把 `refreshGroupsInBackground` + `refreshContactsAndNoticesInBackground` 提到立即并行触发;文件/租户资料/设备注册仍延迟。→ 名字从十几秒缩短到约 1 个往返补正。
- **A4 — 产品路径不物理删长期内容缓存**:`selectEnterprise` 进入 Task 移除旧的远端快照物理删除;缓存按 scope 隔离,保留以便秒显。按 2026-06-23 用户最终口径,退出登录 / DEBUG auth reset / 安全封禁 / 企业访问阻断也不得物理删除长期内容缓存,只清凭证、连接和当前活跃内存视图。
- **A1 — 进入接缓存秒显**:`switchPlatformTenant` + `enterIM` 后加 `applyCachedRemoteSnapshotIfAvailable(context:)`,重进同企业即时渲染列表(含已解析真名),再后台 `refreshRemoteSnapshot` 合并。
- **Batch 7 — 恢复期可交互**:`BlueStoneIMApp` 根视图 gate 改为仅 `isShowingLaunchSplash` 显示全屏封面;恢复登录期间直接进 `MainShellView`(tabs 可点、会话区显示加载骨架),不再整屏不可操作。
- **B4** 由现有 `conversationTitle`(真名非 identifier-like 时保留)+ A1 共同保证:进入接缓存后真名不被 ID 覆盖。

**未做(需后端,建议下一步)**:
- **B1 — 服务端 `conversations/sync` 返回 `peer_name`/`group_name`** + **B2 客户端解析**:这是"首装/首次进入也立刻有名字"的根治项;需改 Go(`server/internal/im`)+ `codegraph sync .` + 部署,故未在本轮客户端改动内完成。
- **A2/A3**(两次网络解耦 + 更短首屏超时兜底):可选增量,本轮未做。

**验证**:需在 Xcode 真机/模拟器 ⌘R 复测:重进同企业是否秒显、恢复期 tabs 是否立即可点、名字是否 ~1s 内变真名;读 `[JHT Perf]` 打点确认。

### 9.7 B1 + B2 实现规格(服务端返回会话名 + 客户端解析)——交执行方

> 目标:**首装/首次进入某企业时,会话名首帧即为真实姓名/群名**(不依赖本地通讯录/群资料加载)。
> 可行性已确认:`im_user.nickname`(对端昵称)与 `im_group.name`(群名)都在 im 服务可访问的库;direct 会话的 `PeerIMUID` 已由 `normalizeConversationForAPI`(`server/internal/im/system_channel.go:74-79`)派生。

#### 9.7.1 服务端(Go,`server/internal/im`)

1. **模型加字段** — `model.go` 的 `Conversation`(`:145`)新增可选字段:
   ```go
   DisplayName string `json:"display_name,omitempty"` // 单聊=对端昵称,群聊=群名
   ```
   (向后兼容,老客户端忽略。)

2. **填充名字** — 在 `postgres.go` 的 `enrichConversationsForViewer`(`:970`)末尾、`return conversations, nil` 前,批量解析并赋值;**名字解析失败不得让 sync 报错**(降级为不带名字):
   - 收集 direct 会话的 `PeerIMUID` 集合、group 会话的 `ChannelID`(=group_id)集合。
   - 一次 `SELECT im_uid, COALESCE(NULLIF(nickname,''),'') FROM im_user WHERE tenant_id=$1 AND im_uid IN (...)` 得到对端昵称表。
   - 一次 `SELECT group_id, COALESCE(NULLIF(name,''),'') FROM im_group WHERE tenant_id=$1 AND group_id IN (...)` 得到群名表。
   - 回填:direct→`conversations[i].DisplayName = 对端昵称`;group→`= 群名`(空则不设)。
   - 建议封装 `queryNameMap(ctx, query, tenantID, ids) (map[string]string, error)` 复用两段查询;`fmt`/`strings`/`context` 均已在该文件引入。
   - 调用处用 `if withNames, err := r.applyConversationDisplayNames(...); err == nil { conversations = withNames }`,保证失败时静默降级。

3. **内存 Store(可选)** — `store.go` 的 `SyncConversations`(`:863`)是另一套实现(测试/内存)。可镜像同样逻辑;不做也可(该路径 `DisplayName` 为空,客户端回退本地解析)。

4. **测试** — `handler_test.go` 用 `omitempty` 不影响既有断言;若有对会话结构做全等断言处,补 `DisplayName` 期望值。新增 1 条断言:direct/group sync 返回的 `display_name` 等于对应昵称/群名。

5. **收尾** — 改完在项目根 `/Users/.../IM2` 跑 `codegraph sync .`(CLAUDE.md 规则);服务端重新部署。

#### 9.7.2 客户端(Swift,`AppState.swift`)

1. **解析字段** — `RemoteConversation`(`:17973` 一带)新增 `displayName` 解析:CodingKeys 加 `case displayName = "display_name"`,`init` 里 `displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""`。

2. **优先用服务端名字** — `applyRemoteConversations`(`:9884`)里把
   ```swift
   let title = conversationTitle(channelID: channelID, kind: kind, previous: previous)
   ```
   改为 `var title = ...`,其后追加:
   ```swift
   let serverName = remote.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
   if !serverName.isEmpty {
       let idForCheck = kind == .group ? channelID : directConversationPeerID(channelID)
       if title.isEmpty || isIdentifierLikeDisplayName(title, matching: idForCheck) {
           title = serverName
       }
   }
   ```
   语义:本地能解析出真名(通讯录/群资料已在、或本地备注)就用本地;否则用服务端名字;两者都没有才回退 ID。不影响本地备注优先级。

#### 9.7.3 验收
- 抓 `/api/im/conversations/sync` 响应,确认每条含 `display_name`(单聊=昵称、群聊=群名)。
- **首装/首次进入某企业**:会话列表首帧即真实名称,无 ID 占位、无需等 contacts/groups。
- 本地有备注的会话仍显示备注(本地优先未被破坏)。
- 切租户/换账号名称正确;服务端未返回名字时回退本地解析,不崩不卡。
- Go 单测通过;`codegraph sync .` 通过。

**验证方式**
- Debug 构建验证 Swift 编译与资源链接。
- 覆盖安装启动模拟器,确认 app 可拉起。
- CodeGraph sync/query 验证索引可读。
- Instruments 的 Animation Hitches / Time Profiler 和真机帧率数据仍需方案方在目标设备上补测;本轮未提供真机 Instruments 数据。

### 2026-06-21 / 性能优化计划回收审计

本轮只做状态核对和验收记录补齐,不改核心业务代码。核对范围包括 `PERF_OPT_PLAN.md`、`AppState.swift`、`ConversationViews.swift`、`ChatViews.swift`、`DesignSystem.swift`、`AuthViews.swift` 的当前实现。

**已落地项**
- Batch 1 启动 gate 解耦已在 `syncPrimaryConversationData` 落地:会话列表同步成功后立即设置 `hasLoadedRemoteSnapshot=true` 并输出 `conversation_list_ready_ms`,历史预取通过 `startConversationHistoryPrefetch` 后台执行。
- 历史预取已按最近 12 个会话、最大并发 6 的窗口批处理执行;消息写入仍回到 `applyRemoteMessages` 串行合并,read receipts 在历史预取完成后后台补齐。
- Batch 2 会话列表派生数据缓存已落地:`ConversationListView` 使用 `ConversationRenderSections` 缓存 matching/pinned/regular 分段,减少 body 内重复 filter/sort。
- 消息页滚动首批优化已落地:`ChatView` 旧记录加载提前到顶部 3 条内触发,`AppState.loadOlderMessagesIfAvailable` 对同一历史 scope 做短窗口节流。
- 头像/远端图片首批缓存已落地:`AvatarImageCache` 与 `CachedRemoteImage` 负责同 URL in-flight 合并、后台下载和 `byPreparingForDisplay()` 预解码,头像上传后继续写入缓存。
- Batch 5 登录/注册页卡顿优化已落地:`AuthBackground`/`AuthParticles` 从 30fps 降到 20fps,输入聚焦、键盘、authScreen 转场、翻牌和账号/手机号切换期间临时暂停背景动画;`AuthFlipView` 稳定态只构建当前面。

**未落地项 / 风险项**
- 原计划 Batch 3 的磁盘轻量缓存 DTO 已在后续批次落地为轻量首屏缓存;仍需在 UAT 中验证切账号/切企业、缓存过期和坏缓存兜底。
- Batch 4 已在后续批次落地最小 WS 重连 refresh 节流;弱网重连场景仍建议后续用 Network instrument 观察重复请求,完整重连请求图谱优化可继续排期。
- Instruments 量化验收仍未补齐。当前已有 `[JHT Perf] restore_start`、`conversation_list_ready_ms`、`history_prefetch_complete_ms` 打点,但 Animation Hitches / Time Profiler / GPU 需要在目标机型或指定模拟器环境补录。
- 文档早期章节仍保留“Batch 3”作为磁盘缓存计划项,后续记录中的“Batch 3:会话详情进入/历史分页性能”是消息页专项首批优化命名,不是原计划磁盘缓存项;后续排期建议统一批次命名避免误读。

**后续建议批次**
- 优先补 Batch 3/4 的 UAT 与 Instruments/Network 数据,确认缓存命中首页放行、切账号不串数据、重连不重复大刷新。
- 若弱网仍有请求风暴,再做完整重连请求图谱优化,把全量 snapshot、当前会话 sync、RTC events、系统通知 refresh 拆成分级对账。
- 真机或指定模拟器补录 Batch 1/2/5 的 Instruments 指标,把打点数据回填到本计划。

**对当前验收影响**
- 不影响当前语音事件、文件/图片/视频消息、群置顶消息验收。本轮没有改这些业务路径,只是回收性能计划状态。

### 2026-06-21 / Batch 3 磁盘轻量缓存 + Batch 4 重连节流止血

**Batch 3:轻量磁盘缓存 DTO 已落地**
- 新增独立 `CachedRemoteSnapshot` DTO,不让 `Conversation` / `ChatMessage` / `IMUser` 领域模型直接实现 `Codable`。缓存内容只包括会话列表、参与者和每会话最近 40 条消息的展示字段,不缓存 token、登录凭证或请求 header。
- 缓存文件位于 app Caches 下的 `BlueStoneIMRemoteSnapshots`,文件名由 `remoteDataScopeKey(account_id|tenant_id|im_uid|app_id|device_id)` 派生;读取时校验 schema version、scope 和 24 小时有效期。
- 恢复登录时先尝试读取当前 scope 缓存,命中后立即放行会话列表并继续后台真实 `conversations/sync`;真实 sync 成功后覆盖缓存渲染结果,并异步写回新缓存。
- 退出登录、Debug 重置登录态和切换企业前会清理当前 scope 缓存,避免旧账号/旧企业会话串入新上下文。

**Batch 4:WS 重连 refresh 最小节流**
- WebSocket 断开提示增加客户端节流:同一轮重连中最多约 30 秒提示一次“实时连接中断，正在重连”,连接恢复后清理该提示状态。
- `connect_ack` 与重连后的整轮 `refreshRemoteSnapshot(force:true)` 改为统一 `scheduleRealtimeRecoveryRefresh`,8 秒窗口内合并重复大刷新;当前打开会话仍可做静默消息对账,RTC calls/events 兜底仍随恢复刷新执行。
- 前台恢复也复用同一恢复刷新调度,避免前台、重连、connect_ack 短时间内连续触发大刷新、重复 unread/read-ack 和派生列表重算。

**用户可见同步错误止血**
- 群聊历史同步失败时,页面内错误状态仍保留“聊天记录同步失败,请稍后重试”;后台/重连触发的同步失败只记录 endpoint 日志,不再每几秒叠加全局 toast。
- 手动进入会话触发的历史同步失败仍会提示,但同一会话 20 秒内只提示一次。鉴权失败、账号/企业/成员禁用等不可恢复错误仍走明确业务提示,并停止盲目重连。

**剩余风险**
- 本轮未补真机 Instruments 数据。缓存命中时的首页放行可用 `[JHT Perf] cached_snapshot_applied` 与后续 `conversation_list_ready_ms` 对照验证;重连节流可通过 WS 断开/恢复日志与 toast 观察验证。
- 轻量缓存只服务首屏展示和最近消息,更早历史仍依赖历史分页接口;后端 sync 始终是最终真实数据来源。

### 2026-06-21 / 剩余项安全推进与验收脚本

本轮按“避开许可证动态能力并发改动”的要求,只推进不触碰 `AppState.swift`、`ChatViews.swift` 核心业务逻辑的安全项。许可证动态能力、`@所有人`、`@昵称` 点击、系统通知 read-all 均不在本轮处理范围。

**本轮推进**
- 新增 `scripts/collect-perf-logs.sh`,用于采集模拟器中 BlueStoneIM 已有的 `[JHT Perf]` / `[JHT Sync]` 日志,并汇总:
  - `cached_snapshot_applied` 缓存命中次数;
  - `conversation_list_ready_ms` 首页会话列表就绪 min/avg/max;
  - `history_prefetch_complete_ms` 历史预取完成 min/avg/max;
  - `realtime_recovery_refresh` 重连恢复刷新次数;
  - endpoint/snapshot/history sync failure 计数;
  - “实时连接中断”toast 样本数。
- 脚本只读系统日志,不修改 App 状态、不注入调试开关、不依赖后端新合同。示例:
  ```bash
  code/apps/ios-chat/scripts/collect-perf-logs.sh --seconds 90
  code/apps/ios-chat/scripts/collect-perf-logs.sh --udid C4F590F7-E193-4EDB-8FF2-4AC5F250B116 --output /tmp/im2-perf.log
  ```

**继续等待 / 需要避开冲突的项**
- 完整重连请求图谱优化仍需改 `AppState.swift`,应等待许可证动态能力接入稳定后再排期。
- 消息页进一步局部渲染、mention 样式和气泡交互会涉及 `ChatViews.swift`,本轮不并发改。
- Batch 3 缓存坏文件注入、切账号 UAT、Batch 1/2/5 的 Instruments Hitches/Time Profiler/GPU 量化仍需真实运行环境补录;本轮脚本仅提供日志采集入口,不能替代 Instruments。

### 2026-06-21 / 剩余项安全推进:远端图片缓存边界

本轮在 iOS执行1 仍持有聊天核心文件的情况下,只推进不触碰 `AppState.swift`、`ChatViews.swift`、`ConversationViews.swift` 的安全性能项。

**本轮完成**
- `AvatarImageCache` 保持既有同 URL in-flight 合并、后台下载和 `UIImage.preparingForDisplay()` 预解码逻辑,新增轻量 LRU 边界。
- 远端头像/企业 logo 内存缓存最多保留 160 张图片;读取命中会刷新最近使用顺序,写入超限后淘汰最久未使用项。
- 该改动不改变后端 URL 解析、头像上传后的缓存写入、占位图或展示样式,只限制长时间滚动联系人/群成员/会话列表后的图片缓存增长。

**本轮跳过**
- 完整 WS 重连请求图谱优化、消息页局部渲染和会话列表进一步派生缓存都可能触碰 `AppState.swift`、`ChatViews.swift` 或 `ConversationViews.swift`,需等待 iOS执行1 当前核心任务稳定后再排队。
- Instruments Animation Hitches / Time Profiler / GPU 量化仍未补录;本轮仅通过 Debug 构建和代码路径验证。

### 2026-06-21 / 剩余项收口:聊天图片缩略图与预览复用远端图片缓存

本轮避开登录、企业选择和验证码相关文件,只处理会话/消息媒体渲染中可独立回退的低风险性能点。

**本轮完成**
- `CachedRemoteImage` 从头像内部组件开放为通用远端图片组件,保留同 URL in-flight 合并、后台下载、`UIImage.preparingForDisplay()` 预解码和 LRU 内存上限。
- 聊天图片消息缩略图从 SwiftUI `AsyncImage` 切换为 `CachedRemoteImage`,快速滚动重复出现同一图片时复用已预解码 `UIImage`,减少重复网络请求、主线程解码和缩略图闪烁。
- 图片预览 sheet 从 `AsyncImage` 切换为同一缓存组件;保存图片时也复用 `AvatarImageCache.remoteImage(for:)`,避免预览后保存再次下载同一 URL。
- 不改变文件/图片/视频消息的后端 URL 口径,仍只消费 `resolvedAttachmentPreviewURL` / `resolvedAttachmentDownloadURL`,不拼接 OSS/CDN/dev-object 地址。

**跳过 / 后续观察**
- 完整 WS 重连请求图谱优化仍需触碰 `AppState.swift`,本轮按并行约束跳过。
- 消息气泡更细粒度的 Equatable row / 分段 diff 需要更大范围验证,本轮不做。
- Instruments Animation Hitches / Time Profiler 仍需在目标设备上补录;本轮用 Debug build 和可运行检查验证 Swift 编译与 App 启动。

### 2026-06-21 / 剩余性能项继续推进:消息行解析收窄与远端图片复用保护

本轮只处理性能与滚动体验,不改业务合同、消息状态、企业选择、语音、文件媒体能力或 mention 语义。

**本轮完成**
- `ChatView` 消息行发送人解析继续沿用轻量 `ChatMessageRenderRow`,但 `MessageSenderResolver` 的用户索引来源从“当前用户 + 会话参与者 + 全部联系人 + 所有群成员”收窄为“当前用户 + 会话参与者 + 全部联系人 + 当前群成员/管理员”。这避免消息列表每次 body 重算时扫描所有群的成员集合,尤其降低多群/大群账号进入单个会话后的主线程字典构建成本。
- `CachedRemoteImage` 在 URL 未命中缓存时先清空旧图,并在异步下载返回后检查任务是否已取消,避免快速滚动或 SwiftUI 复用远端图片 view 时旧 URL 请求回填到新行造成短暂错图/闪烁。

**不变量**
- 发送人展示仍优先使用当前会话参与者、联系人和当前群成员资料;缺资料时仍回退消息自带 `senderName/senderId`,不影响历史消息顺序、已读/送达、撤回、reaction 或附件渲染。
- 远端图片仍只消费后端返回 URL,继续使用 `AvatarImageCache` 的 in-flight 合并、后台下载、预解码和 LRU 上限;不新增 local/OSS/CDN provider 分支。

**仍未完成 / 风险**
- 完整 WS 重连请求图谱优化仍需更大范围修改 `AppState.swift`,建议在弱网 Network instrument 下确认是否还有 request storm 后再排期。
- 消息气泡 Equatable row / 分段 diff 涉及更多状态输入,仍需真机 Instruments + UAT 覆盖后再推进。
- 本轮未补真机 Hitches/Time Profiler 量化,只用 Debug 构建、模拟器启动和代码路径验证。

### 2026-06-21 / Batch 4 继续推进:实时事件兜底全量刷新去重

本轮按剩余性能大包继续推进低风险、高收益项,只收敛 realtime fallback 的重复全量同步,不改变消息、未读、已读、系统通知、附件、语音入口等业务合同。

**本轮完成**
- `refreshRealtimeFallback` 在无法按 `channel_id/channel_type` 定位本地会话时,不再立即发起独立 `refreshRemoteSnapshot(force:true)`,改走已有 `scheduleRealtimeRecoveryRefresh`。该调度器会在 650ms 后执行统一对账,且 8 秒窗口内合并重复恢复刷新。
- `message_extra` 的 decode fallback、未知 extra、reaction/pin 已本地应用后的兜底刷新统一走 `scheduleRealtimeRecoveryRefresh`,避免同一时间一批 reaction、pin、conversation_update、connect_ack 事件各自触发整轮 conversations sync。
- `message_receipt` fallback 在缺少 channel 或本地找不到会话时同样走统一恢复刷新调度;能定位当前会话时仍只同步该会话消息、extras 和 read receipts,保持已读状态及时刷新。

**不变量**
- `connect_ack`、`conversation_update`、WS 重连、前台恢复仍使用原恢复调度器;RTC calls/events 仍在调度器里对账,不会被吞掉。
- 能定位到具体会话的 realtime fallback 仍优先做单会话 `syncConversationMessagesIfNeeded`,不会因为节流而漏掉当前聊天页新消息。
- 用户主动操作后的刷新(加好友、建群、审批、撤回等)仍保留原即时 refresh,本轮只处理实时事件兜底路径。

**验证方式**
- Debug Simulator 构建通过即可证明 Swift actor/异步路径可编译。
- 后续弱网或 WS 事件风暴 UAT 可用 `scripts/collect-perf-logs.sh --seconds 90` 观察 `realtime_recovery_refresh` 与 `conversation_list_ready_ms` 样本,预期多条 fallback 事件在 8 秒窗口内合并为更少的全量 refresh。

### 2026-06-21 / 会话列表行级派生缓存补齐

本轮继续按低风险性能收口推进,只处理会话列表渲染热区,不改登录/企业选择、`@所有人`/普通 mention 业务语义、附件、语音、撤回或已读逻辑。

**本轮完成**
- `ConversationRenderSections` 从直接缓存 `Conversation` 数组改为缓存轻量 `ConversationRenderItem`,在分段缓存重建时一次性计算每个会话行的 `unreadMention` 预览。
- `ConversationInteractiveRow` 渲染时直接消费缓存好的 mention preview,避免 SwiftUI body 因 toast、导航、搜索栏等无关状态重绘时,每行再次对会话尾部未读消息做 `suffix/filter` 扫描。
- 分段过滤、置顶排序、未读角标、`@我` 筛选与点击进入会话规则保持不变;该优化只移动计算时机,不改变展示结果。

**验证方式**
- Debug 构建用于验证 SwiftUI 泛型行模型与缓存更新可编译。
- 后续可在大量会话/大量未读消息账号上用 Animation Hitches 或简单 body 计数观察会话列表重绘成本,预期无关状态刷新时行级 mention 预览不再重复扫描消息尾部。

### 2026-06-21 / Batch 2 继续推进:会话列表 @我 派生数据缓存

本轮继续处理列表/消息渲染减少重复重算,只收敛会话列表页 `@我` 筛选的派生数据扫描,不改变消息展示、未读、已读、系统通知、附件、语音入口或 mention 业务语义。

**本轮完成**
- `ConversationListView` 新增 `cachedMentionRecords` 与 `cachedUnreadMentionCount`,把 `@我` 消息记录和 @ 未读计数从 body 每次重绘时的即时遍历,改为在会话数据、搜索词或当前用户身份变化时重算。
- 普通会话分段缓存继续沿用 `cachedConversationSections`;`@我` 切换时直接复用已生成的 mention 记录,避免长会话列表或实时消息刷新时重复 `flatMap` 所有会话消息。

**不变量**
- `@所有人`、普通结构化 `@用户`、未读 @ 计数和点击进入会话规则不变;候选/详情稳定身份逻辑不在本轮修改。
- 搜索词变化仍会刷新 `@我` 记录;当前用户 ID 或昵称变化时也会重新计算 mention 匹配目标。

**后续观察**
- 如果后续 Instruments 显示会话列表仍有 body 热点,下一步再考虑缓存 `alertingUnreadTotal`、公告未读条目或将 `ConversationRenderSections` 抽到更靠近 `AppState` 的派生层;本轮先保持最小改动面。

### 2026-06-21 / Batch 2 继续推进:会话列表未读与公告派生缓存

本轮继续沿着会话列表渲染减少重复重算推进,只处理 `ConversationListView` 内部派生数据,避开历史消息同步、分页游标和消息缓存语义。

**本轮完成**
- `alertingUnreadTotal` 从 body/filter badge 路径的即时扫描改为 `cachedAlertingUnreadTotal`,只在 `state.conversations` 变化或首次出现时重算。搜索框输入、筛选切换、sheet/toast 等无关刷新不再重复遍历所有会话计算未读总数。
- 未读公告 banner 从 body 内 `state.inboxItems.filter` 改为 `cachedAnnouncementItems`,只在 `state.inboxItems` 变化或首次出现时重算,减少会话列表无关状态刷新时对 inbox 的重复过滤。
- query 变化时只刷新搜索相关的普通会话分段和 `@我` 记录,不再顺带刷新未读总数;filter 变化继续只刷新会话分段。

**不变量**
- 非免打扰未读总数、公告 `kind=announcement`/`isAnnouncement` 过滤、系统通知 read-all、公告单条 read、会话排序和 `@我` 筛选语义不变。
- 本轮不触碰 `AppState` 的历史同步、消息分页、WebSocket 重连、附件、语音或许可证能力逻辑。

**验证**
- Debug Simulator 构建作为行为等价和 SwiftUI `onChange` 编译检查。
- 仍需后续用 Instruments Animation Hitches / SwiftUI body 计数在 50+ 会话、频繁 toast/搜索场景下补量化数据。

### 2026-06-21 / 远端图片缓存内存压力收口

本轮继续选择低冲突性能项,不触碰登录/企业选择、附件发送、语音、公告收件箱、mention 或消息历史同步业务逻辑。

**本轮完成**
- `AvatarImageCache` 在已有同 URL in-flight 合并、后台下载、预解码和 160 张 LRU 上限基础上,接入 `UIApplication.didReceiveMemoryWarningNotification`。
- iOS 发出内存警告时只清空已完成的远端图片内存缓存与 LRU 顺序,不主动改写 URL、不取消业务状态、不引入 local/OSS/CDN 分支;后续可见图片仍按现有 `CachedRemoteImage` 路径重新按需下载。
- 该优化面向大群头像、文件列表缩略图、聊天图片预览来回切换后的内存压力,预期降低后台/前台切换或系统内存紧张时被系统回收的概率。

**不变量**
- 头像上传后的本地缓存写入、远端图片占位、附件预览、消息发送、已读、撤回、语音入口和公告/系统通知未读逻辑均不变。
- 缓存仍只消费后端返回 URL,不拼接 OSS/CDN/dev-object 域名。

**仍未完成 / 风险**
- 本轮为内存压力防护,不是滚动帧率量化;仍需后续在目标真机用 Instruments Memory Graph、Animation Hitches 或 Time Profiler 记录前后数据。
- 更细粒度消息气泡 diff、完整 WS 请求图谱优化仍属于较大核心文件改动,建议继续按专项排期。

### 2026-06-21 / 文件列表过滤派生缓存

本轮继续选择低风险、可独立验证的列表渲染优化,不触碰登录/企业选择、消息历史分页、附件发送上传核心、语音、公告收件箱或 mention 业务逻辑。

**本轮完成**
- `FilesView` 新增文件列表过滤派生缓存,只在 `state.files`、搜索词或文件分类变化时重算文件列表。
- sheet、预览 loading、toast、导航等无关状态触发 body 重绘时,不再重复遍历全部文件并反复计算 `FileItem.visualKind`。
- 搜索和分类语义保持不变:搜索仍匹配文件名、发送人、来源;分类仍覆盖 PDF、图片、视频、表格、文档、压缩包和音频。

**不变量**
- 文件预览、下载、QuickLook、系统分享、图片/视频缩略图、类型 Logo、后端 URL 消费口径和“无删除入口”产品规则均不变。
- 不新增网络请求、不改 provider 分支、不改变附件上传/发送/失败重试流程。

**仍未完成 / 风险**
- 该项收益主要体现在文件数量较多、频繁打开预览或搜索切换时;小列表体感变化可能不明显。
- 仍需用 Instruments 在真实 100+ 文件列表中补 Animation Hitches / Time Profiler 量化。

### 2026-06-21 / 通讯录分组派生缓存

本轮继续推进不触碰登录企业选择、token/switch、消息历史和公告 read-all 的低风险列表渲染优化。

**本轮完成**
- `ContactsView` 新增通讯录分组派生缓存,只在 `state.contacts` 或搜索词变化时重算。
- 联系人搜索过滤、排序和首字母分组从每次 body 重绘的即时计算,收敛到数据/查询变化时计算。
- 联系人详情导航、toast、sheet、选中联系人等无关状态变化不再重复执行 `IMUserSearchMatcher`、排序和 `Dictionary(grouping:)`。

**不变量**
- 搜索匹配规则、联系人分组、空态、用户详情和进入会话行为不变。
- 群成员筛选、邀请成员和同名 `@` 稳定身份逻辑不在本轮修改,避免和其它业务任务交叉。

**仍未完成 / 风险**
- 收益主要体现在联系人数量较多和频繁打开/关闭详情页时;小通讯录体感变化可能不明显。
- 仍需用 Instruments 在 500+ 联系人场景补 Animation Hitches / Time Profiler 量化。

### 2026-06-21 / 文件列表行级展示派生缓存

本轮继续推进附件/文件列表方向的低风险优化,不触碰附件上传发送、预览下载、登录企业选择、许可证能力或公告 read-all 逻辑。

**本轮完成**
- `FilesView` 的过滤缓存从 `[FileItem]` 升级为轻量 `FileRenderItem`,在 `state.files`、搜索词或分类变化时一次性生成行级展示模型。
- `FilePresentation` 缓存 `visualKind` 与缩略图 URL,文件行和缩略图组件直接复用结果,避免预览 sheet、loading、toast 等无关状态刷新时反复执行媒体类型推断和缩略图候选 URL 选择。
- 文件点击仍回传原始 `FileItem` 给预览 sheet,下载、QuickLook、分享和系统打开逻辑保持原路径。

**不变量**
- 搜索、分类、文件预览、下载、分享、图片/视频缩略图、类型 Logo 和后端 URL 消费口径不变。
- 不新增网络请求,不拼接 OSS/CDN/dev-object/bucket/object key,不改变附件发送、失败重试或取消流程。

**仍未完成 / 风险**
- 该项收益主要体现在文件数量较多且页面存在频繁无关状态刷新时;小文件列表体感变化可能不明显。
- 仍需在 100+ 文件列表场景用 Instruments Animation Hitches / Time Profiler 补充量化。

### 2026-06-21 / 消息列表行模型派生缓存

本轮继续推进 `PERF_OPT_PLAN.md` 中消息列表/滚动热区的低风险项,避开系统通知、公告收件箱、入群审批卡片、登录企业选择和附件媒体主功能语义。

**本轮完成**
- `ChatView` 新增 `cachedMessageRows` 与 `cachedMessageRowIDs`,消息列表渲染优先复用已生成的 `ChatMessageRenderRow`。
- 消息行发送人解析、显示名补全和 sender header 判断只在消息数组、会话参与者、联系人、当前用户或当前群成员/管理员变化时重算。
- 弹出消息操作 sheet、附件图片/视频预览、搜索面板、toast、滚动目标和其它无关状态刷新时,不再重复为整屏消息构建 `MessageSenderResolver` 并扫描联系人/群成员。

**不变量**
- 消息顺序、未读分割线、顶部历史分页、已读/送达状态、reaction、附件预览、普通 `@用户` 和 `@所有人` 样式/点击行为保持不变。
- 发送人资料来源仍是当前用户、会话参与者、联系人和当前群成员/管理员;不会按昵称反查,也不改变同名用户稳定身份规则。

**仍未完成 / 风险**
- 本轮属于主线程派生计算收敛,收益主要体现在长消息列表、频繁打开 sheet/预览或实时 receipt/reaction 刷新时。
- 真机 Instruments Animation Hitches / Time Profiler 仍需补录;本轮用 Debug 构建和代码路径验证行为等价。

### 2026-06-21 / 远端图片缓存解码成本预算

本轮选择头像、企业 logo、文件列表缩略图和聊天图片缩略图共用的 `AvatarImageCache`,避开 `ChatViews.swift`、系统通知、公告收件箱、入群审批卡片、登录企业选择和附件发送主语义。

**本轮完成**
- `AvatarImageCache` 在已有同 URL in-flight 合并、后台下载、预解码和 160 张 LRU 上限基础上,新增约 64 MiB 解码后图片字节预算。
- 缓存写入时记录 `cgImage.bytesPerRow * height` 等实际解码成本,超过数量或字节预算都会按最近使用顺序淘汰旧图,避免少量大图让缓存长期占用过高内存。
- 异步 `remoteImage(for:)` 的缓存命中改为复用 `image(for:)`,命中时同样刷新 LRU 顺序,避免活跃图片在 count/byte 淘汰时被误当作旧图。
- iOS 内存警告清理时同步重置图片成本表和累计字节数,避免清空图片后成本统计残留。

**不变量**
- 图片显示内容、占位、失败态、点击预览、附件缩略图和头像 URL 消费口径不变。
- 不新增网络请求,不取消 in-flight 下载,不拼接 OSS/CDN/dev-object/bucket/object key,不改变附件上传/发送或预览语义。

**仍未完成 / 风险**
- 本轮是内存占用上限收口,不包含真机 Instruments Memory Graph 或滚动掉帧量化;需在大群头像、文件列表 100+ 缩略图和聊天图片来回切换场景继续补测。
- 缓存按原图解码尺寸统计成本,暂不对原图做强制下采样,避免影响图片预览清晰度;若后续内存仍高,建议增加按显示目标尺寸的独立缩略图缓存层。

### 2026-06-21 / 文件列表系统预览下载去重

本轮选择文件 Tab / 文件详情的 QuickLook 系统预览下载器,避开 `ChatViews.swift`、`ContactsViews.swift`、群置顶、`@` 候选、公告收件箱、登录企业选择和附件发送主语义。

**本轮完成**
- `SystemPreviewLoader` 改为通过 `SystemPreviewDownloadStore` actor 统一准备本地预览文件。
- 同一 `preview_url/download_url + 建议文件名` 的并发预览请求复用同一个 in-flight 下载任务,避免用户连续点击列表行和详情“预览”时重复下载同一文件。
- 下载完成后的非空临时预览文件会直接复用,减少重复打开同一 PDF/Office/图片/视频时的网络请求和 QuickLook 等待时间。
- 临时文件按 URL hash 子目录隔离,同名但不同 URL 的文件不会互相覆盖;`file://` 本地 URL 直接返回,不再交给 `URLSession.download`。

**不变量**
- 文件列表点击、文件详情预览、下载/打开、系统分享、错误兜底和类型图标保持不变。
- 客户端仍只消费后端返回的 `preview_url/download_url`,不拼接 OSS/CDN/dev-object/bucket/object key。
- 本轮不改聊天附件消息气泡和附件发送上传进度逻辑,避免与聊天核心任务冲突。

**仍未完成 / 风险**
- 聊天消息附件详情里的 `AttachmentSystemPreviewLoader` 仍是独立下载路径;如后续确认无同文件冲突,可把同一去重 store 抽到共享文件后复用。
- 本轮没有真机 Network Instruments 抓取;用 Debug 构建和代码路径验证去重行为。真实 UAT 建议连续打开同一 PDF 或图片文件,确认第二次不再触发网络下载。

### 2026-06-21 / APIClient 幂等 GET in-flight 去重

本轮选择独立网络层 `IMAPIClient`,避开 `ChatViews.swift`、群 `@` 候选、群置顶、附件媒体主交互和登录企业选择逻辑段。

**本轮完成**
- `IMAPIClient` 新增幂等 GET 请求 in-flight 合并表,同一 `base + path/query + bearer` 的并发 GET 会复用同一个 `URLSession` 任务结果。
- 去重只覆盖无 body 的 GET,不缓存响应、不跨请求生命周期保留结果;第一个请求完成后立即移除 in-flight 记录,后续刷新仍会重新访问后端。
- `GET /api/rtc/calls/events` 是 clear-on-read 兜底事件接口,已明确排除去重,避免多消费者被合并后丢掉清空式事件边界。
- HTTP 状态码、`X-Request-ID`、`Retry-After`、业务错误码和空响应处理仍沿用原有路径;失败会传播给所有等待者,不会本地假成功。

**不变量**
- `POST/PUT/PATCH/DELETE`、登录/企业切换、系统通知 read-all、附件上传、消息发送、已读回执和 RTC 事件语义不变。
- 客户端仍只按后端返回 URL 与业务 code 处理,不新增本地接口 fallback 或响应缓存。

**仍未完成 / 风险**
- 本轮是并发重复请求收敛,不是离线缓存;同一接口串行重复刷新仍按原逻辑请求后端。
- 未接入 Network Instruments 抓包量化;建议后续在会话列表/文件列表/资料页同时刷新时观察重复 GET 请求数量下降。

### 2026-06-21 / 群列表行级派生缓存

本轮继续选择不触碰 `ChatViews.swift`、群 `@` 候选、群置顶、登录企业选择或附件发送主语义的低风险性能点,收敛通讯录群列表的重复计算。

**本轮完成**
- `GroupListView` 新增 `GroupListRenderSections` 与 `GroupListRenderItem`,把“我创建 / 管理”和“我加入的”两段群列表以及每行对应会话一次性缓存。
- 缓存只在 `state.groups`、`state.conversations`、当前用户 ID 或当前用户名变化时重建;导航到会话、打开详情、toast/sheet 等无关状态刷新时复用行模型。
- 原先每次 body 重绘都会两次过滤 `state.groups`,且每个群行都会线性扫描 `state.conversations` 查找会话;现在这些扫描集中到缓存重建时执行。

**不变量**
- 群管理权限仍走 `state.canManageGroup`,群分组、未读角标、头像 URL、点击进入会话、`loadGroupDetailIfNeeded` 和 accessibility 文案不变。
- 不改群成员筛选、同名 `@`、群置顶、聊天历史分页或消息同步逻辑。

**仍未完成 / 风险**
- 收益主要体现在群数量较多、频繁进入/返回群列表或列表上叠加弹层/toast 的场景;小群列表体感可能不明显。
- 未接入 Instruments;后续可在 100+ 群账号上用 Animation Hitches 或 SwiftUI body 计数补量化。

### 2026-06-21 / 头像缓存 body 只读命中

本轮继续推进远端图片/头像显示侧的低风险优化,只触碰 `AvatarImageCache` 与 `AvatarView`,避开 `AppState.swift` 语音/RTC 状态机、聊天附件发送、系统通知、公告收件箱和 mention 业务。

**本轮完成**
- `AvatarImageCache` 新增 `peekImage(for:)`,用于 SwiftUI `body` 渲染路径只读获取已缓存图片,不刷新 LRU 顺序。
- `AvatarView.avatarBody` 从 `image(for:)` 切换为 `peekImage(for:)`;快速滚动、toast、sheet 或父视图无关状态导致头像行重绘时,不再为每个已缓存头像执行 `accessOrder.removeAll + append`。
- 真正的异步加载、缓存命中和保存路径仍使用 `image(for:)` / `remoteImage(for:)`,继续刷新 LRU 与字节预算,保证缓存淘汰策略不退化。

**不变量**
- 头像、企业 logo、文件缩略图和聊天图片显示内容不变;占位、失败态、上传头像后的缓存写入、远端 URL 消费口径均不变。
- 不新增网络请求、不拼接 OSS/CDN/dev-object、不改变附件、消息、已读、撤回、语音或公告/系统通知语义。

**仍未完成 / 风险**
- 本轮是代码路径上的主线程小成本收敛,未取得真实 SwiftUI body 计数或 Instruments 数据。
- 后续建议在 100+ 会话头像、500+ 通讯录和大群成员列表中补 Animation Hitches / Time Profiler,观察头像行重绘期间主线程数组操作下降。

### 2026-06-22 / 进入群聊首屏轻量化与请求去重

本轮针对“进入群聊后卡一阵”做源码级链路审计并落地低风险收口,只处理聊天页进入群聊前几秒的任务瀑布,不改变公告顶部条、附件媒体、回复 quote/@、置顶权限提示或未读展示语义。

**根因定位**
- `ChatView.onAppear` 同时触发消息强制同步、已读、群详情、置顶消息和 12 秒轮询兜底;群详情路径原先串行执行 `groupDetail -> listGroupMembers -> listGroupAnnouncements -> listGroupFiles -> listGroupJoinRequests`,大群成员/文件/审批数据会和首屏消息区竞争同一时段的网络与主线程模型合并。
- 首屏强制消息同步、置顶消息刷新和公告详情加载没有同会话 in-flight 去重;快速切群、前后台切换或 SwiftUI 重复 `onAppear` 时容易重复发同类请求。
- 历史向上分页已有 `conversationHistoryLoadingIDs` 和 0.85s 节流,不是本轮首屏卡顿主因。

**本轮完成**
- `ChatView` 进入群聊和前台恢复时调用轻量群资料模式:只同步群基础详情和当前公告,不在首屏立即拉全量成员、群文件和审批请求。
- `AppState` 新增首屏消息同步、群资料包、置顶消息、公告详情和群文件的 in-flight 去重;同一账号/企业/会话的重复请求在前一个完成前直接复用等待状态,避免重复挤占首屏。
- 轻量群资料刷新期间若用户马上打开群详情,会记录完整刷新待办;轻量刷新结束后自动补跑完整群资料,保证成员、文件和审批数据不丢。
- 切账号/切企业/退出登录时清空新增的 in-flight 状态,避免旧账号任务残留影响新会话。
- `ChatView` 增加首帧/可见历史/非关键数据耗时日志,`AppState` 增加最近窗口历史同步耗时日志;日志只包含耗时、会话类型和数量,不包含用户 id、会话 id、URL、token 或消息正文。
- 12 秒兜底轮询增加当前会话历史同步在途判断;若首屏或静默补刷尚未完成,本轮轮询跳过,避免断线/弱网时重复 `/api/im/sync` 抢占首屏。

**首屏策略**
- 首屏优先展示导航栏、已有最近消息/历史 loading、输入框和当前公告;置顶条仍可刷新,但同类请求去重。
- 群成员、群文件和审批请求延后到群详情或显式入口完整刷新,不阻塞聊天页出现和消息列表滚动。

**验证与剩余风险**
- Debug Simulator 构建通过;本轮用代码路径验证请求去重和行为等价,未接入真机 Instruments。
- Swift parse 通过;后续可通过 `[JHT Perf] chat_first_frame_ms/chat_history_ready_ms/chat_side_data_ready_ms` 与 Instruments 对齐首帧、历史窗口和非关键数据耗时。
- 建议 UAT 覆盖:冷启动进入普通群、有公告/置顶群、快速切换两个群、私聊切群聊、群详情立即打开、弱网下重复前后台切换。
- 仍需在真实 500+ 成员/大量附件群上补 Animation Hitches / Time Profiler 量化,确认主线程无 >250ms 长任务。

### 2026-06-22 / 主界面首屏可交互阻塞收口

本轮针对“进入主界面后会话列表已显示但十几秒无法操作”做源码级排查和低风险修复。范围只覆盖主界面首屏可交互、会话列表派生缓存、登录/入企后的附属同步调度,不改变登录企业选择、聊天消息、附件、公告、RTC 或通知业务语义。

**根因定位**
- `syncPrimaryConversationData` 已做到会话列表到达即放行,但列表出现后立即启动历史预取、二级快照、群 bundle、文件/联系人/通知和 WS recovery。多条任务回写 `conversations/groups/files/inbox` 后会触发 SwiftUI 列表重绘。
- `ConversationListView` 对 `state.conversations` 的每次变化都会同步重建普通会话分段、`@我` 记录和未读聚合缓存;历史预取逐会话 `applyRemoteMessages` 时会放大为多次全列表扫描。
- 首轮群 bundle 原先会预热最多 8 个群并拉成员、群文件和审批等非首屏必需数据,容易与会话列表首屏交互争抢 MainActor 和网络。

**本轮完成**
- `MainShellView` 接入 `[JHT Perf] main_shell_bootstrap_start/main_shell_appeared_ms/main_shell_interactive_ms` 打点,用于区分主界面出现、可交互和后续预热耗时。
- 会话列表 `state.conversations` 变化后的派生缓存重建改为 140ms debounce,合并历史预取/WS 回包期间的连续刷新,搜索词、筛选和当前用户变化仍即时重算;`@我` 明细记录仅在 `@我` 筛选可见时重建,避免首屏隐藏列表扫描。
- 历史预取延后 3.0s 启动,最多预取 6 个会话,并发上限从 6 降到 2;历史失败继续只记录日志,不把首页打回失败态。
- 二级快照延后 2.2s 启动;文件配置、企业资料、群、联系人、通知、文件列表和设备登记均不阻塞首屏点击。
- 首轮群 bundle 延后 4.5s,最多预热 2 个群,且只拉轻量群详情/当前公告,成员、群文件和审批仍等群详情或显式入口完整刷新。

**验收建议**
- 冷启动/登录后进入主界面:观察日志 `main_shell_appeared_ms` 与 `main_shell_interactive_ms`,列表出现后底部 Tab、搜索、企业切换入口应能立即响应。
- 弱网或后端二级接口慢:首页不显示全屏锁定,慢任务只影响对应局部数据;失败路径保留 endpoint 日志和局部错误/重试。
- 真实 UAT 仍需大账号样本补 Instruments Animation Hitches / Time Profiler,确认列表出现后无连续主线程长任务。
