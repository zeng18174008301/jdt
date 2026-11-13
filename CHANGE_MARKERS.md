# IOS1 当前导入基线

- 来源：`jdt (2).zip`（2026-11-09）。压缩包 SHA-256：`fb5b444b62852ff1dde7a66f133e6e7b8fd67ef44ba8a474370ea302b92a00a0`。
- 导入前主线：`f424fccf770ab472115e1fd60290a125dc1c7237`。当前 iOS1 源码按该包替换，旧包独有源码不回灌。
- 包内 `SHA256SUMS.txt` 属于旧基线。导入文件重新计算哈希，压缩包原标识保留在下方。
- 核对范围包括 App1 工程、业务代码、资源、测试和现有脚本。外部 CI/签名文件仍保留在原压缩包。

<!-- WDT_IOS1_SOURCE_FILENAMES_20261113_BEGIN -->

## iOS1 生产源码文件重命名（2026-11-13）

生产 Swift 源码按与 jdt 重复的文件名改名，共 113 个文件。App 目录 101 个，IM4Core 1 个，IM4Data 6 个，IM4Stores 5 个。
文件保留原目录、类型名和源码内容。Xcode 文件引用保留原 ID。Package.swift 和三个源码检查脚本同步使用新路径。测试目录按要求保留原样，其中直接读取旧源码路径的测试需要另行适配。

验证通过 Xcode 文件路径、六个 Package target 的路径、Swift 语法及 113 个文件的内容校验。Release 模拟器编译停在 WebRTC 依赖解析，本机缓存缺少该框架二进制。

| 原路径 | 新路径 |
| --- | --- |
| `BlueStoneIM/AccessDiagnostics.swift` | `BlueStoneIM/IOS1AccessDiagnostics.swift` |
| `BlueStoneIM/AccessDiscovery.swift` | `BlueStoneIM/IOS1AccessDiscovery.swift` |
| `BlueStoneIM/AppState.swift` | `BlueStoneIM/IOS1AppState.swift` |
| `BlueStoneIM/AuthViews.swift` | `BlueStoneIM/IOS1AuthViews.swift` |
| `BlueStoneIM/AvatarRealtimeProjection.swift` | `BlueStoneIM/IOS1AvatarRealtimeProjection.swift` |
| `BlueStoneIM/BatchForwardState.swift` | `BlueStoneIM/IOS1BatchForwardState.swift` |
| `BlueStoneIM/BlueStoneIMApp.swift` | `BlueStoneIM/IOS1BlueStoneIMApp.swift` |
| `BlueStoneIM/CachedRemoteSnapshot.swift` | `BlueStoneIM/IOS1CachedRemoteSnapshot.swift` |
| `BlueStoneIM/CallLifecycle.swift` | `BlueStoneIM/IOS1CallLifecycle.swift` |
| `BlueStoneIM/CallStore.swift` | `BlueStoneIM/IOS1CallStore.swift` |
| `BlueStoneIM/CertificationPresentation.swift` | `BlueStoneIM/IOS1CertificationPresentation.swift` |
| `BlueStoneIM/ChatViews.swift` | `BlueStoneIM/IOS1ChatViews.swift` |
| `BlueStoneIM/ContactStore.swift` | `BlueStoneIM/IOS1ContactStore.swift` |
| `BlueStoneIM/ContactsViews.swift` | `BlueStoneIM/IOS1ContactsViews.swift` |
| `BlueStoneIM/ConversationStore.swift` | `BlueStoneIM/IOS1ConversationStore.swift` |
| `BlueStoneIM/ConversationViews.swift` | `BlueStoneIM/IOS1ConversationViews.swift` |
| `BlueStoneIM/Core/AppSupport/AccountSession/AppState+AuthenticationProfileWorkspace.swift` | `BlueStoneIM/Core/AppSupport/AccountSession/IOS1AppState+AuthenticationProfileWorkspace.swift` |
| `BlueStoneIM/Core/AppSupport/AppState+ContactsInboxDevices.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppState+ContactsInboxDevices.swift` |
| `BlueStoneIM/Core/AppSupport/AppState+ConversationsHistory.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppState+ConversationsHistory.swift` |
| `BlueStoneIM/Core/AppSupport/AppState+FilesAttachments.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppState+FilesAttachments.swift` |
| `BlueStoneIM/Core/AppSupport/AppState+GroupAdministration.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppState+GroupAdministration.swift` |
| `BlueStoneIM/Core/AppSupport/AppState+GroupsAnnouncements.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppState+GroupsAnnouncements.swift` |
| `BlueStoneIM/Core/AppSupport/AppState+MessageActions.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppState+MessageActions.swift` |
| `BlueStoneIM/Core/AppSupport/AppState+MessageSendingAttachments.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppState+MessageSendingAttachments.swift` |
| `BlueStoneIM/Core/AppSupport/AppState+Realtime.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppState+Realtime.swift` |
| `BlueStoneIM/Core/AppSupport/AppState+RemoteErrorHandling.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppState+RemoteErrorHandling.swift` |
| `BlueStoneIM/Core/AppSupport/AppState+SearchConversationSettings.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppState+SearchConversationSettings.swift` |
| `BlueStoneIM/Core/AppSupport/AppState+StickerLibrary.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppState+StickerLibrary.swift` |
| `BlueStoneIM/Core/AppSupport/AppStateDiagnosticsSupport.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppStateDiagnosticsSupport.swift` |
| `BlueStoneIM/Core/AppSupport/AppStateLocalSupport.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppStateLocalSupport.swift` |
| `BlueStoneIM/Core/AppSupport/AppStatePolicies.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppStatePolicies.swift` |
| `BlueStoneIM/Core/AppSupport/AppStatePolicySupport.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppStatePolicySupport.swift` |
| `BlueStoneIM/Core/AppSupport/AppStateRTCSupport.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppStateRTCSupport.swift` |
| `BlueStoneIM/Core/AppSupport/AppStateSlideCaptchaSupport.swift` | `BlueStoneIM/Core/AppSupport/IOS1AppStateSlideCaptchaSupport.swift` |
| `BlueStoneIM/Core/AppSupport/Calls/AppState+VoiceCalls.swift` | `BlueStoneIM/Core/AppSupport/Calls/IOS1AppState+VoiceCalls.swift` |
| `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift` | `BlueStoneIM/Core/AppSupport/DebugFixtures/IOS1AppState+DebugScreenshotFixtures.swift` |
| `BlueStoneIM/Core/AppSupport/GroupFileMapping/AppState+RemoteGroupFileMapping.swift` | `BlueStoneIM/Core/AppSupport/GroupFileMapping/IOS1AppState+RemoteGroupFileMapping.swift` |
| `BlueStoneIM/Core/AppSupport/InteractionPolicy/AppInteractionPolicy.swift` | `BlueStoneIM/Core/AppSupport/InteractionPolicy/IOS1AppInteractionPolicy.swift` |
| `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift` | `BlueStoneIM/Core/AppSupport/MessageMapping/IOS1AppState+GroupSystemMessagePresentation.swift` |
| `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+IdentityPresentation.swift` | `BlueStoneIM/Core/AppSupport/MessageMapping/IOS1AppState+IdentityPresentation.swift` |
| `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift` | `BlueStoneIM/Core/AppSupport/MessageMapping/IOS1AppState+RemoteMessagePayloadMapping.swift` |
| `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+RemoteMessageStateMapping.swift` | `BlueStoneIM/Core/AppSupport/MessageMapping/IOS1AppState+RemoteMessageStateMapping.swift` |
| `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteRegistrationSnapshotSync.swift` | `BlueStoneIM/Core/AppSupport/RemoteSync/IOS1AppState+RemoteRegistrationSnapshotSync.swift` |
| `BlueStoneIM/Core/AppSupport/TenantSession/AppState+TenantSwitchingRemoteMapping.swift` | `BlueStoneIM/Core/AppSupport/TenantSession/IOS1AppState+TenantSwitchingRemoteMapping.swift` |
| `BlueStoneIM/Core/NetworkSupport/NetworkSupportTypes.swift` | `BlueStoneIM/Core/NetworkSupport/IOS1NetworkSupportTypes.swift` |
| `BlueStoneIM/Core/Networking/IMAPIClient+Account.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Account.swift` |
| `BlueStoneIM/Core/Networking/IMAPIClient+Auth.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Auth.swift` |
| `BlueStoneIM/Core/Networking/IMAPIClient+Bootstrap.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Bootstrap.swift` |
| `BlueStoneIM/Core/Networking/IMAPIClient+Contacts.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Contacts.swift` |
| `BlueStoneIM/Core/Networking/IMAPIClient+Files.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Files.swift` |
| `BlueStoneIM/Core/Networking/IMAPIClient+Groups.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Groups.swift` |
| `BlueStoneIM/Core/Networking/IMAPIClient+Messages.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Messages.swift` |
| `BlueStoneIM/Core/Networking/IMAPIClient+RTC.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIClient+RTC.swift` |
| `BlueStoneIM/Core/Networking/IMAPIClient+Stickers.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Stickers.swift` |
| `BlueStoneIM/Core/Networking/IMAPIClient+Workspaces.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Workspaces.swift` |
| `BlueStoneIM/Core/Networking/IMAPIClient.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIClient.swift` |
| `BlueStoneIM/Core/Networking/IMAPIErrorSupport.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIErrorSupport.swift` |
| `BlueStoneIM/Core/Networking/IMAppBootstrapSupport.swift` | `BlueStoneIM/Core/Networking/IOS1IMAppBootstrapSupport.swift` |
| `BlueStoneIM/Core/Storage/IMAPIContext.swift` | `BlueStoneIM/Core/Storage/IOS1IMAPIContext.swift` |
| `BlueStoneIM/Core/Storage/IMProtectedSessionStore.swift` | `BlueStoneIM/Core/Storage/IOS1IMProtectedSessionStore.swift` |
| `BlueStoneIM/DesignSystem.swift` | `BlueStoneIM/IOS1DesignSystem.swift` |
| `BlueStoneIM/DeviceRevocationDetector.swift` | `BlueStoneIM/IOS1DeviceRevocationDetector.swift` |
| `BlueStoneIM/EmojiPickerCore.swift` | `BlueStoneIM/IOS1EmojiPickerCore.swift` |
| `BlueStoneIM/EmojiPickerPreferences.swift` | `BlueStoneIM/IOS1EmojiPickerPreferences.swift` |
| `BlueStoneIM/EmojiPickerStoreAdapter.swift` | `BlueStoneIM/IOS1EmojiPickerStoreAdapter.swift` |
| `BlueStoneIM/EmojiPickerView.swift` | `BlueStoneIM/IOS1EmojiPickerView.swift` |
| `BlueStoneIM/FileStore.swift` | `BlueStoneIM/IOS1FileStore.swift` |
| `BlueStoneIM/FilesRTCViews.swift` | `BlueStoneIM/IOS1FilesRTCViews.swift` |
| `BlueStoneIM/GroupDetails/GroupDetailMembers.swift` | `BlueStoneIM/GroupDetails/IOS1GroupDetailMembers.swift` |
| `BlueStoneIM/GroupMuteMode.swift` | `BlueStoneIM/IOS1GroupMuteMode.swift` |
| `BlueStoneIM/HTTPTransport.swift` | `BlueStoneIM/IOS1HTTPTransport.swift` |
| `BlueStoneIM/IMAPIProtocol.swift` | `BlueStoneIM/IOS1IMAPIProtocol.swift` |
| `BlueStoneIM/IOSRiskTelemetry.swift` | `BlueStoneIM/IOS1IOSRiskTelemetry.swift` |
| `BlueStoneIM/IdentityPresentation.swift` | `BlueStoneIM/IOS1IdentityPresentation.swift` |
| `BlueStoneIM/LegacySnapshotImporter.swift` | `BlueStoneIM/IOS1LegacySnapshotImporter.swift` |
| `BlueStoneIM/MeSettingsViews.swift` | `BlueStoneIM/IOS1MeSettingsViews.swift` |
| `BlueStoneIM/MediaPipeline.swift` | `BlueStoneIM/IOS1MediaPipeline.swift` |
| `BlueStoneIM/MessagePersistenceCoordinator.swift` | `BlueStoneIM/IOS1MessagePersistenceCoordinator.swift` |
| `BlueStoneIM/MockData.swift` | `BlueStoneIM/IOS1MockData.swift` |
| `BlueStoneIM/Models.swift` | `BlueStoneIM/IOS1Models.swift` |
| `BlueStoneIM/PreloginBootstrap.swift` | `BlueStoneIM/IOS1PreloginBootstrap.swift` |
| `BlueStoneIM/PreloginBootstrapResolver.swift` | `BlueStoneIM/IOS1PreloginBootstrapResolver.swift` |
| `BlueStoneIM/PreloginBootstrapStartup.swift` | `BlueStoneIM/IOS1PreloginBootstrapStartup.swift` |
| `BlueStoneIM/PresenceConnectivityProjection.swift` | `BlueStoneIM/IOS1PresenceConnectivityProjection.swift` |
| `BlueStoneIM/RTCCallRecordCard.swift` | `BlueStoneIM/IOS1RTCCallRecordCard.swift` |
| `BlueStoneIM/RTCCallRecordMessage.swift` | `BlueStoneIM/IOS1RTCCallRecordMessage.swift` |
| `BlueStoneIM/RTCCallRecordRedial.swift` | `BlueStoneIM/IOS1RTCCallRecordRedial.swift` |
| `BlueStoneIM/RealtimeClient.swift` | `BlueStoneIM/IOS1RealtimeClient.swift` |
| `BlueStoneIM/RealtimeQUICTransport.swift` | `BlueStoneIM/IOS1RealtimeQUICTransport.swift` |
| `BlueStoneIM/RealtimeTransport.swift` | `BlueStoneIM/IOS1RealtimeTransport.swift` |
| `BlueStoneIM/RegistrationFlowPolicy.swift` | `BlueStoneIM/IOS1RegistrationFlowPolicy.swift` |
| `BlueStoneIM/RemoteAPIModels.swift` | `BlueStoneIM/IOS1RemoteAPIModels.swift` |
| `BlueStoneIM/ScopedResponseFence.swift` | `BlueStoneIM/IOS1ScopedResponseFence.swift` |
| `BlueStoneIM/SnapshotCache.swift` | `BlueStoneIM/IOS1SnapshotCache.swift` |
| `BlueStoneIM/StickerGIFRenderer.swift` | `BlueStoneIM/IOS1StickerGIFRenderer.swift` |
| `BlueStoneIM/StickerStore.swift` | `BlueStoneIM/IOS1StickerStore.swift` |
| `BlueStoneIM/SyncEngine.swift` | `BlueStoneIM/IOS1SyncEngine.swift` |
| `BlueStoneIM/VideoCallViews.swift` | `BlueStoneIM/IOS1VideoCallViews.swift` |
| `BlueStoneIM/VideoMediaClient.swift` | `BlueStoneIM/IOS1VideoMediaClient.swift` |
| `BlueStoneIM/VoiceMediaClient.swift` | `BlueStoneIM/IOS1VoiceMediaClient.swift` |
| `BlueStoneIM/WireCodec.swift` | `BlueStoneIM/IOS1WireCodec.swift` |
| `Sources/IM4Core/HTTPTransport.swift` | `Sources/IM4Core/IOS1CoreHTTPTransport.swift` |
| `Sources/IM4Data/AttachmentTransferRepository.swift` | `Sources/IM4Data/IOS1DataAttachmentTransferRepository.swift` |
| `Sources/IM4Data/LocalMessageRepository.swift` | `Sources/IM4Data/IOS1DataLocalMessageRepository.swift` |
| `Sources/IM4Data/MessageDatabaseMigrations.swift` | `Sources/IM4Data/IOS1DataMessageDatabaseMigrations.swift` |
| `Sources/IM4Data/MessageDatabasePaths.swift` | `Sources/IM4Data/IOS1DataMessageDatabasePaths.swift` |
| `Sources/IM4Data/MessageDatabaseSchema.swift` | `Sources/IM4Data/IOS1DataMessageDatabaseSchema.swift` |
| `Sources/IM4Data/SQLiteMessageRepository.swift` | `Sources/IM4Data/IOS1DataSQLiteMessageRepository.swift` |
| `Sources/IM4Stores/CallStore.swift` | `Sources/IM4Stores/IOS1StoresCallStore.swift` |
| `Sources/IM4Stores/ContactStore.swift` | `Sources/IM4Stores/IOS1StoresContactStore.swift` |
| `Sources/IM4Stores/ConversationStore.swift` | `Sources/IM4Stores/IOS1StoresConversationStore.swift` |
| `Sources/IM4Stores/FileStore.swift` | `Sources/IM4Stores/IOS1StoresFileStore.swift` |
| `Sources/IM4Stores/StickerStore.swift` | `Sources/IM4Stores/IOS1StoresStickerStore.swift` |

<!-- WDT_IOS1_SOURCE_FILENAMES_20261113_END -->

<!-- WDT_IOS1_XCODE_GROUP_PATHS_20261113_BEGIN -->

## iOS1 工程侧栏文件分组（2026-11-13）

`BlueStoneIM.xcodeproj/project.pbxproj` 将 30 个生产源码的工程根目录引用改为组内相对引用。`BlueStoneIM/App` 下 44 个已有源码引用归入 App 组。验证改动前后的文件引用 ID、解析后的磁盘路径、编译阶段和目标配置一致。回退时按 App 组 ID `E388BD8543CA450C91FC5EBD` 和该工程文件的差分还原。

<!-- WDT_IOS1_XCODE_GROUP_PATHS_20261113_END -->

<!-- WDT_IOS1_XCODE_GROUP_PATHS_20261113_02_BEGIN -->

## iOS1 工程侧栏跨目录文件引用（2026-11-13）

`BlueStoneIM.xcodeproj/project.pbxproj` 将生产目录中的 113 个跨目录文件引用归到实际父目录对应的 Xcode 组，补齐 15 个目录组。验证全部文件引用解析出的磁盘路径、文件 ID 和编译阶段一致。回退时还原本批工程文件的分组及路径差分。

<!-- WDT_IOS1_XCODE_GROUP_PATHS_20261113_02_END -->

<!-- WDT_IOS1_SOURCE_FOLDERS_20261113_BEGIN -->

## iOS1 主工程源码目录整理（2026-11-13）

将根目录的 Swift 源码按 App、领域、存储、网络、媒体及各业务页面分组。原 DesignSystem 和 Features 目录分别改名为 IOS1DesignSystem 和 IOS1Features。Xcode 文件引用、Package.swift 和源码检查脚本同步更新。源码内容与原文件逐字节一致，工程引用 ID 和编译阶段一致。 SwiftPM 清单可解析，全部源文件和排除路径有效。测试目录保留原样，引用旧文件路径的源码检查测试需要跟随迁移。回退时按下表逆向移动文件并还原工程、Package 和脚本的路径差分。

| 原路径 | 新路径 |
| --- | --- |
| `BlueStoneIM/AccessDebugOverlay.swift` | `BlueStoneIM/Core/AppSupport/Diagnostics/AccessDebugOverlay.swift` |
| `BlueStoneIM/AccessDebugOverlayLayout.swift` | `BlueStoneIM/Core/AppSupport/Diagnostics/AccessDebugOverlayLayout.swift` |
| `BlueStoneIM/AccessDiagnosticsSnapshot.swift` | `BlueStoneIM/Core/AppSupport/Diagnostics/AccessDiagnosticsSnapshot.swift` |
| `BlueStoneIM/AccessDiscoveryEndpoint.swift` | `BlueStoneIM/Core/Networking/Access/AccessDiscoveryEndpoint.swift` |
| `BlueStoneIM/AccessDiscoveryModels.swift` | `BlueStoneIM/Core/Networking/Access/AccessDiscoveryModels.swift` |
| `BlueStoneIM/AccessDiscoveryStore.swift` | `BlueStoneIM/Core/Networking/Access/AccessDiscoveryStore.swift` |
| `BlueStoneIM/AccessDiscoveryTrust.swift` | `BlueStoneIM/Core/Networking/Access/AccessDiscoveryTrust.swift` |
| `BlueStoneIM/ApplicationOverlayViews.swift` | `BlueStoneIM/App/ApplicationOverlayViews.swift` |
| `BlueStoneIM/ApplicationPolicyScreens.swift` | `BlueStoneIM/App/ApplicationPolicyScreens.swift` |
| `BlueStoneIM/AvatarRealtimeSurfaceProjector.swift` | `BlueStoneIM/Core/AppSupport/Media/AvatarRealtimeSurfaceProjector.swift` |
| `BlueStoneIM/CallKitVoiceCallIntegration.swift` | `BlueStoneIM/Core/AppSupport/Calls/CallKitVoiceCallIntegration.swift` |
| `BlueStoneIM/CertificationProfileBroker.swift` | `BlueStoneIM/Core/AppSupport/Media/CertificationProfileBroker.swift` |
| `BlueStoneIM/DataAppAdapters.swift` | `BlueStoneIM/Core/Storage/DataAppAdapters.swift` |
| `BlueStoneIM/DataModuleBridge.swift` | `BlueStoneIM/Core/Storage/DataModuleBridge.swift` |
| `BlueStoneIM/DesignSystem/ApprovalPresentationViews.swift` | `BlueStoneIM/IOS1DesignSystem/ApprovalPresentationViews.swift` |
| `BlueStoneIM/DesignSystem/AuthBackgroundViews.swift` | `BlueStoneIM/IOS1DesignSystem/AuthBackgroundViews.swift` |
| `BlueStoneIM/DesignSystem/AvatarImagePipeline.swift` | `BlueStoneIM/IOS1DesignSystem/AvatarImagePipeline.swift` |
| `BlueStoneIM/DesignSystem/AvatarPresentationViews.swift` | `BlueStoneIM/IOS1DesignSystem/AvatarPresentationViews.swift` |
| `BlueStoneIM/DesignSystem/AvatarViews.swift` | `BlueStoneIM/IOS1DesignSystem/AvatarViews.swift` |
| `BlueStoneIM/DesignSystem/CommonControlViews.swift` | `BlueStoneIM/IOS1DesignSystem/CommonControlViews.swift` |
| `BlueStoneIM/DesignSystem/DesignSystemModuleExports.swift` | `BlueStoneIM/IOS1DesignSystem/DesignSystemModuleExports.swift` |
| `BlueStoneIM/DesignSystem/GroupInviteApprovalCard.swift` | `BlueStoneIM/IOS1DesignSystem/GroupInviteApprovalCard.swift` |
| `BlueStoneIM/DesignSystem/NavigationGestureInstallers.swift` | `BlueStoneIM/IOS1DesignSystem/NavigationGestureInstallers.swift` |
| `BlueStoneIM/DesignSystem/PhotoLibraryPickerCompat.swift` | `BlueStoneIM/IOS1DesignSystem/PhotoLibraryPickerCompat.swift` |
| `BlueStoneIM/DesignSystem/PhotoLibraryPresentation.swift` | `BlueStoneIM/IOS1DesignSystem/PhotoLibraryPresentation.swift` |
| `BlueStoneIM/DesignSystem/SheetHeader.swift` | `BlueStoneIM/IOS1DesignSystem/SheetHeader.swift` |
| `BlueStoneIM/DesignSystem/SwiftUICompatibility.swift` | `BlueStoneIM/IOS1DesignSystem/SwiftUICompatibility.swift` |
| `BlueStoneIM/DesignSystemModuleBridge.swift` | `BlueStoneIM/IOS1DesignSystem/DesignSystemModuleBridge.swift` |
| `BlueStoneIM/DomainAppAdapters.swift` | `BlueStoneIM/Domain/DomainAppAdapters.swift` |
| `BlueStoneIM/DomainModuleBridge.swift` | `BlueStoneIM/Domain/DomainModuleBridge.swift` |
| `BlueStoneIM/Features/Auth/AuthCaptchaViews.swift` | `BlueStoneIM/IOS1Features/Auth/AuthCaptchaViews.swift` |
| `BlueStoneIM/Features/Auth/AuthFlipView.swift` | `BlueStoneIM/IOS1Features/Auth/AuthFlipView.swift` |
| `BlueStoneIM/Features/Auth/AuthFormControls.swift` | `BlueStoneIM/IOS1Features/Auth/AuthFormControls.swift` |
| `BlueStoneIM/Features/Auth/AuthLegalViews.swift` | `BlueStoneIM/IOS1Features/Auth/AuthLegalViews.swift` |
| `BlueStoneIM/Features/Auth/AuthWorkspaceViews.swift` | `BlueStoneIM/IOS1Features/Auth/AuthWorkspaceViews.swift` |
| `BlueStoneIM/Features/Auth/ForgotPasswordView.swift` | `BlueStoneIM/IOS1Features/Auth/ForgotPasswordView.swift` |
| `BlueStoneIM/Features/Auth/LoginRegisterViews.swift` | `BlueStoneIM/IOS1Features/Auth/LoginRegisterViews.swift` |
| `BlueStoneIM/Features/Auth/RememberedLoginCredentials.swift` | `BlueStoneIM/IOS1Features/Auth/RememberedLoginCredentials.swift` |
| `BlueStoneIM/Features/Calls/CallScreenViews.swift` | `BlueStoneIM/IOS1Features/Calls/CallScreenViews.swift` |
| `BlueStoneIM/Features/Calls/RTCCallRecordRow.swift` | `BlueStoneIM/IOS1Features/Calls/RTCCallRecordRow.swift` |
| `BlueStoneIM/Features/Chat/ChatAttachmentDetail.swift` | `BlueStoneIM/IOS1Features/Chat/ChatAttachmentDetail.swift` |
| `BlueStoneIM/Features/Chat/ChatAttachmentPreview.swift` | `BlueStoneIM/IOS1Features/Chat/ChatAttachmentPreview.swift` |
| `BlueStoneIM/Features/Contacts/ContactAvatarPreview.swift` | `BlueStoneIM/IOS1Features/Contacts/ContactAvatarPreview.swift` |
| `BlueStoneIM/Features/Contacts/ContactCommonRows.swift` | `BlueStoneIM/IOS1Features/Contacts/ContactCommonRows.swift` |
| `BlueStoneIM/Features/Contacts/ContactDirectoryTable.swift` | `BlueStoneIM/IOS1Features/Contacts/ContactDirectoryTable.swift` |
| `BlueStoneIM/Features/Contacts/ContactGroupDetail.swift` | `BlueStoneIM/IOS1Features/Contacts/ContactGroupDetail.swift` |
| `BlueStoneIM/Features/Contacts/ContactGroupList.swift` | `BlueStoneIM/IOS1Features/Contacts/ContactGroupList.swift` |
| `BlueStoneIM/Features/Contacts/ContactRelationshipViews.swift` | `BlueStoneIM/IOS1Features/Contacts/ContactRelationshipViews.swift` |
| `BlueStoneIM/Features/Contacts/ContactSearchViews.swift` | `BlueStoneIM/IOS1Features/Contacts/ContactSearchViews.swift` |
| `BlueStoneIM/Features/Contacts/ContactUserProfile.swift` | `BlueStoneIM/IOS1Features/Contacts/ContactUserProfile.swift` |
| `BlueStoneIM/Features/Contacts/DepartmentManagementSheets.swift` | `BlueStoneIM/IOS1Features/Contacts/DepartmentManagementSheets.swift` |
| `BlueStoneIM/Features/Contacts/GroupHistoryScreenshots.swift` | `BlueStoneIM/IOS1Features/Contacts/GroupHistoryScreenshots.swift` |
| `BlueStoneIM/Features/Contacts/GroupMemberManagementViews.swift` | `BlueStoneIM/IOS1Features/Contacts/GroupMemberManagementViews.swift` |
| `BlueStoneIM/Features/Contacts/GroupModerationSettingsViews.swift` | `BlueStoneIM/IOS1Features/Contacts/GroupModerationSettingsViews.swift` |
| `BlueStoneIM/Features/Contacts/GroupMuteListViews.swift` | `BlueStoneIM/IOS1Features/Contacts/GroupMuteListViews.swift` |
| `BlueStoneIM/Features/Contacts/GroupProfileEditSheets.swift` | `BlueStoneIM/IOS1Features/Contacts/GroupProfileEditSheets.swift` |
| `BlueStoneIM/Features/Contacts/GroupSettingsAndLifecycleSheets.swift` | `BlueStoneIM/IOS1Features/Contacts/GroupSettingsAndLifecycleSheets.swift` |
| `BlueStoneIM/Features/Contacts/GroupSharingViews.swift` | `BlueStoneIM/IOS1Features/Contacts/GroupSharingViews.swift` |
| `BlueStoneIM/Features/Contacts/OrganizationDirectoryViews.swift` | `BlueStoneIM/IOS1Features/Contacts/OrganizationDirectoryViews.swift` |
| `BlueStoneIM/Features/Conversations/ConversationListHeaderViews.swift` | `BlueStoneIM/IOS1Features/Conversations/ConversationListHeaderViews.swift` |
| `BlueStoneIM/Features/Conversations/ConversationListMentions.swift` | `BlueStoneIM/IOS1Features/Conversations/ConversationListMentions.swift` |
| `BlueStoneIM/Features/Conversations/ConversationListProjection.swift` | `BlueStoneIM/IOS1Features/Conversations/ConversationListProjection.swift` |
| `BlueStoneIM/Features/Conversations/ConversationListRenderCache.swift` | `BlueStoneIM/IOS1Features/Conversations/ConversationListRenderCache.swift` |
| `BlueStoneIM/Features/Conversations/ConversationListRows.swift` | `BlueStoneIM/IOS1Features/Conversations/ConversationListRows.swift` |
| `BlueStoneIM/Features/Conversations/ConversationListSearch.swift` | `BlueStoneIM/IOS1Features/Conversations/ConversationListSearch.swift` |
| `BlueStoneIM/Features/Conversations/ConversationListTime.swift` | `BlueStoneIM/IOS1Features/Conversations/ConversationListTime.swift` |
| `BlueStoneIM/Features/Conversations/FindUserSheet.swift` | `BlueStoneIM/IOS1Features/Conversations/FindUserSheet.swift` |
| `BlueStoneIM/Features/Conversations/QuickAddViews.swift` | `BlueStoneIM/IOS1Features/Conversations/QuickAddViews.swift` |
| `BlueStoneIM/Features/Conversations/RecycledConversationTable.swift` | `BlueStoneIM/IOS1Features/Conversations/RecycledConversationTable.swift` |
| `BlueStoneIM/Features/Conversations/TenantGlobalSearchResults.swift` | `BlueStoneIM/IOS1Features/Conversations/TenantGlobalSearchResults.swift` |
| `BlueStoneIM/Features/Files/FileListSupportViews.swift` | `BlueStoneIM/IOS1Features/Files/FileListSupportViews.swift` |
| `BlueStoneIM/Features/Files/FilePreviewViews.swift` | `BlueStoneIM/IOS1Features/Files/FilePreviewViews.swift` |
| `BlueStoneIM/Features/Files/FileVisualPresentation.swift` | `BlueStoneIM/IOS1Features/Files/FileVisualPresentation.swift` |
| `BlueStoneIM/Features/Files/FilesPreviewCacheAdapter.swift` | `BlueStoneIM/IOS1Features/Files/FilesPreviewCacheAdapter.swift` |
| `BlueStoneIM/Features/Files/FilesView.swift` | `BlueStoneIM/IOS1Features/Files/FilesView.swift` |
| `BlueStoneIM/Features/Files/QuickLookAndFileShareViews.swift` | `BlueStoneIM/IOS1Features/Files/QuickLookAndFileShareViews.swift` |
| `BlueStoneIM/Features/Files/SystemPreviewLoader.swift` | `BlueStoneIM/IOS1Features/Files/SystemPreviewLoader.swift` |
| `BlueStoneIM/Features/Me/AccountInfoViews.swift` | `BlueStoneIM/IOS1Features/Me/AccountInfoViews.swift` |
| `BlueStoneIM/Features/Me/DeviceSessionsView.swift` | `BlueStoneIM/IOS1Features/Me/DeviceSessionsView.swift` |
| `BlueStoneIM/Features/Me/EnterpriseSwitcherView.swift` | `BlueStoneIM/IOS1Features/Me/EnterpriseSwitcherView.swift` |
| `BlueStoneIM/Features/Me/InboxCenterViews.swift` | `BlueStoneIM/IOS1Features/Me/InboxCenterViews.swift` |
| `BlueStoneIM/Features/Me/NotificationSettingsView.swift` | `BlueStoneIM/IOS1Features/Me/NotificationSettingsView.swift` |
| `BlueStoneIM/Features/Me/PhoneBindingFlowView.swift` | `BlueStoneIM/IOS1Features/Me/PhoneBindingFlowView.swift` |
| `BlueStoneIM/Features/Me/ProfileEditViews.swift` | `BlueStoneIM/IOS1Features/Me/ProfileEditViews.swift` |
| `BlueStoneIM/Features/Me/RealNameVerificationViews.swift` | `BlueStoneIM/IOS1Features/Me/RealNameVerificationViews.swift` |
| `BlueStoneIM/Features/Me/SecuritySettingsViews.swift` | `BlueStoneIM/IOS1Features/Me/SecuritySettingsViews.swift` |
| `BlueStoneIM/IOS1AccessDiagnostics.swift` | `BlueStoneIM/Core/AppSupport/Diagnostics/IOS1AccessDiagnostics.swift` |
| `BlueStoneIM/IOS1AccessDiscovery.swift` | `BlueStoneIM/Core/Networking/Access/IOS1AccessDiscovery.swift` |
| `BlueStoneIM/IOS1AppState.swift` | `BlueStoneIM/App/IOS1AppState.swift` |
| `BlueStoneIM/IOS1AuthViews.swift` | `BlueStoneIM/IOS1Features/Auth/IOS1AuthViews.swift` |
| `BlueStoneIM/IOS1AvatarRealtimeProjection.swift` | `BlueStoneIM/Core/AppSupport/Media/IOS1AvatarRealtimeProjection.swift` |
| `BlueStoneIM/IOS1BatchForwardState.swift` | `BlueStoneIM/IOS1Features/Chat/IOS1BatchForwardState.swift` |
| `BlueStoneIM/IOS1BlueStoneIMApp.swift` | `BlueStoneIM/App/IOS1BlueStoneIMApp.swift` |
| `BlueStoneIM/IOS1CachedRemoteSnapshot.swift` | `BlueStoneIM/Core/Storage/IOS1CachedRemoteSnapshot.swift` |
| `BlueStoneIM/IOS1CallLifecycle.swift` | `BlueStoneIM/Core/AppSupport/Calls/IOS1CallLifecycle.swift` |
| `BlueStoneIM/IOS1CallStore.swift` | `BlueStoneIM/Stores/IOS1CallStore.swift` |
| `BlueStoneIM/IOS1CertificationPresentation.swift` | `BlueStoneIM/Domain/IOS1CertificationPresentation.swift` |
| `BlueStoneIM/IOS1ChatViews.swift` | `BlueStoneIM/IOS1Features/Chat/IOS1ChatViews.swift` |
| `BlueStoneIM/IOS1ContactStore.swift` | `BlueStoneIM/Stores/IOS1ContactStore.swift` |
| `BlueStoneIM/IOS1ContactsViews.swift` | `BlueStoneIM/IOS1Features/Contacts/IOS1ContactsViews.swift` |
| `BlueStoneIM/IOS1ConversationStore.swift` | `BlueStoneIM/Stores/IOS1ConversationStore.swift` |
| `BlueStoneIM/IOS1ConversationViews.swift` | `BlueStoneIM/IOS1Features/Conversations/IOS1ConversationViews.swift` |
| `BlueStoneIM/IOS1DesignSystem.swift` | `BlueStoneIM/IOS1DesignSystem/IOS1DesignSystem.swift` |
| `BlueStoneIM/IOS1DeviceRevocationDetector.swift` | `BlueStoneIM/IOS1Features/Auth/IOS1DeviceRevocationDetector.swift` |
| `BlueStoneIM/IOS1EmojiPickerCore.swift` | `BlueStoneIM/IOS1Features/Chat/IOS1EmojiPickerCore.swift` |
| `BlueStoneIM/IOS1EmojiPickerPreferences.swift` | `BlueStoneIM/IOS1Features/Chat/IOS1EmojiPickerPreferences.swift` |
| `BlueStoneIM/IOS1EmojiPickerStoreAdapter.swift` | `BlueStoneIM/IOS1Features/Chat/IOS1EmojiPickerStoreAdapter.swift` |
| `BlueStoneIM/IOS1EmojiPickerView.swift` | `BlueStoneIM/IOS1Features/Chat/IOS1EmojiPickerView.swift` |
| `BlueStoneIM/IOS1FileStore.swift` | `BlueStoneIM/Stores/IOS1FileStore.swift` |
| `BlueStoneIM/IOS1FilesRTCViews.swift` | `BlueStoneIM/IOS1Features/Files/IOS1FilesRTCViews.swift` |
| `BlueStoneIM/IOS1GroupMuteMode.swift` | `BlueStoneIM/IOS1Features/Contacts/IOS1GroupMuteMode.swift` |
| `BlueStoneIM/IOS1HTTPTransport.swift` | `BlueStoneIM/Core/Networking/IOS1HTTPTransport.swift` |
| `BlueStoneIM/IOS1IMAPIProtocol.swift` | `BlueStoneIM/Core/Networking/IOS1IMAPIProtocol.swift` |
| `BlueStoneIM/IOS1IOSRiskTelemetry.swift` | `BlueStoneIM/Core/AppSupport/Diagnostics/IOS1IOSRiskTelemetry.swift` |
| `BlueStoneIM/IOS1IdentityPresentation.swift` | `BlueStoneIM/Domain/IOS1IdentityPresentation.swift` |
| `BlueStoneIM/IOS1LegacySnapshotImporter.swift` | `BlueStoneIM/Core/Storage/IOS1LegacySnapshotImporter.swift` |
| `BlueStoneIM/IOS1MeSettingsViews.swift` | `BlueStoneIM/IOS1Features/Me/IOS1MeSettingsViews.swift` |
| `BlueStoneIM/IOS1MediaPipeline.swift` | `BlueStoneIM/Core/AppSupport/Media/IOS1MediaPipeline.swift` |
| `BlueStoneIM/IOS1MessagePersistenceCoordinator.swift` | `BlueStoneIM/Core/Storage/IOS1MessagePersistenceCoordinator.swift` |
| `BlueStoneIM/IOS1MockData.swift` | `BlueStoneIM/Domain/IOS1MockData.swift` |
| `BlueStoneIM/IOS1Models.swift` | `BlueStoneIM/Domain/IOS1Models.swift` |
| `BlueStoneIM/IOS1PreloginBootstrap.swift` | `BlueStoneIM/Core/Networking/Access/IOS1PreloginBootstrap.swift` |
| `BlueStoneIM/IOS1PreloginBootstrapResolver.swift` | `BlueStoneIM/Core/Networking/Access/IOS1PreloginBootstrapResolver.swift` |
| `BlueStoneIM/IOS1PreloginBootstrapStartup.swift` | `BlueStoneIM/Core/Networking/Access/IOS1PreloginBootstrapStartup.swift` |
| `BlueStoneIM/IOS1PresenceConnectivityProjection.swift` | `BlueStoneIM/Domain/IOS1PresenceConnectivityProjection.swift` |
| `BlueStoneIM/IOS1RTCCallRecordCard.swift` | `BlueStoneIM/IOS1Features/Calls/IOS1RTCCallRecordCard.swift` |
| `BlueStoneIM/IOS1RTCCallRecordMessage.swift` | `BlueStoneIM/Domain/IOS1RTCCallRecordMessage.swift` |
| `BlueStoneIM/IOS1RTCCallRecordRedial.swift` | `BlueStoneIM/IOS1Features/Calls/IOS1RTCCallRecordRedial.swift` |
| `BlueStoneIM/IOS1RealtimeClient.swift` | `BlueStoneIM/Core/Networking/Realtime/IOS1RealtimeClient.swift` |
| `BlueStoneIM/IOS1RealtimeQUICTransport.swift` | `BlueStoneIM/Core/Networking/Realtime/IOS1RealtimeQUICTransport.swift` |
| `BlueStoneIM/IOS1RealtimeTransport.swift` | `BlueStoneIM/Core/Networking/Realtime/IOS1RealtimeTransport.swift` |
| `BlueStoneIM/IOS1RegistrationFlowPolicy.swift` | `BlueStoneIM/IOS1Features/Auth/IOS1RegistrationFlowPolicy.swift` |
| `BlueStoneIM/IOS1RemoteAPIModels.swift` | `BlueStoneIM/Core/Networking/IOS1RemoteAPIModels.swift` |
| `BlueStoneIM/IOS1ScopedResponseFence.swift` | `BlueStoneIM/Core/Networking/Access/IOS1ScopedResponseFence.swift` |
| `BlueStoneIM/IOS1SnapshotCache.swift` | `BlueStoneIM/Core/Storage/IOS1SnapshotCache.swift` |
| `BlueStoneIM/IOS1StickerGIFRenderer.swift` | `BlueStoneIM/IOS1Features/Chat/IOS1StickerGIFRenderer.swift` |
| `BlueStoneIM/IOS1StickerStore.swift` | `BlueStoneIM/Stores/IOS1StickerStore.swift` |
| `BlueStoneIM/IOS1SyncEngine.swift` | `BlueStoneIM/Core/AppSupport/Sync/IOS1SyncEngine.swift` |
| `BlueStoneIM/IOS1VideoCallViews.swift` | `BlueStoneIM/IOS1Features/Calls/IOS1VideoCallViews.swift` |
| `BlueStoneIM/IOS1VideoMediaClient.swift` | `BlueStoneIM/Core/AppSupport/Calls/IOS1VideoMediaClient.swift` |
| `BlueStoneIM/IOS1VoiceMediaClient.swift` | `BlueStoneIM/Core/AppSupport/Calls/IOS1VoiceMediaClient.swift` |
| `BlueStoneIM/IOS1WireCodec.swift` | `BlueStoneIM/Core/Networking/Realtime/IOS1WireCodec.swift` |
| `BlueStoneIM/IOSNotificationAuthorization.swift` | `BlueStoneIM/Core/AppSupport/Notifications/IOSNotificationAuthorization.swift` |
| `BlueStoneIM/IOSNotificationModels.swift` | `BlueStoneIM/Core/AppSupport/Notifications/IOSNotificationModels.swift` |
| `BlueStoneIM/IOSNotificationRuntime.swift` | `BlueStoneIM/Core/AppSupport/Notifications/IOSNotificationRuntime.swift` |
| `BlueStoneIM/IOSSceneCaptureMonitor.swift` | `BlueStoneIM/Core/AppSupport/Diagnostics/IOSSceneCaptureMonitor.swift` |
| `BlueStoneIM/LoginLogStore.swift` | `BlueStoneIM/IOS1Features/Auth/LoginLogStore.swift` |
| `BlueStoneIM/MainShellView.swift` | `BlueStoneIM/App/MainShellView.swift` |
| `BlueStoneIM/MediaDownloadPipeline.swift` | `BlueStoneIM/Core/AppSupport/Media/MediaDownloadPipeline.swift` |
| `BlueStoneIM/MediaLayeredCache.swift` | `BlueStoneIM/Core/AppSupport/Media/MediaLayeredCache.swift` |
| `BlueStoneIM/MediaResourceModels.swift` | `BlueStoneIM/Domain/MediaResourceModels.swift` |
| `BlueStoneIM/MessagePersistenceMediaCache.swift` | `BlueStoneIM/Core/Storage/MessagePersistenceMediaCache.swift` |
| `BlueStoneIM/MessagePersistenceScopeCleanup.swift` | `BlueStoneIM/Core/Storage/MessagePersistenceScopeCleanup.swift` |
| `BlueStoneIM/PreloginStrictJSON.swift` | `BlueStoneIM/Core/Networking/Access/PreloginStrictJSON.swift` |
| `BlueStoneIM/PreloginTrust.swift` | `BlueStoneIM/Core/Networking/Access/PreloginTrust.swift` |
| `BlueStoneIM/RTCCallDiagnosticLogStore.swift` | `BlueStoneIM/Core/AppSupport/Calls/RTCCallDiagnosticLogStore.swift` |
| `BlueStoneIM/RTCQualitySampling.swift` | `BlueStoneIM/Core/AppSupport/Calls/RTCQualitySampling.swift` |
| `BlueStoneIM/RTCQualityTelemetrySession.swift` | `BlueStoneIM/Core/AppSupport/Calls/RTCQualityTelemetrySession.swift` |
| `BlueStoneIM/RTCVideoMediaPolicies.swift` | `BlueStoneIM/Core/AppSupport/Calls/RTCVideoMediaPolicies.swift` |
| `BlueStoneIM/RTCVideoRenderer.swift` | `BlueStoneIM/Core/AppSupport/Calls/RTCVideoRenderer.swift` |
| `BlueStoneIM/RealtimeClient+ConnectionLifecycle.swift` | `BlueStoneIM/Core/Networking/Realtime/RealtimeClient+ConnectionLifecycle.swift` |
| `BlueStoneIM/RealtimeConnectionDiagnostics.swift` | `BlueStoneIM/Core/Networking/Realtime/RealtimeConnectionDiagnostics.swift` |
| `BlueStoneIM/RealtimeFrameDecoder.swift` | `BlueStoneIM/Core/Networking/Realtime/RealtimeFrameDecoder.swift` |
| `BlueStoneIM/RealtimeTransportContracts.swift` | `BlueStoneIM/Core/Networking/Realtime/RealtimeTransportContracts.swift` |
| `BlueStoneIM/RuntimeRouteFailover.swift` | `BlueStoneIM/Core/Networking/Access/RuntimeRouteFailover.swift` |
| `BlueStoneIM/RuntimeRouteModels.swift` | `BlueStoneIM/Core/Networking/Access/RuntimeRouteModels.swift` |
| `BlueStoneIM/RuntimeRouteStore.swift` | `BlueStoneIM/Core/Networking/Access/RuntimeRouteStore.swift` |
| `BlueStoneIM/StickerLibraryModels.swift` | `BlueStoneIM/Domain/StickerLibraryModels.swift` |
| `BlueStoneIM/SyncEngineContract.swift` | `BlueStoneIM/Core/AppSupport/Sync/SyncEngineContract.swift` |
| `BlueStoneIM/VideoCallScreenshotHost.swift` | `BlueStoneIM/IOS1Features/Calls/VideoCallScreenshotHost.swift` |
| `BlueStoneIM/VoiceMediaSession.swift` | `BlueStoneIM/Core/AppSupport/Calls/VoiceMediaSession.swift` |
| `BlueStoneIM/WebRTCVideoMediaClient+Media.swift` | `BlueStoneIM/Core/AppSupport/Calls/WebRTCVideoMediaClient+Media.swift` |
| `BlueStoneIM/WebRTCVideoMediaClient+Recovery.swift` | `BlueStoneIM/Core/AppSupport/Calls/WebRTCVideoMediaClient+Recovery.swift` |
| `BlueStoneIM/WebRTCVideoMediaClient+Signaling.swift` | `BlueStoneIM/Core/AppSupport/Calls/WebRTCVideoMediaClient+Signaling.swift` |
| `BlueStoneIM/WebRTCVoiceMediaClient+QualityDiagnostics.swift` | `BlueStoneIM/Core/AppSupport/Calls/WebRTCVoiceMediaClient+QualityDiagnostics.swift` |
| `BlueStoneIM/WebRTCVoiceMediaClient+Recovery.swift` | `BlueStoneIM/Core/AppSupport/Calls/WebRTCVoiceMediaClient+Recovery.swift` |
| `BlueStoneIM/WebRTCVoiceMediaClient+Signaling.swift` | `BlueStoneIM/Core/AppSupport/Calls/WebRTCVoiceMediaClient+Signaling.swift` |

<!-- WDT_IOS1_SOURCE_FOLDERS_20261113_END -->

<!-- WDT_IOS1_WDT_SOURCE_NAMES_20261113_BEGIN -->

## 问达通生产源码命名（2026-11-13）

将主工程及本地 Package 的 IOS1 文件名前缀统一为 WDT，目录名改为 WDTDesignSystem 和 WDTFeatures。应用入口使用 WDTApp.swift，风险遥测文件使用 WDTRiskTelemetry.swift。源码内容、工程引用 ID、目标成员和编译阶段均已核对。测试目录保留原样。回退时按下表逆向改名，并还原工程、Package 清单和脚本的路径差分。

| 原路径 | 新路径 |
| --- | --- |
| `BlueStoneIM/App/IOS1AppState.swift` | `BlueStoneIM/App/WDTAppState.swift` |
| `BlueStoneIM/App/IOS1BlueStoneIMApp.swift` | `BlueStoneIM/App/WDTApp.swift` |
| `BlueStoneIM/Core/AppSupport/AccountSession/IOS1AppState+AuthenticationProfileWorkspace.swift` | `BlueStoneIM/Core/AppSupport/AccountSession/WDTAppState+AuthenticationProfileWorkspace.swift` |
| `BlueStoneIM/Core/AppSupport/Calls/IOS1AppState+VoiceCalls.swift` | `BlueStoneIM/Core/AppSupport/Calls/WDTAppState+VoiceCalls.swift` |
| `BlueStoneIM/Core/AppSupport/Calls/IOS1CallLifecycle.swift` | `BlueStoneIM/Core/AppSupport/Calls/WDTCallLifecycle.swift` |
| `BlueStoneIM/Core/AppSupport/Calls/IOS1VideoMediaClient.swift` | `BlueStoneIM/Core/AppSupport/Calls/WDTVideoMediaClient.swift` |
| `BlueStoneIM/Core/AppSupport/Calls/IOS1VoiceMediaClient.swift` | `BlueStoneIM/Core/AppSupport/Calls/WDTVoiceMediaClient.swift` |
| `BlueStoneIM/Core/AppSupport/DebugFixtures/IOS1AppState+DebugScreenshotFixtures.swift` | `BlueStoneIM/Core/AppSupport/DebugFixtures/WDTAppState+DebugScreenshotFixtures.swift` |
| `BlueStoneIM/Core/AppSupport/Diagnostics/IOS1AccessDiagnostics.swift` | `BlueStoneIM/Core/AppSupport/Diagnostics/WDTAccessDiagnostics.swift` |
| `BlueStoneIM/Core/AppSupport/Diagnostics/IOS1IOSRiskTelemetry.swift` | `BlueStoneIM/Core/AppSupport/Diagnostics/WDTRiskTelemetry.swift` |
| `BlueStoneIM/Core/AppSupport/GroupFileMapping/IOS1AppState+RemoteGroupFileMapping.swift` | `BlueStoneIM/Core/AppSupport/GroupFileMapping/WDTAppState+RemoteGroupFileMapping.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppState+ContactsInboxDevices.swift` | `BlueStoneIM/Core/AppSupport/WDTAppState+ContactsInboxDevices.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppState+ConversationsHistory.swift` | `BlueStoneIM/Core/AppSupport/WDTAppState+ConversationsHistory.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppState+FilesAttachments.swift` | `BlueStoneIM/Core/AppSupport/WDTAppState+FilesAttachments.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppState+GroupAdministration.swift` | `BlueStoneIM/Core/AppSupport/WDTAppState+GroupAdministration.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppState+GroupsAnnouncements.swift` | `BlueStoneIM/Core/AppSupport/WDTAppState+GroupsAnnouncements.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppState+MessageActions.swift` | `BlueStoneIM/Core/AppSupport/WDTAppState+MessageActions.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppState+MessageSendingAttachments.swift` | `BlueStoneIM/Core/AppSupport/WDTAppState+MessageSendingAttachments.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppState+Realtime.swift` | `BlueStoneIM/Core/AppSupport/WDTAppState+Realtime.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppState+RemoteErrorHandling.swift` | `BlueStoneIM/Core/AppSupport/WDTAppState+RemoteErrorHandling.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppState+SearchConversationSettings.swift` | `BlueStoneIM/Core/AppSupport/WDTAppState+SearchConversationSettings.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppState+StickerLibrary.swift` | `BlueStoneIM/Core/AppSupport/WDTAppState+StickerLibrary.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppStateDiagnosticsSupport.swift` | `BlueStoneIM/Core/AppSupport/WDTAppStateDiagnosticsSupport.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppStateLocalSupport.swift` | `BlueStoneIM/Core/AppSupport/WDTAppStateLocalSupport.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppStatePolicies.swift` | `BlueStoneIM/Core/AppSupport/WDTAppStatePolicies.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppStatePolicySupport.swift` | `BlueStoneIM/Core/AppSupport/WDTAppStatePolicySupport.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppStateRTCSupport.swift` | `BlueStoneIM/Core/AppSupport/WDTAppStateRTCSupport.swift` |
| `BlueStoneIM/Core/AppSupport/IOS1AppStateSlideCaptchaSupport.swift` | `BlueStoneIM/Core/AppSupport/WDTAppStateSlideCaptchaSupport.swift` |
| `BlueStoneIM/Core/AppSupport/InteractionPolicy/IOS1AppInteractionPolicy.swift` | `BlueStoneIM/Core/AppSupport/InteractionPolicy/WDTAppInteractionPolicy.swift` |
| `BlueStoneIM/Core/AppSupport/Media/IOS1AvatarRealtimeProjection.swift` | `BlueStoneIM/Core/AppSupport/Media/WDTAvatarRealtimeProjection.swift` |
| `BlueStoneIM/Core/AppSupport/Media/IOS1MediaPipeline.swift` | `BlueStoneIM/Core/AppSupport/Media/WDTMediaPipeline.swift` |
| `BlueStoneIM/Core/AppSupport/MessageMapping/IOS1AppState+GroupSystemMessagePresentation.swift` | `BlueStoneIM/Core/AppSupport/MessageMapping/WDTAppState+GroupSystemMessagePresentation.swift` |
| `BlueStoneIM/Core/AppSupport/MessageMapping/IOS1AppState+IdentityPresentation.swift` | `BlueStoneIM/Core/AppSupport/MessageMapping/WDTAppState+IdentityPresentation.swift` |
| `BlueStoneIM/Core/AppSupport/MessageMapping/IOS1AppState+RemoteMessagePayloadMapping.swift` | `BlueStoneIM/Core/AppSupport/MessageMapping/WDTAppState+RemoteMessagePayloadMapping.swift` |
| `BlueStoneIM/Core/AppSupport/MessageMapping/IOS1AppState+RemoteMessageStateMapping.swift` | `BlueStoneIM/Core/AppSupport/MessageMapping/WDTAppState+RemoteMessageStateMapping.swift` |
| `BlueStoneIM/Core/AppSupport/RemoteSync/IOS1AppState+RemoteRegistrationSnapshotSync.swift` | `BlueStoneIM/Core/AppSupport/RemoteSync/WDTAppState+RemoteRegistrationSnapshotSync.swift` |
| `BlueStoneIM/Core/AppSupport/Sync/IOS1SyncEngine.swift` | `BlueStoneIM/Core/AppSupport/Sync/WDTSyncEngine.swift` |
| `BlueStoneIM/Core/AppSupport/TenantSession/IOS1AppState+TenantSwitchingRemoteMapping.swift` | `BlueStoneIM/Core/AppSupport/TenantSession/WDTAppState+TenantSwitchingRemoteMapping.swift` |
| `BlueStoneIM/Core/NetworkSupport/IOS1NetworkSupportTypes.swift` | `BlueStoneIM/Core/NetworkSupport/WDTNetworkSupportTypes.swift` |
| `BlueStoneIM/Core/Networking/Access/IOS1AccessDiscovery.swift` | `BlueStoneIM/Core/Networking/Access/WDTAccessDiscovery.swift` |
| `BlueStoneIM/Core/Networking/Access/IOS1PreloginBootstrap.swift` | `BlueStoneIM/Core/Networking/Access/WDTPreloginBootstrap.swift` |
| `BlueStoneIM/Core/Networking/Access/IOS1PreloginBootstrapResolver.swift` | `BlueStoneIM/Core/Networking/Access/WDTPreloginBootstrapResolver.swift` |
| `BlueStoneIM/Core/Networking/Access/IOS1PreloginBootstrapStartup.swift` | `BlueStoneIM/Core/Networking/Access/WDTPreloginBootstrapStartup.swift` |
| `BlueStoneIM/Core/Networking/Access/IOS1ScopedResponseFence.swift` | `BlueStoneIM/Core/Networking/Access/WDTScopedResponseFence.swift` |
| `BlueStoneIM/Core/Networking/IOS1HTTPTransport.swift` | `BlueStoneIM/Core/Networking/WDTHTTPTransport.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Account.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIClient+Account.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Auth.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIClient+Auth.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Bootstrap.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIClient+Bootstrap.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Contacts.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIClient+Contacts.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Files.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIClient+Files.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Groups.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIClient+Groups.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Messages.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIClient+Messages.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIClient+RTC.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIClient+RTC.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Stickers.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIClient+Stickers.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIClient+Workspaces.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIClient+Workspaces.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIClient.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIClient.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIErrorSupport.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIErrorSupport.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAPIProtocol.swift` | `BlueStoneIM/Core/Networking/WDTIMAPIProtocol.swift` |
| `BlueStoneIM/Core/Networking/IOS1IMAppBootstrapSupport.swift` | `BlueStoneIM/Core/Networking/WDTIMAppBootstrapSupport.swift` |
| `BlueStoneIM/Core/Networking/IOS1RemoteAPIModels.swift` | `BlueStoneIM/Core/Networking/WDTRemoteAPIModels.swift` |
| `BlueStoneIM/Core/Networking/Realtime/IOS1RealtimeClient.swift` | `BlueStoneIM/Core/Networking/Realtime/WDTRealtimeClient.swift` |
| `BlueStoneIM/Core/Networking/Realtime/IOS1RealtimeQUICTransport.swift` | `BlueStoneIM/Core/Networking/Realtime/WDTRealtimeQUICTransport.swift` |
| `BlueStoneIM/Core/Networking/Realtime/IOS1RealtimeTransport.swift` | `BlueStoneIM/Core/Networking/Realtime/WDTRealtimeTransport.swift` |
| `BlueStoneIM/Core/Networking/Realtime/IOS1WireCodec.swift` | `BlueStoneIM/Core/Networking/Realtime/WDTWireCodec.swift` |
| `BlueStoneIM/Core/Storage/IOS1CachedRemoteSnapshot.swift` | `BlueStoneIM/Core/Storage/WDTCachedRemoteSnapshot.swift` |
| `BlueStoneIM/Core/Storage/IOS1IMAPIContext.swift` | `BlueStoneIM/Core/Storage/WDTIMAPIContext.swift` |
| `BlueStoneIM/Core/Storage/IOS1IMProtectedSessionStore.swift` | `BlueStoneIM/Core/Storage/WDTIMProtectedSessionStore.swift` |
| `BlueStoneIM/Core/Storage/IOS1LegacySnapshotImporter.swift` | `BlueStoneIM/Core/Storage/WDTLegacySnapshotImporter.swift` |
| `BlueStoneIM/Core/Storage/IOS1MessagePersistenceCoordinator.swift` | `BlueStoneIM/Core/Storage/WDTMessagePersistenceCoordinator.swift` |
| `BlueStoneIM/Core/Storage/IOS1SnapshotCache.swift` | `BlueStoneIM/Core/Storage/WDTSnapshotCache.swift` |
| `BlueStoneIM/Domain/IOS1CertificationPresentation.swift` | `BlueStoneIM/Domain/WDTCertificationPresentation.swift` |
| `BlueStoneIM/Domain/IOS1IdentityPresentation.swift` | `BlueStoneIM/Domain/WDTIdentityPresentation.swift` |
| `BlueStoneIM/Domain/IOS1MockData.swift` | `BlueStoneIM/Domain/WDTMockData.swift` |
| `BlueStoneIM/Domain/IOS1Models.swift` | `BlueStoneIM/Domain/WDTModels.swift` |
| `BlueStoneIM/Domain/IOS1PresenceConnectivityProjection.swift` | `BlueStoneIM/Domain/WDTPresenceConnectivityProjection.swift` |
| `BlueStoneIM/Domain/IOS1RTCCallRecordMessage.swift` | `BlueStoneIM/Domain/WDTRTCCallRecordMessage.swift` |
| `BlueStoneIM/GroupDetails/IOS1GroupDetailMembers.swift` | `BlueStoneIM/GroupDetails/WDTGroupDetailMembers.swift` |
| `BlueStoneIM/IOS1DesignSystem` | `BlueStoneIM/WDTDesignSystem` |
| `BlueStoneIM/IOS1DesignSystem/IOS1DesignSystem.swift` | `BlueStoneIM/WDTDesignSystem/WDTDesignSystem.swift` |
| `BlueStoneIM/IOS1Features` | `BlueStoneIM/WDTFeatures` |
| `BlueStoneIM/IOS1Features/Auth/IOS1AuthViews.swift` | `BlueStoneIM/WDTFeatures/Auth/WDTAuthViews.swift` |
| `BlueStoneIM/IOS1Features/Auth/IOS1DeviceRevocationDetector.swift` | `BlueStoneIM/WDTFeatures/Auth/WDTDeviceRevocationDetector.swift` |
| `BlueStoneIM/IOS1Features/Auth/IOS1RegistrationFlowPolicy.swift` | `BlueStoneIM/WDTFeatures/Auth/WDTRegistrationFlowPolicy.swift` |
| `BlueStoneIM/IOS1Features/Calls/IOS1RTCCallRecordCard.swift` | `BlueStoneIM/WDTFeatures/Calls/WDTRTCCallRecordCard.swift` |
| `BlueStoneIM/IOS1Features/Calls/IOS1RTCCallRecordRedial.swift` | `BlueStoneIM/WDTFeatures/Calls/WDTRTCCallRecordRedial.swift` |
| `BlueStoneIM/IOS1Features/Calls/IOS1VideoCallViews.swift` | `BlueStoneIM/WDTFeatures/Calls/WDTVideoCallViews.swift` |
| `BlueStoneIM/IOS1Features/Chat/IOS1BatchForwardState.swift` | `BlueStoneIM/WDTFeatures/Chat/WDTBatchForwardState.swift` |
| `BlueStoneIM/IOS1Features/Chat/IOS1ChatViews.swift` | `BlueStoneIM/WDTFeatures/Chat/WDTChatViews.swift` |
| `BlueStoneIM/IOS1Features/Chat/IOS1EmojiPickerCore.swift` | `BlueStoneIM/WDTFeatures/Chat/WDTEmojiPickerCore.swift` |
| `BlueStoneIM/IOS1Features/Chat/IOS1EmojiPickerPreferences.swift` | `BlueStoneIM/WDTFeatures/Chat/WDTEmojiPickerPreferences.swift` |
| `BlueStoneIM/IOS1Features/Chat/IOS1EmojiPickerStoreAdapter.swift` | `BlueStoneIM/WDTFeatures/Chat/WDTEmojiPickerStoreAdapter.swift` |
| `BlueStoneIM/IOS1Features/Chat/IOS1EmojiPickerView.swift` | `BlueStoneIM/WDTFeatures/Chat/WDTEmojiPickerView.swift` |
| `BlueStoneIM/IOS1Features/Chat/IOS1StickerGIFRenderer.swift` | `BlueStoneIM/WDTFeatures/Chat/WDTStickerGIFRenderer.swift` |
| `BlueStoneIM/IOS1Features/Contacts/IOS1ContactsViews.swift` | `BlueStoneIM/WDTFeatures/Contacts/WDTContactsViews.swift` |
| `BlueStoneIM/IOS1Features/Contacts/IOS1GroupMuteMode.swift` | `BlueStoneIM/WDTFeatures/Contacts/WDTGroupMuteMode.swift` |
| `BlueStoneIM/IOS1Features/Conversations/IOS1ConversationViews.swift` | `BlueStoneIM/WDTFeatures/Conversations/WDTConversationViews.swift` |
| `BlueStoneIM/IOS1Features/Files/IOS1FilesRTCViews.swift` | `BlueStoneIM/WDTFeatures/Files/WDTFilesRTCViews.swift` |
| `BlueStoneIM/IOS1Features/Me/IOS1MeSettingsViews.swift` | `BlueStoneIM/WDTFeatures/Me/WDTMeSettingsViews.swift` |
| `BlueStoneIM/Stores/IOS1CallStore.swift` | `BlueStoneIM/Stores/WDTCallStore.swift` |
| `BlueStoneIM/Stores/IOS1ContactStore.swift` | `BlueStoneIM/Stores/WDTContactStore.swift` |
| `BlueStoneIM/Stores/IOS1ConversationStore.swift` | `BlueStoneIM/Stores/WDTConversationStore.swift` |
| `BlueStoneIM/Stores/IOS1FileStore.swift` | `BlueStoneIM/Stores/WDTFileStore.swift` |
| `BlueStoneIM/Stores/IOS1StickerStore.swift` | `BlueStoneIM/Stores/WDTStickerStore.swift` |
| `Sources/IM4Core/IOS1CoreHTTPTransport.swift` | `Sources/IM4Core/WDTCoreHTTPTransport.swift` |
| `Sources/IM4Data/IOS1DataAttachmentTransferRepository.swift` | `Sources/IM4Data/WDTDataAttachmentTransferRepository.swift` |
| `Sources/IM4Data/IOS1DataLocalMessageRepository.swift` | `Sources/IM4Data/WDTDataLocalMessageRepository.swift` |
| `Sources/IM4Data/IOS1DataMessageDatabaseMigrations.swift` | `Sources/IM4Data/WDTDataMessageDatabaseMigrations.swift` |
| `Sources/IM4Data/IOS1DataMessageDatabasePaths.swift` | `Sources/IM4Data/WDTDataMessageDatabasePaths.swift` |
| `Sources/IM4Data/IOS1DataMessageDatabaseSchema.swift` | `Sources/IM4Data/WDTDataMessageDatabaseSchema.swift` |
| `Sources/IM4Data/IOS1DataSQLiteMessageRepository.swift` | `Sources/IM4Data/WDTDataSQLiteMessageRepository.swift` |
| `Sources/IM4Stores/IOS1StoresCallStore.swift` | `Sources/IM4Stores/WDTStoresCallStore.swift` |
| `Sources/IM4Stores/IOS1StoresContactStore.swift` | `Sources/IM4Stores/WDTStoresContactStore.swift` |
| `Sources/IM4Stores/IOS1StoresConversationStore.swift` | `Sources/IM4Stores/WDTStoresConversationStore.swift` |
| `Sources/IM4Stores/IOS1StoresFileStore.swift` | `Sources/IM4Stores/WDTStoresFileStore.swift` |
| `Sources/IM4Stores/IOS1StoresStickerStore.swift` | `Sources/IM4Stores/WDTStoresStickerStore.swift` |

<!-- WDT_IOS1_WDT_SOURCE_NAMES_20261113_END -->

## 聊天视频下载进度（2026-11-13）

<!-- WDT_IOS1_VIDEO_DOWNLOAD_PROGRESS_20261113_BEGIN -->

聊天视频主动下载时恢复进度显示。旧版气泡组装把视频的下载快照过滤掉。共用进度控件在缺少总大小时会使用转圈，拿到总大小才切换到横条。

- `BlueStoneIM/App/ChatFileAttachmentAssembly.swift` 将下载快照传给气泡，沿用现有按附件观察和会话绑定的取消动作。
- `Sources/IM4Features/Chat/ChatMediaBubbleViews.swift` 将深色背景板和进度条覆盖在固定大小的封面底部。
- `Sources/IM4Features/ChatAttachmentDetail.swift` 为视频气泡提供横条样式与单行状态文字。等待、下载和校验保存共用相同布局。
- 合并时一起应用以上三处。测试目录沿用既有用例。

- iPhone 17 模拟器临时副本通过 4 项附件测试，覆盖进度高度、字节进度、取消及封面不触发视频下载。副本暂时替换了存在 Swift 并发编译错误的启动测试辅助类，并增加临时高度断言。正式测试目录保留原样。

<!-- WDT_IOS1_VIDEO_DOWNLOAD_PROGRESS_20261113_END -->

## 注册邀请码交给服务端校验（2026-11-13）

<!-- WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113_BEGIN -->

- 注册表单、先选企业、注册验证码和注册入企请求接受非空邀请码。已识别的旧码沿用原有归一化，其他输入只去掉首尾空白。
- 服务端确认的邀请绑定由注册流程核对。保留 App、设备、企业和会话校验以及默认企业回退保护。
- 涉及注册 UI、RegistrationFlowPolicy、注册和验证码请求、企业上下文以及注册续办。合并时按同一标记应用各处，并保留对应请求和回执断言。
- 注册验证码查询保留 URL 参数编码，避免邀请码里的 `&`、`+` 或 `=` 在拼接路由时被拆成其他参数。
- iPhone 17 模拟器临时副本通过 25 项注册、验证码和企业绑定回归。副本临时绕过已有的启动测试辅助类编译错误；工程中的该辅助类保留原样。

<!-- WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113_END -->

## 聊天惯性滚动期间的缩略图（2026-11-13）

<!-- WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113_BEGIN -->

- 缩略图在排队前检查滚动，但等待限并发名额期间可能开始下一次滑动。下载、解码或缓存写入完成时也可能正处于惯性减速。
- Sources/IM4Features/Chat/ChatMediaScrollActivity.swift 提供拖动、减速和停稳的统一判断。WenDaTong/App/ChatAttachmentThumbnailLoader.swift 在取得名额后、读取兜底资源以及更新气泡前重新检查。内存命中保留即时显示。
- 两处一起合并。复用现有滚动阶段、缓存范围和任务取消机制。

- iPhone 17 模拟器临时副本通过 4 项回归，覆盖排队期间开始减速、缓存并发控制及图片和视频封面内存首帧。临时副本替换了已有并发编译错误的启动测试辅助类。

<!-- WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113_END -->

## 聊天图片缩略图优先（2026-11-13）

<!-- WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_BEGIN -->

- 普通图片气泡通过 ChatAttachmentThumbnailAssembly 和 ChatAttachmentThumbnailContent 使用消息中的缩略图地址。可用的内存或本地原图缓存仍可直接出图，缩略图缺失或读取失败沿用原图下载和原有加载提示。
- AppState+AttachmentURLsAndProgress 过滤文件详情回退到同一原图路径的缩略图地址。ChatAttachmentActions 在点击普通图片时优先准备原件。
- 消息缺少可用小图时查询文件详情，有独立小图则显示并写入缩略图缓存。缺失或读取失败时把同一份文件详情交给原图下载流程。涉及 AppState+FileOpenAndSnapshots、AppState+AttachmentDownload 和 AppState+VoiceMessagePlayback。
- 合并时一起应用以上改动。复用现有缩略图渲染、滚动等待、后台解码与缓存。

- iPhone 17 模拟器临时副本通过 4 项测试，覆盖文件详情小图优先及磁盘缓存、原图缓存复用、图片与视频封面内存首帧、视频封面持久化。测试副本暂时替换已有并发编译错误的启动测试辅助类。

<!-- WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113_END -->

## 聊天语音气泡时长布局（2026-11-13）

<!-- WDT_IOS1_VOICE_DURATION_LAYOUT_20261113_BEGIN -->

- 聊天语音气泡的波形子视图使用固定柱宽和间距，空间不足时柱条越过波形布局宽度，盖住右侧时长。
- Sources/IM4Features/Chat/ChatMediaBubbleViews.swift 优先为单行时长保留其完整宽度，语音气泡在窄布局中可收缩。
- Sources/IM4Features/Chat/ChatVoiceRecordingViews.swift 为聊天气泡提供可收缩波形。按可用宽度等比调整柱宽和间距，保留波形采样数。合并时同步应用以上两处。

- iPhone 17 模拟器临时副本通过 3 项语音回归，包含 174 pt 内容宽度下的 15 秒截图。截图确认波形和时长之间有间距。测试副本临时替换已有并发编译错误的启动测试辅助类。

<!-- WDT_IOS1_VOICE_DURATION_LAYOUT_20261113_END -->

## 工程文件与构建名称统一（2026-11-13）

<!-- WDT_IOS1_WENDATONG_TARGET_NAMES_20261113_BEGIN -->

- 源码和测试目录、三个共享 Scheme、签名文件、Target、Swift 模块、构建产物与 App 入口类型统一使用 WenDaTong。
- 同步 project.pbxproj、Package.swift、归档与模拟器脚本、测试导入和工程路径。工程引用 ID、依赖锁定、Bundle ID 与签名文件内容保持一致。
- 保留设备上已有的数据库、缓存目录和错误域名称，以便现有安装继续读取本地数据。
- 外部构建和测试命令使用新 Scheme、产物路径及测试 Target。合并时同时迁移目录、Scheme 和签名文件，并更新以上引用。

- Debug 模拟器构建通过，产物标识 app.xltest.com。归档校验 8 项与两组模拟器脚本检查通过。临时副本绕过现有的启动测试辅助类编译错误后，9 项相关 XCTest 通过。该临时改动已还原。

<!-- WDT_IOS1_WENDATONG_TARGET_NAMES_20261113_END -->

## Xcode 工程更名（2026-11-13）

<!-- WDT_IOS1_XCODE_PROJECT_NAME_20261113_BEGIN -->

- 将 `BlueStoneIM.xcodeproj` 原位更名为 `WenDaTong.xcodeproj`，三个共享 Scheme 的 ReferencedContainer 同步切换。
- Xcode 工程对象、Target、Scheme 名、产物名、签名、Bundle ID、SwiftPM 依赖和应用源码路径保持原样。
- 同步 README、模拟器运行脚本、重构验收脚本、内部归档脚本及历史 APP2 归档脚本的工程路径。
- 测试目录按既定范围保留。AccessDiagnosticsTests.swift、HTTPVerificationContactAndRemarkTests.swift、test_verify_app1_archive.py 的路径检查仍使用旧工程名。
- 合并时先确保目标工程名未占用，再将整个 xcodeproj 原位更名并更新以下路径引用。外部命令的 -project 参数需使用新路径。

| 文件（更名后） | 修改前 SHA-256 | 修改后 SHA-256 |
| --- | --- | --- |
| `WenDaTong.xcodeproj/project.pbxproj` | `19c88c1af911e7cf1cdfde4827a6971ac12c4972192c9161c33bd0d2850d9b49` | `a197e8ff32a2839dba8029124e29cf7cba20548937b537ab2cb1468351faee56` |
| `WenDaTong.xcodeproj/xcshareddata/xcschemes/BlueStoneIM-App1.xcscheme` | `64805c6f2547ebce8792db324eafb7578c3f02ed124e99040888a30b5f6caf20` | `cc4fe354dc88829ca45901cb2236493c40b70ebffb4e4e4317beb705072d9d5c` |
| `WenDaTong.xcodeproj/xcshareddata/xcschemes/BlueStoneIM-InternalValidation.xcscheme` | `964f443cb328f9717a579bc5b5a1e03b5494a2b6abfdd32ce67108769bf550a1` | `b739628a25072392d6a5a4712528231c025be308be22c3afeda56c75c01ffd0e` |
| `WenDaTong.xcodeproj/xcshareddata/xcschemes/BlueStoneIM.xcscheme` | `1407c268cb2c072696fc94fb17bcd03c615eaae975e64174138ef9aa34819636` | `2ed6b05c641e7f78137937cbc3dee3dda428995b666a8292b6aa1cc1b79b0ef1` |
| `scripts/archive-app2-release.sh` | `ab12cc1ab93a7652a45af32da6c5b838be6a740b2a7fb825b57524708aebb0a2` | `302e6982510e0ce474323e7549f8b86763fa42abf92db12e572efca5cb77e27e` |
| `scripts/archive-internal-validation.sh` | `3d3c6f2c1f9d96fad6cbc7237f445e35089ff577ec4f6d6767da15cc862ada2f` | `7771041005744d5d5b8a25232919ab06fa1b2686ffafb0c50cafb6f821a86fe4` |
| `scripts/refactor-check.sh` | `015fb5f585defeefd81932a5219c3938faadb046412869a0fe69584d91b4616d` | `8d5e3373783bc68075e619a889f31e3481d8cd6226d63234231ac022ed7d42cc` |
| `scripts/run-simulator.sh` | `7d902c6b9eca8ad5fb767332af4da8db7cbae1ef32c799a638d56c7342511f21` | `5a229ecbc8457bb324482815a9b948f352fc8d40965ae4d3864f1c42666769a7` |
| `README.md` | `b7bb3c970ebf840a45aadd2c5a54cf63552fecc38e25fb93903e6810ef37e235` | `3c3f972a6998196e449e9cb24370ed81c391e4cb4a3931f74f7f3d12a32ccb1f` |

<!-- WDT_IOS1_XCODE_PROJECT_NAME_20261113_END -->

## 工程侧栏资源归类（2026-11-13）

<!-- WDT_IOS1_PROJECT_RESOURCES_20261113_BEGIN -->

- 主工程 BlueStoneIM 根层仅列出文件夹。真实路径与 Xcode 分组同步，保留既有编译和打包阶段成员。
- project.pbxproj 更新签名、Info.plist、Swift 桥接头文件路径。资源目录下保留 InfoPlist.strings 本地化变体组。
- Package.swift 同步排除路径。归档脚本、推广图脚本和 README 同步资源位置。推广图脚本采用图标集内实际的 AppStore-1024.png。GIF 解码器仅调整 Wuffs 的 include 路径。
- 合并时按下表移动文件并同步上述引用。测试目录按要求未改动，其中有测试直接读取旧配置路径。
- 验证包括工程对象和引用路径逐项对照、SwiftPM 清单解析、C 语法检查、配置文件检查和脚本语法检查。

| 原路径（相对 BlueStoneIM） | 新路径（相对 BlueStoneIM） | 移动后 SHA-256 |
| --- | --- | --- |
| `BlueStoneIM.entitlements` | `WDTConfiguration/BlueStoneIM.entitlements` | `080523135221b8a9ce7ab047e6845862af5f83c0610a8819a8af0d6f17a8d4a7` |
| `BlueStoneIMDebug.entitlements` | `WDTConfiguration/BlueStoneIMDebug.entitlements` | `97704a8960b4facceef54397a08fb5d0a456247c3627359215aa2a27df22656c` |
| `BlueStoneIMRelease.entitlements` | `WDTConfiguration/BlueStoneIMRelease.entitlements` | `5836ca5c18c70afb57e7936b2e710eae5fd15fe8f979d04e1a94c16d97bfde2f` |
| `Info.plist` | `WDTConfiguration/Info.plist` | `08dbf0f8472ea776a0afe0adcd0af46dfd8d09ac48be0111d62caf1c79dcecf9` |
| `Assets.xcassets` | `WDTResources/Assets.xcassets` | `ec5e93364131b97a9c155abc2b400c98dd054e8eb30d3e906f75c87d5a2ee294` |
| `PrivacyInfo.xcprivacy` | `WDTResources/PrivacyInfo.xcprivacy` | `bd5d55dfb40da5049b92a496007d8e054ba0aac4f81b23a99f2d99950ab1386c` |
| `zh-Hans.lproj` | `WDTResources/zh-Hans.lproj` | `101c5ac88cdf2d7e7d8f44cae1f37a10d0c3fa95664230398606f1976ea47231` |
| `AuthBackground.metal` | `WDTDesignSystem/AuthBackground.metal` | `b4b539a882db700b26d2cf8dbb6217b529b75e2d03f7c02d59f25e7ab2644c30` |
| `GIFFallbackDecoder.c` | `ThirdParty/GIF/GIFFallbackDecoder.c` | `c1f186956169dd2c0109b1459eb755c442fd754ac7af226b2519a760da161a9e` |
| `GIFFallbackDecoder.h` | `ThirdParty/GIF/GIFFallbackDecoder.h` | `4b140ff2f513d7ef13ecbfd4899961e2b980dbb64fafddea1dde85cd7d0fee8a` |
| `MEDIA_PIPELINE_SOLUTION.md` | `WDTDocs/MEDIA_PIPELINE_SOLUTION.md` | `a1b02c6196cadb7e731def7989c44320410cae236e636e640507d66f9a90d785` |
| `PERF_OPT_PLAN.md` | `WDTDocs/PERF_OPT_PLAN.md` | `8e46ec56700d0b889b701cbafd5f038eba8cc72dbbf249f5078c5570ba8a4ea2` |
| `VOICE_MESSAGE_DURATION_FILE_LIST_UAT_20260725.md` | `WDTDocs/VOICE_MESSAGE_DURATION_FILE_LIST_UAT_20260725.md` | `af633004d7f76cb0c9f101b2b32a3d2bbb58aaef2cd38e729f958eec3e828fe5` |

目录 SHA-256 根据内部文件路径与内容哈希计算（忽略 Finder 元数据）。除 GIF C 源码外，移动前后哈希一致。GIF C 源码移动前哈希为 `e6a17d8a5362a578d9321e781dab5bc848419c96d74e97c4639a5d42cad2e1c0`。

<!-- WDT_IOS1_PROJECT_RESOURCES_20261113_END -->

## iOS1 搜索 · 请求、响应、输入与游标（实施中）

- `BASED_ON_CANONICAL_HEAD=8ea3ec41903dd96c7f0d86576f1de51dd11a8e79`，iOS1 tree `b11d947ec4a0f26cc705895232d88f7b0a1651ad`。实施分支 `codex/ios1-search-optimization-20261113`。
- 标识 `WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113`。AppState 与搜索网络入口实现单在途、取消传播和身份校验。搜索响应保留分类失败、降级、精确总数和游标，并兼容旧格式。原入口接入当前查询的错误、重试与分类续页状态。全局单字仍支持其他分类。
- 契约涉及 `BlueStoneIM/{AppState,ChatViews,ConversationViews}.swift`、`BlueStoneIM/App/{ChatMessageInteractionAssembly,ChatNavigationActions,ChatScreenComposition,ChatTranscriptLayoutAssembly}.swift`、`BlueStoneIM/Core/AppSupport/AppState+SearchConversationSettings.swift`、`BlueStoneIM/Core/Networking/IMAPIClient+{Contacts,RequestExecution}.swift`、`BlueStoneIM/Features/Conversations/ConversationListSearch.swift`、`Sources/IM4Data/NetworkingDTO/SearchResponseWireModels.swift`、`Sources/IM4Features/Chat/ChatHistorySearchViews.swift` 及 `BlueStoneIMTests/{HTTPAccountPolicyAndGroupLifecycleTests,RemoteSearchModelTests}.swift`。
- 标识 `WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113`。两处搜索使用支持组字的同一输入框，键盘提交立即发起查询并合并同一在途请求。涉及 `BlueStoneIM/{ChatViews,ConversationViews}.swift`、`BlueStoneIM/DesignSystem/CommonControlViews.swift`、`BlueStoneIM/App/ChatNavigationActions.swift`、`BlueStoneIM/Features/Conversations/ConversationListSearch.swift`、`Sources/IM4Features/Chat/ChatHistorySearchViews.swift` 及 `BlueStoneIMTests/{ChatHeaderStatusBoundaryTests,DesignSystemComponentBoundaryTests}.swift`。
- 标识 `WDT_IOS1_SEARCH_CURSOR_V2_20261113`。纯消息范围用独立的 `cursor_v2` 链，首请求带空值，续页发送原始令牌。混合搜索保留现有合同，旧服务达到偏移界限时展示覆盖有限。涉及 `BlueStoneIM/{ChatViews,IMAPIProtocol}.swift`、`BlueStoneIM/App/{ChatMessageInteractionAssembly,ChatNavigationActions,ChatScreenComposition}.swift`、`BlueStoneIM/Core/AppSupport/AppState+SearchConversationSettings.swift`、`BlueStoneIM/Core/Networking/IMAPIClient+Contacts.swift`、`BlueStoneIM/Features/Conversations/ConversationListSearch.swift`、`Sources/IM4Features/Chat/ChatHistorySearchViews.swift` 和 `BlueStoneIMTests/HTTPAccountPolicyAndGroupLifecycleTests.swift`。
- 模拟器工程通过请求契约、UIKit 组字及游标定向测试。服务端原有的单字混合、单字纯消息验证及分页合同测试通过。回退按完整功能标识和相关测试差分执行。

### 独立搜索页及最近搜索

- `WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113`。会话列表保留 `@我` 本地搜索，其他搜索进入全屏页。草稿、分类、游标、结果、查询缓存和跳转身份由独立页面持有。范围包括 `BlueStoneIM/ConversationViews.swift`、`BlueStoneIM/Features/Conversations/ConversationListSearch.swift`、新文件 `TenantGlobalSearchResults.swift`、`BlueStoneIM/Core/AppSupport/AppState+AttachmentURLsAndProgress.swift` 的搜索文件入口、对应 PBX 登记及挂载测试。旧表尾搜索及其状态删除。
- `WDT_IOS1_CHAT_SEARCH_PAGE_20261113`。新文件 `BlueStoneIM/App/ChatHistorySearchPage.swift` 提供页面状态、日期和分类筛选、纯消息分页以及定位条。保留原历史水合和滚动入口，移除旧内嵌搜索与共享聊天输入状态。入口和动作见 `ChatViews.swift`、`App/Chat{HeaderAssembly,TranscriptLayoutAssembly,ScreenComposition,ScrollPositionAssembly}.swift`。旧逻辑从 `App/Chat{NavigationActions,MessageInteractionAssembly}.swift` 和 `Sources/IM4Features/Chat/ChatScreenPresentationState.swift` 移除。结果展示及解码见 `Sources/IM4Features/Chat/ChatHistorySearch{Views,ResultPresentation}.swift`、`Sources/IM4Data/NetworkingDTO/SearchResultWireModels.swift`。应用层可见性批次和水合身份校验在 `AppState+SearchConversationSettings.swift`。
- `WDT_IOS1_SEARCH_HISTORY_20261113`。新文件 `BlueStoneIM/Core/AppSupport/TenantSearchHistoryStore.swift` 使用设备专属 Keychain、按部署和账号分记录并按企业、IM 身份和会话分隔。写入与清理接现有 AppState 身份及权限事件，普通退出保留。涉及 `AppState.swift`、`AppState+SearchConversationSettings.swift`、`RemoteSync/AppState+WorkspaceAccessErrors.swift`、PBX 登记及两个测试文件。
- 独审回修覆盖 `ChatHistorySearchPage.swift`、`ChatTranscriptLayoutAssembly.swift`、`AppState+SearchConversationSettings.swift`、`TenantSearchHistoryStore.swift`、`Features/Auth/RememberedLoginCredentials.swift` 和相关定向测试。权限拒绝退役已有命中与跳转，本地撤回或删除立即使搜索结果失效，受保护数据不可用时保留待清理范围并在恢复后重试。
- 定向 iOS 模拟器测试 10 项通过，覆盖实际页面打开、单字混合查询只发一次、最近搜索归属及清理、夏令时日期边界、旧消息水合及缺失目标。新增长历史夹具分别验证 iOS 聊天搜索会话和服务端真实搜索处理函数可分页到 1,045 条不同命中，校验旧偏移 1001 被拒、类型和会话保真、末页终止和最早命中的准确定位参数。服务端只增 `code/server/internal/tenant/search_phase3_test.go` 测试，未改共享 API。聊天行展示在查询内按命中标识缓存，只计算新增或变化的内容。
- 测试用隔离 Keychain 适配器确认应用层读写，本地签名模拟器已通过真实 Keychain 适配器读写清除。用户确认真机性能后续交人工验收。设备锁定前后的 Keychain 行为和真实数据回归纳入同一人工清单。回退整个页面和历史批次，保留已验证的请求契约与输入批次。
- 额外挂载检查通过：1050 个会话下，实际会话列表打开全局搜索，输入期间列表全量投影 0 次，关闭后原列表及第 800 行锚点保留。实际聊天页打开历史搜索，输入期间聊天消息时间线重算 0 次。测试见 `BlueStoneIMTests/ChatHeaderStatusBoundaryTests.swift`，iOS 26.5 模拟器的结构计数，不替代真机 P95 和长帧率。

### 链接和附件消息发送人筛选

- `WDT_IOS1_SEARCH_LINK_FILTER_20261113` 与 `WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113`。仅服务端声明能力时展示两项筛选，逐页检查实际生效回显。链接查正文 HTTP(S) 链接。附件消息由实际发送人或转发人决定，命中定位到消息，不使用文件对象原上传者推断。接口按同一消息分页链发 `has_link=true` 或 `message_content=attachment`，保留 `from_uid`、日期和会话身份。
- 涉及 `BlueStoneIM/App/Chat{HistorySearchPage,ScreenComposition}.swift`、`BlueStoneIM/IMAPIProtocol.swift`、`BlueStoneIM/Core/Networking/IMAPIClient+Contacts.swift`、`BlueStoneIM/Core/AppSupport/AppState+SearchConversationSettings.swift`、`Sources/IM4Data/NetworkingDTO/SearchResponseWireModels.swift`、`Sources/IM4Features/Chat/ChatHistorySearch{Views,ResultPresentation}.swift` 及 `BlueStoneIMTests/ChatHeaderStatusBoundaryTests.swift`。回退按对应标识和共享 API 兼容面执行。
- 本地签名 iOS 模拟器通过 24 项定向测试，包含旧副本无回显拒绝、附件发送人在各页保留、同账号同企业切回后的迟到响应丢弃、真实 Keychain 适配器及已有分页、定位与 UI 入口。

### 搜索体验修订及日历可见性回修

- 累计补丁基线 `c1e9ac8da012228467760ae6cac45806214ebf2f`，原独审候选 `01ab77b153283527e8d7a213f83d44b9056bab45`，分支 `codex/ios1-chat-search-calendar`。回修见本索引所在提交，原体验改动见其祖先提交 `eb6246945`、`593eb14bc`、`9ce9bc470`、`01ab77b15`。
- `WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113`。输入和选历史词只编辑草稿，显式提交后才请求。移除逐字防抖发起、页面重现时自动发起以及旧词结果标签，保留已提交词的分类、续页和重试。
- `WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113`。调整搜索框、禁用态、最近搜索和失败卡片，输入组件保留其它调用方的默认占位样式。
- `WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113`。日期入口共用一套日历，从当前窗口及按会话、可见序号和日期范围筛选后的本机 SQLite 记录选锚点。移除聊天页的远端单日锚点请求、旧日期筛选控件及固定高度弹层。普通编辑更新搜索文案，日历可见性保留。撤回、删除和隐藏事件在 SQLite 每天选出首个候选前排除失效消息，日期与时区转换沿用本地公历。未同步日期保持不可选。
- 合并时须一起保留动作绑定、本机只读协调入口、日期锚点排除和 UI 回调。协调器的新增日期查询与 v5 出箱分别保留。本批未改数据库 schema、后端接口或部署入口。
- 专用 iOS 26.5 模拟器 32 项定向 XCTest 全部通过。新增回归覆盖唯一消息编辑后日期仍可选，以及 SQLite 旧日期首条撤回后跳到同日下一条。回执为同批验证目录的 `SearchCalendarVisibilityReview.xcresult` 和 `test-search-calendar-visibility-review.log`。

| 文件 | 标识行区间 |
| --- | --- |
| `BlueStoneIM/App/ChatHistorySearchPage.swift` | 聊天日历 17, 83, 114, 133–136, 148, 211–215, 242–296, 319–323, 332, 340, 349–354, 399–403, 458, 478, 514, 524–530, 651, 679–684, 695, 706–726, 732–735, 744–769, 805 |
| `BlueStoneIM/App/ChatScreenComposition.swift` | 聊天日历 531, 550–555 |
| `BlueStoneIM/Core/AppSupport/AppState+SearchConversationSettings.swift` | 聊天日历 458–491 |
| `BlueStoneIM/Core/Networking/DTO/RemoteSearchSyncModels.swift` | 聊天日历 49–62 |
| `BlueStoneIM/DesignSystem/CommonControlViews.swift` | 全局样式 12, 21, 29, 51–58 |
| `BlueStoneIM/Features/Conversations/ConversationListSearch.swift` | 手动提交 38, 85, 182, 192–196, 206–212, 243, 307–319, 325–332, 340, 350–354, 362, 381, 424–427, 457, 477, 484 / 全局样式 166–176, 199, 219–228, 254–302 |
| `BlueStoneIM/Features/Conversations/TenantGlobalSearchResults.swift` | 全局样式 245–309, 421–442 / 手动提交 320, 333 |
| `BlueStoneIM/MessagePersistenceCoordinator.swift` | 聊天日历 362–372 |
| `BlueStoneIMTests/ChatHeaderStatusBoundaryTests.swift` | 聊天日历 435–438, 728–833, 858 / 手动提交 465–475, 485–491 |
| `BlueStoneIMTests/DesignSystemTests.swift` | 聊天日历 455–458, 477–483 |
| `BlueStoneIMTests/MessageDatabaseSemanticsTests.swift` | 聊天日历 642–664 |
| `Sources/IM4Data/SQLiteMessageRepository+Projection.swift` | 聊天日历 137–170 |
| `Sources/IM4Domain/ChatMessageModels.swift` | 聊天日历 427–432 |
| `Sources/IM4Features/Chat/ChatHistorySearchViews.swift` | 聊天日历 7–19, 58–66, 72–77, 107, 119–180, 268–275, 370–415, 501–507, 546–551, 557–734, 746, 814–817, 831–834, 840–845 |

## iOS1 架构重构阶段 1 · API 模型首批拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，原 iOS1 tree `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 下列行号对应原 `BlueStoneIM/RemoteAPIModels.swift`。新文件位于 `BlueStoneIM/Core/Networking/DTO/`，继续编入 `BlueStoneIM` target。迁移时只补 `import Foundation`，保留声明正文、原有标识、访问控制和解析行为。

| 原文件区间 | 新文件 |
| --- | --- |
| 11549–11967 | `RemoteConversationModels.swift` |
| 12233–12499 | `RemoteMessageReceiptModels.swift` |
| 12500–13210 | `RemoteSearchResultModels.swift` |
| 13211–13652 | `RemoteSearchSyncModels.swift` |
| 14153–14416 | `RemoteStickerModels.swift` |

- 剩余 `RemoteAPIModels.swift` 为 12,312 行，保留为后续拆分批次。回退时整体反向应用本批提交，恢复原文件并移除对应 Xcode 登记。
- 新文件与原片段逐字节一致（不计新增 import 和文件末尾空行）。Swift 6 语法解析及工程文件 `plutil` 检查通过。用户要求在没有 iOS 15 真机的情况下继续，性能采样前置为 `PASSED_BY_USER`，iOS 15 运行与同身份升级待验证。
- Debug 模拟器 `build-for-testing` 通过，候选 App `MinimumOSVersion` 为 `15.0`。同一 iOS 26.5 模拟器对原始提交与候选各运行 11 个 XCTest，两轮均 10 个通过。唯一失败为既有的 `testAppStateVisibleQueuedReadDoesNotConsumeUnseenArrival`，两轮四处断言的实际值和期望值一致。构建、原始测试与候选测试证据位于 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 下的 `phase1-*-*.log` 和 `Phase1-*.xcresult`。


## iOS1 架构重构阶段 1 · API 模型剩余拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接首批 `00d47449e3fb24225d3331417693ee5048359393`。下列行号对应首批之后的 `BlueStoneIM/RemoteAPIModels.swift`。
- 共享编解码工具保留在 `RemoteAPIModels.swift`，其余分到 `BlueStoneIM/Core/Networking/DTO/`。在原 App target 内搬动声明，不调整访问控制。租户 Logo、准入辅助函数与所有调用方同文件，邀请审批响应及请求也保留在同文件。`CryptoKit` 的导入随 SHA-256 指纹实现迁移。

| 原文件区间 | 目标文件 |
| --- | --- |
| 3–466, 1531–1712, 5701–5728, 12218–12312 | `RemoteAPIModels.swift` |
| 467–914 | `RemoteBootstrapModels.swift` |
| 915–1277 | `RemoteAppPolicyModels.swift` |
| 1278–1493 | `RemoteLegalModels.swift` |
| 1781–1969, 2239–2510 | `RemoteDirectoryModels.swift` |
| 1970–2238, 4200–4276 | `RemoteAvatarUploadModels.swift` |
| 2511–2871 | `RemoteRTCConnectionModels.swift` |
| 2872–3199 | `RemoteRTCCallModels.swift` |
| 3200–3509 | `RemoteRTCMediaPolicyModels.swift` |
| 3510–3841 | `RemoteRTCSignalingModels.swift` |
| 3842–4199 | `RemoteRTCEventModels.swift` |
| 1494–1530, 4277–4538, 5218–5312 | `RemoteAuthChallengeModels.swift` |
| 4539–4818, 6991–7066 | `RemoteAuthSessionModels.swift` |
| 4819–5217, 5313–5554 | `RemoteLoginModels.swift` |
| 5555–5700, 5811–6105, 6529–6730, 7251–7342 | `RemoteTenantMembershipModels.swift` |
| 5729–5810, 6106–6528, 6731–6801, 7067–7250 | `RemoteWorkspaceAccessModels.swift` |
| 6802–6990, 8517–8699 | `RemoteInviteModels.swift` |
| 7343–7868, 11818–11821 | `RemoteAccountModels.swift` |
| 7869–8516 | `RemoteContactModels.swift` |
| 8700–9043 | `RemoteDeviceNotificationModels.swift` |
| 9044–9573 | `RemoteGroupProfileModels.swift` |
| 9574–10030 | `RemoteGroupLifecycleModels.swift` |
| 10031–10379 | `RemoteGroupMembershipModels.swift` |
| 10380–10706 | `RemoteFilePolicyModels.swift` |
| 10707–11253 | `RemoteFileModels.swift` |
| 11254–11548 | `RemoteGroupMutationModels.swift` |
| 1713–1780, 11549–11817, 11822–11874, 12130–12217 | `RemoteMessageModels.swift` |
| 11875–12129 | `RemoteMessageEventModels.swift` |

- 剩余共享文件为 770 行，新增 27 个文件均不超过 800 行。逐段核对所有原声明、注释和旧标识完整。工程仅增加新 Swift 文件登记，Swift 6 语法检查和 `plutil` 通过。回退时整体反向应用本批，恢复共享文件和工程登记。
- 原始候选在推送指纹测试中用 63 字符的期望比较真实 64 字符 SHA-256，独立计算确认实现输出与测试输入匹配。本批保持测试断言，按前后结果对照判定。
- Debug 模拟器构建通过，`MinimumOSVersion` 为 `15.0`。原始候选与本批在 iOS 26.5 各跑 15 项，均 14 项通过、同一项既有指纹断言失败，实际值和期望值完全一致。证据位于 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1b-*.log` 和 `Phase1b-*.xcresult`。


## iOS1 架构重构阶段 1 · 领域模型拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 API 模型拆分 `863c0452a`。行号对应改动前的 `BlueStoneIM/Models.swift`。
- 应用公共声明仍在 `Models.swift`，各领域声明移至 `BlueStoneIM/Domain/` 并继续编入同一 App target。会话解析器保持同文件，联系人搜索和私有数组去重实现保持同文件。UIKit/CryptoKit 的导入随开屏图模型及缓存实现迁移。

| 原文件区间 | 目标文件 |
| --- | --- |
| 10–258, 4606–4836 | `Models.swift` |
| 259–278, 514–523, 1116–1262, 1342–1552, 1813–1821 | `ChatMessageModels.swift` |
| 279–513 | `StickerMessageModels.swift` |
| 524–750 | `EnterpriseModels.swift` |
| 751–1115, 4271–4390 | `ContactModels.swift` |
| 5–9, 1263–1341, 2119–2230, 2516–2696 | `FileModels.swift` |
| 1553–1685 | `VoiceMessageModels.swift` |
| 1686–1812, 3933–4270 | `GroupModels.swift` |
| 1822–2118 | `ConversationModels.swift` |
| 2231–2515 | `FavoriteAssetModels.swift` |
| 2697–3165 | `SplashModels.swift` |
| 3166–3464 | `SplashSnapshotStore.swift` |
| 3465–3932 | `SplashImageCache.swift` |
| 4391–4605 | `CallModels.swift` |

- 原文件为 4,836 行，拆分后 `Models.swift` 482 行，新增 13 个文件，最长 486 行。逐段对照确认原声明、注释与标识完整，访问控制不变。工程差分只有 Swift 文件登记，Swift 6 语法检查和 `plutil` 通过。回退时整体反向应用本批，恢复原文件和工程登记。
- Debug 模拟器构建通过，`MinimumOSVersion` 为 `15.0`。改动前后在同一 iOS 26.5 模拟器各跑 12 项，均通过。证据位于 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1c-*.log` 和 `Phase1c-*.xcresult`。


## iOS1 架构重构阶段 1 · 设计系统拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `5f28bec63241e38b5333b8b02b8e5c09ce1ffe0d`。行号对应拆分前 `BlueStoneIM/DesignSystem.swift`。
- 通用颜色、未读文案和轻量样式扩展留在 `DesignSystem.swift`，其余移至 `BlueStoneIM/DesignSystem/`，仍属于原 App target。UIKit 手势安装和私有导航辅助函数保持同文件。SwiftUI 兼容分支、访问控制、组件尺寸及视觉常量均保持原样。

| 原文件区间 | 目标文件 |
| --- | --- |
| 581–599, 1109–1158 | `DesignSystem.swift` |
| 8–580 | `AvatarImagePipeline.swift` |
| 600–873, 2804–2830 | `SwiftUICompatibility.swift` |
| 874–1108 | `PhotoLibraryPickerCompat.swift` |
| 1159–1323 | `AuthBackgroundViews.swift` |
| 1324–1792, 2182–2243 | `AvatarViews.swift` |
| 1793–1958, 2118–2181, 2244–2478 | `CommonControlViews.swift` |
| 1959–2117 | `GroupInviteApprovalCard.swift` |
| 2479–2803 | `NavigationGestureInstallers.swift` |

- 原文件 2,830 行，拆分后 72 行，新增 8 个文件，最长 577 行。逐段对照保留全部声明、注释及标识。仅调整文件导入和 Xcode 源码登记。回退时整体反向应用本批。
- Debug 模拟器构建通过，`MinimumOSVersion` 为 `15.0`。同一 iOS 26.5 模拟器前后各跑 12 项图像、导航、兼容及控件测试，全部通过。证据位于 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1d-*.log` 和 `Phase1d-*.xcresult`。


## iOS1 架构重构阶段 1 · 文件和通话视图拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `83a555b90190bc3a13c6efb10731aa8ea8fce799`。行号对应拆分前 `BlueStoneIM/FilesRTCViews.swift`，目标均在原 `BlueStoneIM` target。
- 通话入口、语音及视频选择和通话记录详情保持同文件。文件列表、预览、缓存与系统预览加载迁至 `Features/Files/`，通话记录行和通话界面迁至 `Features/Calls/`。

| 原文件区间 | 目标文件 |
| --- | --- |
| 2426–2778, 2883–3272 | `FilesRTCViews.swift` |
| 6–731 | `Features/Files/FilesView.swift` |
| 732–1070 | `Features/Files/FileListSupportViews.swift` |
| 1071–1647 | `Features/Files/FilePreviewViews.swift` |
| 1648–1693, 1956–1990 | `Features/Files/QuickLookAndFileShareViews.swift` |
| 1694–1955 | `Features/Files/FilesPreviewCacheAdapter.swift` |
| 1991–2150 | `Features/Files/SystemPreviewLoader.swift` |
| 2151–2425 | `Features/Files/FileVisualPresentation.swift` |
| 2779–2882 | `Features/Calls/RTCCallRecordRow.swift` |
| 3273–3715 | `Features/Calls/CallScreenViews.swift` |

- 原文件 3,715 行，拆分后 747 行，新增 9 个文件。除跨文件调用所需的 10 个声明从 `private` 改为模块内可见，原代码、注释及标识逐段一致。可见性调整仅涉及 `FileRefreshHintView`、`FileLoadMoreFooter`、`FavoriteAssetRenderItem`、`FilePreviewOpenState`、`FilePresentation`、`FavoriteAssetRow`、`FileThumbnail`、`LocalPreviewDocument`、`RTCCallRecordRow` 和 `RTCIncomingCallCard`。
- `WDT_IOS1_REFACTOR_FILES_RTC_VIEWS_20261109` 标记现有源码检查的路径迁移。在线状态检查仍覆盖原文件及其全部拆分文件，来电无障碍检查读取新的实际界面文件，断言保持原样。
- Swift 6 语法解析及 `plutil` 通过。既有 RTC 源码 smoke 在前后均因同一 `videoCallUnavailableReason(for: user)` 字面检查失败，脚本保持原样。回退时整体反向应用本批，恢复文件、Xcode 登记及测试路径。
- Debug 模拟器构建通过，`MinimumOSVersion` 为 `15.0`。同一 iOS 26.5 模拟器前后各跑 12 项文件预览、作用域迁移、通话入口和源码约束测试，全部通过。证据位于 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1e-*.log` 和 `Phase1e-*.xcresult`。


## iOS1 架构重构阶段 1 · 个人页和设置视图拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `6b52e71150f80da9723edfdf8c87c5ef8376fce6`。行号对应拆分前 `BlueStoneIM/MeSettingsViews.swift`，目标仍在原 `BlueStoneIM` target。
- 个人页入口、路由及个人页专用控件留在原文件。其余视图迁至 `Features/Me/`，原安全设置辅助控件与调用方同文件。

| 原文件区间 | 目标文件 |
| --- | --- |
| 6–605, 967–987 | `MeSettingsViews.swift` |
| 606–966 | `Features/Me/AccountInfoViews.swift` |
| 988–1696 | `Features/Me/ProfileEditViews.swift` |
| 1697–1967 | `Features/Me/EnterpriseSwitcherView.swift` |
| 1968–2061 | `Features/Me/NotificationSettingsView.swift` |
| 2062–2157, 2518–2944 | `Features/Me/SecuritySettingsViews.swift` |
| 2158–2300, 2973–3054 | `Features/Me/PhoneBindingFlowView.swift` |
| 2301–2517, 2945–2972 | `Features/Me/RealNameVerificationViews.swift` |
| 3055–3103 | `Features/Me/DeviceSessionsView.swift` |
| 3104–3284 | `Features/Me/InboxCenterViews.swift` |

- 原文件 3,284 行，拆分后 625 行，新增 9 个文件，最长 713 行。仅 `AboutJianHuiTongView`、`ContactUsView`、`AccountCancellationView`、`NicknameEditSheet`、`UsernameEditSheet`、`AvatarEditSheet` 和 `settingsPhoneDisplayText` 从 `private` 改为模块内可见，以保留跨文件调用。其余代码、注释和标识逐段一致。
- `WDT_IOS1_REFACTOR_ME_SETTINGS_VIEWS_20261109` 标记现有测试的源码路径迁移。在线状态检查覆盖原文件及全部拆分文件，通知设置与企业选择文案检查读取实际视图。回退时整体反向应用本批，恢复源码、Xcode 登记及测试路径。
- Debug 模拟器构建通过，`MinimumOSVersion` 为 `15.0`。同一 iOS 26.5 模拟器前后各跑 12 项，11 项通过，均只有企业码文案检查中要求未改动的 `AppState.swift` 包含固定文案的旧断言失败。源码路径变更后的其它断言通过，基线断言未修改。证据位于 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1f-*.log` 和 `Phase1f-*.xcresult`。


## iOS1 架构重构阶段 1 · 登录与注册视图拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `be12887d64a5e00aeadcfb58d16418d2c7378b74`。行号对应拆分前 `BlueStoneIM/AuthViews.swift`，目标仍在原 `BlueStoneIM` target。
- 登录入口留在原文件，表单、验证码、法律文档、企业选择和记住登录信息按职责迁至 `Features/Auth/`。Keychain 实现、作用域键及凭据访问控制保留在同一文件。

| 原文件区间 | 目标文件 |
| --- | --- |
| 6–400, 584–766 | `AuthViews.swift` |
| 401–583 | `Features/Auth/AuthCaptchaViews.swift` |
| 767–1305 | `Features/Auth/RememberedLoginCredentials.swift` |
| 1306–1644 | `Features/Auth/AuthFormControls.swift` |
| 1645–2425 | `Features/Auth/AuthFlipView.swift` |
| 2426–2860 | `Features/Auth/AuthLegalViews.swift` |
| 2861–3033, 3847–3927 | `Features/Auth/AuthWorkspaceViews.swift` |
| 3034–3700 | `Features/Auth/LoginRegisterViews.swift` |
| 3701–3846 | `Features/Auth/ForgotPasswordView.swift` |

- 原文件 3,927 行，拆分后 582 行，新增 8 个文件，最长 785 行。仅跨文件调用所需的 17 个声明改为模块内可见。调整项为 `AuthBrandLockup`、`dismissAuthKeyboard`、`AuthInputField`、`isCompleteAuthMainlandPhone`、`AuthFormInputStyle`、`AuthFormInput`、`OptionalAccessibilityIdentifier`、`RememberLoginCredentialsRow`、`FlipOpacity`、表单专用 `View` 扩展、`ScrollContentHeightKey`、`ScrollOffsetKey`、`LoginContentHeightKey`、`AuthPage`、`LoginWorkspaceSelectionView`、`AuthModeSwitch` 和 `PasswordRequirementHint`。其它代码、注释及标识逐段一致。
- `WDT_IOS1_REFACTOR_AUTH_VIEWS_20261109` 标记注册企业码占位文案断言的源码路径迁移。现有登录文案和 `AppState.swift` 断言保留。回退时整体反向应用本批，恢复源码、Xcode 登记及测试路径。
- Debug arm64 模拟器构建通过，`MinimumOSVersion` 为 `15.0`。同一 iOS 26.5 模拟器配置前后各跑 12 项，均为 10 项通过及同样两项失败。企业码固定文案断言指向未改动的 `AppState.swift`。系统 Keychain 用例在未签名测试宿主上缺少受保护写入权限，依赖注入的凭据作用域、写入失败、清理重试及重登用例通过。证据位于 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1g-*.log` 与 `phase1g-*.xcresult`。


## iOS1 架构重构阶段 1 · 会话列表拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `1c153b46747e88c8526449468215e34c392151d9`。行号对应拆分前 `BlueStoneIM/ConversationViews.swift`。同一 App target 内搬动会话列表、搜索、提及、行展示、快捷入口和 UITableView 复用。
- 原 `ConversationListView` 持有全部存储属性。搜索、提及及缓存的方法原样移入三个同类型扩展。逐段校验源码，除新增 import、扩展边界和为保留跨文件调用调整的 78 处可见性外，非空行逐字一致。Xcode 工程仅新增十个文件的源码登记。

| 原文件区间 | 目标文件 |
| --- | --- |
| 186–301, 396–811, 1060–1076, 1842–1843, 2561–2568 | `ConversationViews.swift` |
| 4–177 | `Features/Conversations/ConversationListTime.swift` |
| 302–307, 364–395, 1189–1726 | `Features/Conversations/ConversationListRenderCache.swift` |
| 812–1059, 178–185, 1844–2268 | `Features/Conversations/ConversationListSearch.swift` |
| 308–363, 1077–1188, 1727–1841, 2569–2728, 4287–4340 | `Features/Conversations/ConversationListMentions.swift` |
| 2269–2560 | `Features/Conversations/ConversationListProjection.swift` |
| 2729–3013, 4091–4286 | `Features/Conversations/ConversationListRows.swift` |
| 3014–3030, 3097–3641 | `Features/Conversations/QuickAddViews.swift` |
| 3031–3096, 3998–4090 | `Features/Conversations/ConversationListHeaderViews.swift` |
| 3642–3997 | `Features/Conversations/FindUserSheet.swift` |
| 4341–4635 | `Features/Conversations/RecycledConversationTable.swift` |

- 原文件 4,635 行，拆分后 561 行，新增 10 个文件，最长 685 行。`WDT_IOS1_REFACTOR_CONVERSATION_VIEWS_20261109` 标记现有测试读取实际源码的路径。备注检查分别读取搜索、快捷入口和会话行，在线状态检查仍覆盖原文件及全部拆分文件。回退时整体反向应用本批，恢复源码、Xcode 登记与测试路径。
- Debug arm64 模拟器编译通过，`MinimumOSVersion` 为 `15.0`。同一 iOS 26.5 模拟器前后各 13 项，均为 11 项通过，千会话拖拽期间重建及备注源码检查出现同样的旧断言失败。千会话初始画面截图为 1170×2532，逐像素差异为 0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1h-*.log`、`phase1h-*.xcresult` 及截图附件。


## iOS1 架构重构阶段 1 · 聊天搜索和弹层首批拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `54604c07647f8c04d70d2a06fb7f3c985d241ec5`。行号对应拆分前 `BlueStoneIM/ChatViews.swift`，目标仍在原 `BlueStoneIM` target。

| 原文件区间 | 目标文件 |
| --- | --- |
| 6451–7099 | `Features/Chat/ChatHistorySearchViews.swift` |
| 7282–7817 | `Features/Chat/ChatConversationSheets.swift` |
| 11740–11789, 14084–14308 | `Features/Chat/ReactionPickerView.swift` |
| 15721–15986, 16429–16499 | `Features/Chat/ReadReceiptSheet.swift` |
| 15987–16384 | `Features/Chat/MessageActionSheets.swift` |

- 逐行核对原代码及标记。可见性调整仅为 `ChatHistorySearchPanel`、`PinnedMessagesSheet`、`EmojiPickerRuntimeContext`、`currentEmojiPickerRuntimeContext` 和 `emojiPickerRuntimeTaskKey`。新文件最长 651 行，`ChatViews.swift` 仍有 14,433 行，继续拆分。
- `WDT_IOS1_REFACTOR_CHAT_SHEETS_20261109` 标记现有测试源码路径迁移。备注检查读取实际回执视图源码，在线状态检查仍覆盖所有拆分文件。回退时整体反向应用本批。
- Debug arm64 构建通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 前后各跑 12 项，基线 10 项通过，候选 11 项通过。备注源码检查的六条旧断言相同。原始版本回执请求数为 2，期望为 1，候选本次通过，回执请求路径和断言均未修改。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1i-*.log` 及 `phase1i-*.xcresult`。


## iOS1 架构重构阶段 1 · 聊天附件视图拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `1fbe416ac4dd036008a19567bc72ca2e57116030`。行号对应拆分前 `BlueStoneIM/ChatViews.swift`。三个文件继续编入原 App target。

| 原文件区间 | 目标文件 |
| --- | --- |
| 12270–12624 | `Features/Chat/ChatAttachmentSelection.swift` |
| 12849–13299, 14174–14217 | `Features/Chat/ChatAttachmentPreview.swift` |
| 13726–14173, 14218–14260 | `Features/Chat/ChatAttachmentDetail.swift` |

- 原声明、注释及标记逐行一致，除所需 import 及跨文件调用的 11 处可见性调整。调整项为 `AttachmentSendConfirmationSheet`、`PendingAttachmentSelection`、`PendingAttachmentSelectionBatch`、`AttachmentActivityView`、`AttachmentMediaPreviewItem`、`AttachmentPhotoLibrarySaver`、`AttachmentPhotoLibrarySaveResult`、`AttachmentShareItem`、`AttachmentLocalPreviewDocument`、`AttachmentQuickLookPreview` 和 `AttachmentGIFImage`。新文件最长 500 行，`ChatViews.swift` 剩 13,092 行。
- `WDT_IOS1_REFACTOR_CHAT_ATTACHMENTS_20261109` 标记现有预览、GIF 保存和在线状态源码检查的路径迁移。回退时整体反向应用本批。
- Debug arm64 编译通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 目标的 10 项附件与源码约束用例前后全过。额外复跑的回执请求数用例在本批基线失败、候选通过。该基线制品即上批通过同一回执测试的候选制品，确认用例结果会在同一构建上变化。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1j-*.log` 和 `phase1j-*.xcresult`。


## iOS1 架构重构阶段 1 · 聊天输入控件和语音录制拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `db366241e65265ca492fb25037801b59a15a235b`。行号对应拆分前 `BlueStoneIM/ChatViews.swift`。目标仍在原 App target。

| 原文件区间 | 目标文件 |
| --- | --- |
| 9555–9766 | `Features/Chat/ChatComposerInputViews.swift` |
| 9767–10261 | `Features/Chat/ChatVoiceRecordingControllers.swift` |
| 10262–10504 | `Features/Chat/ChatVoiceRecordingViews.swift` |

- 除必要导入及 10 处跨文件可见性调整，搬移的声明、注释和旧标记逐行一致。可见性调整为 `ComposerInputBox`、`VoiceMessagePreviewController`、`VoiceMessageRecorderController`、`VoiceMessageRecorderError`、`VoiceMessageRecording`、`VoiceRecordPad`、`VoiceRecordingFeedbackPanel`、`VoiceRecordingOverlay`、`VoiceRecordingPreviewPanel` 和 `VoiceWaveformBars`。原文件剩 12,142 行。
- `WDT_IOS1_REFACTOR_CHAT_VOICE_INPUT_20261109` 标记输入代理和在线状态源码检查的路径迁移。回退时整体反向应用本批。
- Debug arm64 编译通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 模拟器前后各 10 项全过，覆盖录音状态、草稿及键盘、输入工具无障碍。深色 RTL 最大无障碍字号工具栏截图为 960×1620，逐像素差异为 0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1k-*.log` 及 `phase1k-*.xcresult`。


## iOS1 架构重构阶段 1 · 聊天输入区主体、操作及面板拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `348062b600065e8f14aa152b5a5e9ff516c0a185`。行号对应拆分前 `BlueStoneIM/ChatViews.swift`。目标仍在原 App target。

| 原文件区间 | 目标文件 |
| --- | --- |
| 9605–9784, 9983–10441, 10828–10829, 11434–11443 | `Features/Chat/ChatComposer.swift` |
| 9785–9982, 10442–10827 | `Features/Chat/ChatComposerActions.swift` |
| 10830–11433, 11444–11543 | `Features/Chat/ChatComposerPanels.swift` |

- 存储属性和输入区构建体留在 `ChatComposer` 主体，操作方法移到同类型扩展。1,939 行搬移经逐行复核，除 import、扩展边界和 55 个跨文件声明可见性调整，原代码、注释及旧标记一致。新文件最长 706 行，`ChatViews.swift` 剩 10,203 行。
- `WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109` 标记现有测试及本地源码 smoke 的路径迁移。表情面板的字面判断继续检查迁移后的同一语句。回退时整体反向应用本批。
- Debug arm64 模拟器编译通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 前后各 11 项，均 9 项通过；备注源码与贴纸的 `AppState.swift` 字面断言为同一组旧失败，备注报错中搬移后的类型访问修饰符更新。工具栏截图 960×1620 逐像素一致。源码 smoke 在前后均于未改动的 AppState 路径报 `missing func logout()`。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1l-*.log` 和 `phase1l-*.xcresult`。


## iOS1 架构重构阶段 1 · 消息气泡、缩略图和转发拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `735a7c55607c18cdaca530e15b9858863b42cf79`。行号对应拆分前 `BlueStoneIM/ChatViews.swift`。目标仍在原 App target。

| 原文件区间 | 目标文件 |
| --- | --- |
| 6633–6858, 7599–7780 | `Features/Chat/ChatBubbleTextViews.swift` |
| 6859–7598 | `Features/Chat/MessageBubble.swift` |
| 8783–8916 | `Features/Chat/ChatBubbleMetadataViews.swift` |
| 7781–8384 | `Features/Chat/ChatMediaBubbleViews.swift` |
| 894–958, 8385–8782, 10075–10203 | `Features/Chat/ChatAttachmentThumbnailViews.swift` |
| 8917–9554 | `Features/Chat/ChatMessageActionViews.swift` |
| 9555–10030 | `Features/Chat/ChatForwardViews.swift` |

- 搬移 3,592 行，除导入、20 处必要可见性调整及文件末尾空行，逐行一致。缩略图与滚动暂停状态及环境键同文件。新文件最长 742 行，原文件剩 6,610 行。
- `WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109` 标记现有测试的源码读取路径，在线状态检查仍覆盖全部拆分文件。回退时整体反向应用本批。
- Debug arm64 构建通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 前后各 12 项，均为 7 项通过、5 项原有失败。失败项为批量转发行的源码签名、缩略图准入顺序、语音不可转发文案、备注源码和贴纸路径，断言一致。缩略图断言的源码偏移随搬移改变，顺序结果一致。3 张单聊标题与 4 张群禁言横幅的 960×1920 截图逐像素一致。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1m-*.log` 和 `phase1m-*.xcresult`。


## iOS1 架构重构阶段 1 · 聊天滚动与时间线辅助声明拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `2006290ff6a26f5b08ec1daf3ff7757a11e5708d`。行号对应拆分前 `BlueStoneIM/ChatViews.swift`。目标仍在原 App target。

| 原文件区间 | 目标文件 |
| --- | --- |
| 88–221, 289–570, 975–1030 | `Features/Chat/ChatScrollPolicies.swift` |
| 571–974, 6007–6033 | `Features/Chat/ChatScrollMeasurements.swift` |
| 222–288, 5872–6006 | `Features/Chat/ChatTimelineProjection.swift` |
| 1035–1110, 6034–6351 | `Features/Chat/ChatIdentityPresentation.swift` |
| 5812–5831, 6352–6567 | `Features/Chat/ChatHistorySupportViews.swift` |

- 搬移 1,735 行，除必要导入及 21 处跨文件可见性调整，原代码、注释和旧标记逐行一致。新文件最长 474 行，原文件剩 4,875 行，后续拆分 `ChatView` 主体方法。
- `WDT_IOS1_REFACTOR_CHAT_SCROLL_SUPPORT_20261109` 标记现有源码检查的路径迁移，在线状态检查仍覆盖所有拆分文件。回退时整体反向应用本批。
- Debug arm64 构建通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 前后各 12 项，均 11 项通过及同一回底按钮源码用例失败，三条旧断言一致。7 张 960×1920 聊天页截图逐像素一致。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1n-*.log` 和 `phase1n-*.xcresult`。


## iOS1 架构重构阶段 1 · ChatView 主体拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `269ea3260f65469b6d729810a5d1fa675eb3c26b`。行号对应拆分前 `BlueStoneIM/ChatViews.swift`。存储属性和 `body` 保持在主类型，下面的方法搬到同一 App target 内的 `ChatView` 扩展。

| 原文件区间 | 目标文件 |
| --- | --- |
| 345–609, 756–773, 790–802, 1003–1108 | `Features/Chat/ChatViewHeaderAndStatus.swift` |
| 803–1002 | `Features/Chat/ChatViewAttachmentActions.swift` |
| 1109–1171 | `Features/Chat/ChatViewDiagnostics.swift` |
| 1243–1971 | `Features/Chat/ChatViewLayout.swift` |
| 1972–2557, 2895–2978, 4786–4790 | `Features/Chat/ChatViewTimeline.swift` |
| 1172–1226, 2558–2578, 3360–3715 | `Features/Chat/ChatViewNavigation.swift` |
| 610–755, 774–789, 2579–2894 | `Features/Chat/ChatViewHistory.swift` |
| 2979–3359 | `Features/Chat/ChatViewRenderCache.swift` |
| 3716–3939 | `Features/Chat/ChatViewReply.swift` |
| 3940–4614 | `Features/Chat/ChatViewScrollPosition.swift` |
| 4615–4785 | `Features/Chat/ChatViewReadAcknowledgement.swift` |

- 逐行对照 4,430 行，除 import、扩展边界与 267 处模块内跨文件可见性调整，原代码、注释及旧标记一致。原文件剩 445 行，新文件最长 734 行。布局构建体原样搬移。
- `WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109` 标记原有测试源码读取路径迁移。回退时整体反向应用本批。
- Debug arm64 构建通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 模拟器前后各 14 项，均为 11 项通过，批量转发行和两个回底源码用例复现相同旧失败。7 张 960×1920 聊天页截图逐像素一致。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1o-*.log` 与 `phase1o-*.xcresult`。


## iOS1 架构重构阶段 1 · 会话存储按职责拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `ec97d2fd8beffd7efcac2a4a959cdb8a2d887985`。行号对应拆分前 `BlueStoneIM/ConversationStore.swift`。存储属性、发布入口、附件进度节流、查找索引和 reset 保留在主类型，下列声明移到同一 App target 的 `ConversationStore` 扩展。

| 原文件区间 | 目标文件 |
| --- | --- |
| 422–699, 705–755, 816–1000 | `Stores/ConversationStore+Types.swift` |
| 1165–1694, 3650–3676, 4779–4815, 5277–5362 | `Stores/ConversationStore+Lifecycle.swift` |
| 1017–1164, 3217–3537, 3773–3814, 4132–4156, 5253–5276, 5363–5414 | `Stores/ConversationStore+History.swift` |
| 1725–1755, 1875–2060, 2098–2462 | `Stores/ConversationStore+LocalMessages.swift` |
| 1756–1874, 2608–2776 | `Stores/ConversationStore+HistoryMerge.swift` |
| 1695–1724, 2463–2607, 2777–3216, 4816–4909 | `Stores/ConversationStore+RemoteMerge.swift` |
| 756–815, 3538–3649, 3677–3772, 4157–4161, 4910–5252 | `Stores/ConversationStore+ReadState.swift` |
| 3815–4131, 4587–4778 | `Stores/ConversationStore+MessageExtras.swift` |
| 700–704, 4162–4586 | `Stores/ConversationStore+Sync.swift` |

- 逐行对照 4,940 行，除导入、扩展边界与 36 处跨文件可见性调整，原代码、注释与旧标记一致。`ReadAckSyncClaim` 与代次构造、校验函数留在同一文件，保留 `fileprivate`。未读总数的 `private(set)` 与发布路径原样保留。原文件剩 543 行，新文件最长 713 行。回退时整体反向应用本批。
- Debug arm64 构建通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 模拟器前后各 16 项全部通过，覆盖消息合并、分页边界、实时通话记录去重、已读水位、回执和通知发布。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1p-*.log` 与 `phase1p-*.xcresult`。


## iOS1 架构重构阶段 1 · AppState 订阅和展示辅助方法拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `0f4887c61b85b0e2e842d64a56723c7b90f6ee21`。行号对应拆分前 `BlueStoneIM/AppState.swift`。目标仍在原 App target。

| 原文件区间 | 目标文件 |
| --- | --- |
| 863–939, 1758–1816 | `Core/AppSupport/AppState+AvatarRouting.swift` |
| 940–1187 | `Core/AppSupport/AppState+AccessDiagnosticsRuntime.swift` |
| 1297–1757 | `Core/AppSupport/AppState+PresentationPolicy.swift` |
| 2129–2188 | `Core/AppSupport/AppState+RuntimeBindings.swift` |
| 2079–2128, 2309–2342 | `Core/AppSupport/AppState+ColdLaunchSessionRestore.swift` |

- 逐行核对 989 行，除导入、扩展边界与 10 处跨文件可见性调整，原代码、注释与标记一致。五个 Store 的观察转发保持原样。实时连接配置和 `mediaNetworkRecoveryGeneration` 保留同文件，保持 `private(set)`。新文件最长 466 行，主文件仍有 1,438 行，保留存储属性和初始化。主文件的字段拆分继续由阶段 2 的观察范围迁移处理。回退时整体反向应用本批。
- Debug arm64 构建通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 模拟器前后各 12 项均通过，覆盖启动会话恢复、应用策略、诊断入口、头像路由和会话恢复。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1q-*.log` 与 `phase1q-*.xcresult`。


## iOS1 架构重构阶段 1 · 通讯录、资料及群管理视图拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `fbb92ea581025703d1ba7ff10c6a95de53c01160`。行号对应拆分前 `BlueStoneIM/ContactsViews.swift`，目标仍在原 App target。通讯录入口和目录投影留在主文件。

| 原文件区间 | 目标文件 |
| --- | --- |
| 794–1430 | `Features/Contacts/ContactDirectoryTable.swift` |
| 1431–1601 | `Features/Contacts/ContactSearchViews.swift` |
| 1602–1915 | `Features/Contacts/OrganizationDirectoryViews.swift` |
| 1916–2399 | `Features/Contacts/DepartmentManagementSheets.swift` |
| 2400–2505, 7482–7536 | `Features/Contacts/ContactCommonRows.swift` |
| 2506–2759 | `Features/Contacts/ContactGroupList.swift` |
| 2760–2931 | `Features/Contacts/ContactRelationshipViews.swift` |
| 2932–3308, 3453–3717 | `Features/Contacts/ContactUserProfile.swift` |
| 3309–3452 | `Features/Contacts/ContactAvatarPreview.swift` |
| 3718–4241 | `Features/Contacts/ContactGroupDetail.swift` |
| 4242–4805 | `Features/Contacts/GroupSettingsAndLifecycleSheets.swift` |
| 4806–5266 | `Features/Contacts/GroupProfileEditSheets.swift` |
| 5267–6016 | `Features/Contacts/GroupMemberManagementViews.swift` |
| 6017–6322 | `Features/Contacts/GroupSharingViews.swift` |
| 6323–6660 | `Features/Contacts/GroupMuteListViews.swift` |
| 6661–7205 | `Features/Contacts/GroupModerationSettingsViews.swift` |
| 7206–7481 | `Features/Contacts/GroupHistoryScreenshots.swift` |

- 逐行对照 6,743 行，除 import、末尾空行与 24 处跨文件可见性调整，原代码、注释及旧标记一致。主文件剩 792 行，新文件最长 752 行。UIKit 表格和控制器保留同文件。
- `WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110` 标记测试源码路径迁移。备注检查限定在对应行的实现，避免误匹配共享行。回退时整体反向应用本批。
- Debug arm64 构建通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 前后 11 项均为 10 项通过，长列表复用与资料打开、头像预览、群目录刷新、群生命周期均通过。备注源码用例仍有原有失败，目录行诊断标识随声明定位更新。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1r-*.log` 与 `phase1r-*.xcresult`。


## iOS1 架构重构阶段 1 · 通话状态与媒体编排拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `eb7d566e85fab5e0789fc5a6de24d14f04d3586e`。行号对应拆分前 `Core/AppSupport/Calls/AppState+VoiceCalls.swift`。通话所有权留在主文件，下列方法仍在同一 App target 的 `AppState` 扩展。

| 原文件区间 | 目标文件 |
| --- | --- |
| 658–1355 | `Core/AppSupport/Calls/AppState+CallSystemEvents.swift` |
| 1356–1793 | `Core/AppSupport/Calls/AppState+RTCTerminalCompensation.swift` |
| 1794–2271 | `Core/AppSupport/Calls/AppState+IncomingVoiceCalls.swift` |
| 2272–2895 | `Core/AppSupport/Calls/AppState+OutgoingVideoCalls.swift` |
| 2896–3307 | `Core/AppSupport/Calls/AppState+IncomingVideoCalls.swift` |
| 3308–3610 | `Core/AppSupport/Calls/AppState+OutgoingVoiceCalls.swift` |
| 3611–4183 | `Core/AppSupport/Calls/AppState+VoiceMediaSession.swift` |
| 4184–4604 | `Core/AppSupport/Calls/AppState+RTCPeerMediaCoordination.swift` |
| 4605–5040 | `Core/AppSupport/Calls/AppState+RTCMediaHeartbeat.swift` |
| 5041–5697 | `Core/AppSupport/Calls/AppState+VideoMediaSession.swift` |
| 5698–6293 | `Core/AppSupport/Calls/AppState+ActiveCallActions.swift` |
| 6294–6766 | `Core/AppSupport/Calls/AppState+RTCCallEvents.swift` |
| 6767–7229 | `Core/AppSupport/Calls/AppState+RTCCallReconciliation.swift` |
| 7230–7777 | `Core/AppSupport/Calls/AppState+RTCCallHistory.swift` |
| 7778–8176 | `Core/AppSupport/Calls/AppState+RTCPeerPresentation.swift` |

- 逐行对照 7,519 行，除导入、扩展边界与 103 处跨文件可见性调整，声明内容、注释和旧标记一致。原文件 658 行，新文件最长 714 行。Xcode 文件引用相对原 Calls 组。回退时整体反向应用本批。
- Debug arm64 构建通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 前后各 14 项完成，均为 12 项通过及同两项原有断言失败。另一个租约续期用例在基线和候选上均复现同样四条断言及数组越界。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1s-*.log` 和 `phase1s-*.xcresult`，以及 `docs/REFACTOR_FINDINGS.md`。


## iOS1 架构重构阶段 1 · 远端注册和快照同步拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `51dee48e9bd3c168341cdca06d727b008ef8593e`。行号对应拆分前 `Core/AppSupport/RemoteSync/AppState+RemoteRegistrationSnapshotSync.swift`。原文件保留注册提交和确认轮询，下列方法留在同一 App target 的 `AppState` 扩展。

| 原文件区间 | 目标文件 |
| --- | --- |
| 705–1371 | `Core/AppSupport/RemoteSync/AppState+RegistrationResolution.swift` |
| 1372–1709 | `Core/AppSupport/RemoteSync/AppState+PrimarySnapshotSync.swift` |
| 1710–2460 | `Core/AppSupport/RemoteSync/AppState+StoredSessionRefresh.swift` |
| 2461–2732, 3130–3148 | `Core/AppSupport/RemoteSync/AppState+SecondarySnapshotSync.swift` |
| 2733–3129, 5874–5931 | `Core/AppSupport/RemoteSync/AppState+OrganizationDirectorySync.swift` |
| 3149–3704 | `Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift` |
| 3705–4123 | `Core/AppSupport/RemoteSync/AppState+CertificationRefresh.swift` |
| 4124–4805 | `Core/AppSupport/RemoteSync/AppState+AvatarRealtimeAuthority.swift` |
| 4806–5042 | `Core/AppSupport/RemoteSync/AppState+ProfileContactProjection.swift` |
| 5043–5348 | `Core/AppSupport/RemoteSync/AppState+LocalMessageScope.swift` |
| 5349–5873 | `Core/AppSupport/RemoteSync/AppState+ProfileAndTenantAuthority.swift` |
| 5932–6194 | `Core/AppSupport/RemoteSync/AppState+CachedRemoteSnapshot.swift` |
| 6195–6825 | `Core/AppSupport/RemoteSync/AppState+SnapshotPersistence.swift` |
| 6826–7318 | `Core/AppSupport/RemoteSync/AppState+RemoteFailurePresentation.swift` |
| 7319–7920 | `Core/AppSupport/RemoteSync/AppState+WorkspaceAccessErrors.swift` |

- 逐行对照 7,216 行，除导入、扩展边界与 37 处跨文件可见性调整，声明内容、注释与旧标记一致。原文件 705 行，新文件最长 767 行。Xcode 文件引用相对原 RemoteSync 组。回退时整体反向应用本批。
- Debug arm64 构建通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 前后各 14 项全过，覆盖分页换票、重试预算、本地消息读取、租户隔离、注册确认和用户资料权威。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1t-*.log` 和 `phase1t-*.xcresult`。阶段 0 的模拟器制品身份记录在 `docs/perf/identity-20261109.md`。


## iOS1 架构重构阶段 1 · 认证、资料和工作台拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `3ddb3813fd59d4ef311a7f18cb13b6660da77bbb`。行号对应拆分前 `Core/AppSupport/AccountSession/AppState+AuthenticationProfileWorkspace.swift`。原文件保留会话重认证等入口，下列方法移到同一 App target 的 `AppState` 扩展。

| 原文件区间 | 目标文件 |
| --- | --- |
| 403–912, 5310–5321 | `Core/AppSupport/AccountSession/AppState+AppPolicyAndLegal.swift` |
| 913–1343 | `Core/AppSupport/AccountSession/AppState+PreAuthEnterpriseContext.swift` |
| 1344–1868 | `Core/AppSupport/AccountSession/AppState+RememberedLoginAndEntry.swift` |
| 1869–2251 | `Core/AppSupport/AccountSession/AppState+LoginTransportAndWorkspace.swift` |
| 2252–2427 | `Core/AppSupport/AccountSession/AppState+RegistrationAndRecoveryUI.swift` |
| 2428–2546 | `Core/AppSupport/AccountSession/AppState+ProtectedContentAccess.swift` |
| 2547–3227 | `Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift` |
| 3228–3583 | `Core/AppSupport/AccountSession/AppState+WorkspaceSelection.swift` |
| 3584–4128 | `Core/AppSupport/AccountSession/AppState+CurrentProfileEditing.swift` |
| 4129–4509, 5290–5309 | `Core/AppSupport/AccountSession/AppState+GroupProfileEditing.swift` |
| 4510–4977 | `Core/AppSupport/AccountSession/AppState+PhoneBinding.swift` |
| 4978–5287 | `Core/AppSupport/AccountSession/AppState+EnterpriseMembership.swift` |

- 逐行对照 4,917 行，除导入、扩展边界、空行与 31 处跨文件可见性调整，声明、注释和旧标记一致。两个文件私有扩展随调用者搬移，保持私有。原文件 403 行，新文件最长 697 行。Xcode 引用相对原 AccountSession 组。回退时整体反向应用本批。
- Debug arm64 构建通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 前后各 14 项，均 13 项通过及同一工作台刷新过期令牌用例失败，三条断言一致。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1u-*.log` 和 `phase1u-*.xcresult`。


## iOS1 架构重构阶段 1 · 发送、附件、实时与消息映射拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `80371dc9f78831adc978acac10c35d2e0b1306cd`。行号对应 `Core/AppSupport/` 下拆分前文件。下列方法仍在原 App target 的 `AppState` 扩展。

| 原文件及区间 | 目标文件 |
| --- | --- |
| MessageSendingAttachments 39–380 | `AppState+DurableReadAck.swift` |
| MessageSendingAttachments 576–716, 1281–1445 | `AppState+OutgoingAttachmentRecovery.swift` |
| MessageSendingAttachments 17, 717–970 | `AppState+TextSending.swift` |
| MessageSendingAttachments 971–1280, 2092–2127 | `AppState+MediaSending.swift` |
| MessageSendingAttachments 1446–2091 | `AppState+AttachmentUpload.swift` |
| MessageSendingAttachments 2128–2437 | `AppState+AttachmentCacheResources.swift` |
| MessageSendingAttachments 2438–2527 | `AppState+ContactCardMessagePresentation.swift` |
| FilesAttachments 437–868 | `AppState+AttachmentURLsAndProgress.swift` |
| FilesAttachments 869–1161 | `AppState+VoiceMessagePlayback.swift` |
| FilesAttachments 1162–1691 | `AppState+AttachmentDownload.swift` |
| FilesAttachments 1692–2002 | `AppState+FileOpenAndSnapshots.swift` |
| FilesAttachments 2003–2490 | `AppState+IndexedMediaCache.swift` |
| Realtime 307–688 | `AppState+RealtimeConnectionRecovery.swift` |
| Realtime 689–1000 | `AppState+RealtimeSequenceRecovery.swift` |
| Realtime 1001–1480 | `AppState+RealtimeEventDispatch.swift` |
| Realtime 1481–1922 | `AppState+RealtimeGroupAndReadEvents.swift` |
| Realtime 1923–2222 | `AppState+RealtimeMessageExtras.swift` |
| RemoteMessageStateMapping 191–363 | `MessageMapping/AppState+MessageHistoryPrefetch.swift` |
| RemoteMessageStateMapping 364–882 | `MessageMapping/AppState+MessageSidecarSync.swift` |
| RemoteMessageStateMapping 883–1165, 1298–1633 | `MessageMapping/AppState+RemoteMessageApply.swift` |
| RemoteMessageStateMapping 1166–1297 | `MessageMapping/AppState+DeliveryAcknowledgements.swift` |
| RemoteMessageStateMapping 1634–2054 | `MessageMapping/AppState+MessageAndReplyProjection.swift` |
| RemoteMessageStateMapping 2055–2180 | `MessageMapping/AppState+MessageMappingSupport.swift` |

- 四个原文件剩 232、437、307 和 191 行。逐行对照 8,255 行，除导入、扩展边界与 35 处跨文件可见性调整，原声明、注释和旧标记一致。文本发送内部的可重试鉴权错误保留文件私有。回退时整体反向应用本批。
- Debug arm64 构建通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 模拟器前后各 18 项全过，覆盖发送重试、租户撤权、附件续传和下载、实时重同步、撤回、回执和持久化出站队列恢复。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1v-*.log` 与 `phase1v-*.xcresult`。


## iOS1 架构重构阶段 0 · 验证入口

- `WDT_IOS1_REFACTOR_CHECK_20261110` 新增 `scripts/refactor-check.sh`。入口要求显式指定已启动的测试模拟器 UDID 和基线 `.xcresult`。依次运行 Release 构建和 Debug 全部 XCTest，核对两个产物的最低部署版本，导出同名 PNG 并比较解码后的像素。可显式启用已完成阶段的源码守卫。
- `--compare-snapshots` 可直接复用既有结果包。用 `phase1o` 前后制品验证 7 张截图逐像素一致，传入不同截图集合时按预期拒绝。在当前源码上启用阶段 2 守卫，确认它能阻止未迁移的观察状态通过。脚本语法检查通过。完整构建和全量测试组合仍待整合后按项目规则运行，截图覆盖取决于传入结果包。回退时反向应用本批。


## iOS1 架构重构阶段 1 · 联系人关系、群管理、消息操作与贴纸拆分

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `17ba1f9c025210f32da726521e46715324c18742`。行号对应 `Core/AppSupport/` 下拆分前文件。下列方法仍在原 App target 的 `AppState` 扩展。

| 原文件及区间 | 目标文件 |
| --- | --- |
| ContactsInboxDevices 677–1150 | `AppState+ContactRelationships.swift` |
| ContactsInboxDevices 1151–1353, 1651–1723 | `AppState+InboxAndDevices.swift` |
| ContactsInboxDevices 1354–1650 | `AppState+RTCSignalingRefresh.swift` |
| GroupAdministration 549–817 | `AppState+GroupMuteList.swift` |
| GroupAdministration 818–1339 | `AppState+GroupCreationAndSettings.swift` |
| GroupAdministration 1340–1581 | `AppState+GroupMembershipLifecycle.swift` |
| MessageActions 297–570 | `AppState+ReadReceiptPresentation.swift` |
| MessageActions 571–886 | `AppState+MessageEditing.swift` |
| MessageActions 887–1206 | `AppState+MessageModerationAndReports.swift` |
| MessageActions 1207–1847 | `AppState+BatchForwarding.swift` |
| MessageActions 1848–1983 | `AppState+MessageForwardAndReaction.swift` |
| StickerLibrary 435–797 | `AppState+StickerLibraryActions.swift` |
| StickerLibrary 798–1319 | `AppState+StickerUploadAndHydration.swift` |

- 四个原文件剩 677、549、297 和 435 行。逐行对照 4,652 行，除导入、扩展边界与 17 处跨文件可见性调整，原声明、注释和旧标记一致。回退时整体反向应用本批。
- Debug arm64 构建通过，`MinimumOSVersion` 为 `15.0`。iOS 26.5 前后各 14 项，均为 12 项通过，联系人备注和语音接听后心跳两项既有断言结果一致。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1w-*.log` 与 `phase1w-*.xcresult`。


## iOS1 架构重构阶段 1 · 历史、群资料、租户映射与调试夹具

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接联系人、群管理与贴纸拆分 `39180ab18515f376b821b2c657dc3946c90993a1`。本批将历史补页、已读投影、群资料与文件、租户授权投影和调试夹具按职责拆出 13 个同 target 文件。

| 原文件及区间 | 目标文件 |
| --- | --- |
| ConversationsHistory 557–866 | `AppState+ConversationReadState.swift` |
| ConversationsHistory 867–1067 | `AppState+GroupHistoryBoundary.swift` |
| ConversationsHistory 1068–1426 | `AppState+HistoryPaging.swift` |
| ConversationsHistory 1427–1501 | `AppState+ActiveConversationLifecycle.swift` |
| RemoteGroupFileMapping 448–913 | `GroupFileMapping/AppState+GroupAuthorityProjection.swift` |
| RemoteGroupFileMapping 914–1287 | `GroupFileMapping/AppState+GroupDetailProjection.swift` |
| RemoteGroupFileMapping 1288–1897 | `GroupFileMapping/AppState+RemoteFileMapping.swift` |
| RemoteGroupFileMapping 1898–2355 | `GroupFileMapping/AppState+RemoteConversationProjection.swift` |
| TenantSwitchingRemoteMapping 437–999 | `TenantSession/AppState+WorkspaceAndTenantAuthority.swift` |
| TenantSwitchingRemoteMapping 1000–1455 | `TenantSession/AppState+TenantProfileAndRelations.swift` |
| TenantSwitchingRemoteMapping 1456–1867 | `TenantSession/AppState+TenantInboxMapping.swift` |
| DebugScreenshotFixtures 412–853, 1367–1421 | `DebugFixtures/AppState+DebugAvatarFixtures.swift` |
| DebugScreenshotFixtures 854–1366 | `DebugFixtures/AppState+DebugGroupFixtures.swift` |

- 共移动 5,294 行。原文件分别为 557、448、437、414 行，新增文件均在 800 行内。八处扩展成员的可见性扩大至模块内以保留原调用；调试夹具保留原 `#if DEBUG` 和 `@MainActor` 边界。逐段验证声明正文及 Xcode 工程登记；回退时整体反向应用本批。
- Debug arm64 模拟器构建、Swift 语法和工程检查通过，候选 `MinimumOSVersion=15.0`。原始提交与候选在 iOS 26.5 各运行 15 项 XCTest，均 14 项通过，原有 `testAppStateVisibleQueuedReadDoesNotConsumeUnseenArrival` 四处断言的实际值和期望值一致。证据位于 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1x-*.log` 与 `Phase1x-*.xcresult`。


## iOS1 架构重构阶段 1 · 会话、附件和策略辅助类型

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `133e38be76c67455ea8c7200560c068b33764988`。会话时间线、远端资料投影、通知作用域、附件、生命周期、诊断与策略缓存辅助类型按职责搬至同 App target。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `AppStateLocalSupport.swift` 309–633 | `BlueStoneIM/Core/AppSupport/ConversationTimelineSupport.swift` |
| `AppStateLocalSupport.swift` 634–1046 | `BlueStoneIM/Core/AppSupport/RemotePayloadAndFileProjectionSupport.swift` |
| `AppStateLocalSupport.swift` 1047–1311 | `BlueStoneIM/Core/AppSupport/ConversationSequenceAndNotificationSupport.swift` |
| `AppStateLocalSupport.swift` 1312–1791 | `BlueStoneIM/Core/AppSupport/AttachmentRuntimeSupport.swift` |
| `AppStateLocalSupport.swift` 1792–2172 | `BlueStoneIM/Core/AppSupport/LocalMessageAndContactProjectionSupport.swift` |
| `AppStateLocalSupport.swift` 2173–2586 | `BlueStoneIM/Core/AppSupport/AppStateLifecycleSupport.swift` |
| `AppStateLocalSupport.swift` 2587–2884 | `BlueStoneIM/Core/AppSupport/AttachmentDownloadSupport.swift` |
| `AppStatePolicies.swift` 406–905 | `BlueStoneIM/Core/AppSupport/FriendAndWorkspaceDiagnostics.swift` |
| `AppStatePolicySupport.swift` 610–822 | `BlueStoneIM/Core/AppSupport/ScopedAppPolicyStores.swift` |

- 共移动 3,289 行，原文件分别为 307、404、608 行。逐段核对声明正文，保留访问级别。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各运行 15 项 XCTest，均 14 项通过。既有 `testAttachmentDownloadProgressDelegateDoesNotReuseUnscopedLegacyCache` 在两轮都观测到进度 0.0，期望 0.02。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1y-*.log` 和 `phase1y-*.xcresult`。


## iOS1 架构重构阶段 1 · 接入发现、预登录信任和诊断界面

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `ef559de4a05ddc9d08f26add3afa452cb23d8165`。运行时路由与接入发现的信任、端点和缓存分开，预登录签名保留严格 JSON 及旧作用域规则，诊断视图保留同一 target 的编译与展示路径。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `AccessDiscovery.swift` 5–445 | `BlueStoneIM/RuntimeRouteModels.swift` |
| `AccessDiscovery.swift` 446–768 | `BlueStoneIM/RuntimeRouteStore.swift` |
| `AccessDiscovery.swift` 769–1021 | `BlueStoneIM/RuntimeRouteFailover.swift` |
| `AccessDiscovery.swift` 1140–1475 | `BlueStoneIM/AccessDiscoveryModels.swift` |
| `AccessDiscovery.swift` 1476–1929 | `BlueStoneIM/AccessDiscoveryTrust.swift` |
| `AccessDiscovery.swift` 1930–2350 | `BlueStoneIM/AccessDiscoveryEndpoint.swift` |
| `AccessDiscovery.swift` 2351–2693 | `BlueStoneIM/AccessDiscoveryStore.swift` |
| `AccessDiagnostics.swift` 8–664 | `BlueStoneIM/AccessDiagnosticsSnapshot.swift` |
| `AccessDiagnostics.swift` 1059–1598, 1793–1858 | `BlueStoneIM/AccessDebugOverlay.swift` |
| `AccessDiagnostics.swift` 1599–1792 | `BlueStoneIM/AccessDebugOverlayLayout.swift` |
| `PreloginBootstrap.swift` 255–880 | `BlueStoneIM/PreloginStrictJSON.swift` |
| `PreloginBootstrap.swift` 215–233, 881–1403 | `BlueStoneIM/PreloginTrust.swift` |

- 共移动 5,196 行，新增 12 个 Swift 文件。原文件分别为 745、400、233 行。逐段核对原声明和访问级别，诊断覆盖层的私有视图、测量键和拖动修饰符留在一起。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 15 项 XCTest 全部通过，覆盖同版本冲突、坏当前配置回退、持久水位写入失败、账户与租户隔离、非规范 JSON、篡改签名及诊断界面激活。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1z-*.log` 和 `phase1z-*.xcresult`。


## iOS1 架构重构阶段 1 · 媒体、转发、同步和领域辅助类型

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `8ed5f50d733613976b1357a62369aec937ba86f5`。媒体身份、缓存及下载，转发输入及结果，同步合同、录屏状态、贴纸模型和认证资料请求辅助类型保持原 App target。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `MediaPipeline.swift` 4–575 | `BlueStoneIM/MediaResourceModels.swift` |
| `MediaPipeline.swift` 576–1212 | `BlueStoneIM/MediaLayeredCache.swift` |
| `MediaPipeline.swift` 1213–1809 | `BlueStoneIM/MediaDownloadPipeline.swift` |
| `BatchForwardState.swift` 3–451 | `BlueStoneIM/BatchForwardModels.swift` |
| `SyncEngine.swift` 5–277 | `BlueStoneIM/SyncEngineContract.swift` |
| `IOSRiskTelemetry.swift` 5–139 | `BlueStoneIM/IOSSceneCaptureMonitor.swift` |
| `StickerStore.swift` 4–508 | `BlueStoneIM/StickerLibraryModels.swift` |
| `CertificationPresentation.swift` 11–387 | `BlueStoneIM/CertificationProfileBroker.swift` |

- 共移动 3,545 行，新增 8 个 Swift 文件。六个原文件均在 800 行内。逐段核对原声明和访问级别。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各运行 15 项 XCTest，14 项均通过。媒体身份向量用例两边在读夹具时报告 `NSCocoaErrorDomain 260`，隔离检出未保留测试使用的 `code/docs` 相对目录。该用例的断言需在完整仓库布局重跑。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1aa-*.log` 和 `phase1aa-*.xcresult`。


## iOS1 架构重构阶段 1 · 协议正文、签名上传、会话身份和头像

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `a6cda05becc21ce560eefa38ff1b6ee529a2d1a5`。协议正文获取、二进制上传、当前用户身份缓存和头像展示投影按职责拆分，原有私有访问边界保留。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `Core/Networking/IMAPIClient+Bootstrap.swift` 583–862 | `BlueStoneIM/Core/Networking/IMAPIClient+LegalDocuments.swift` |
| `Core/Networking/IMAPIClient+Files.swift` 81–485 | `BlueStoneIM/Core/Networking/IMAPIClient+BinaryUpload.swift` |
| `Core/Storage/IMAPIContext.swift` 166–416 | `BlueStoneIM/Core/Storage/IMCurrentUserIdentityCache.swift` |
| `AvatarRealtimeProjection.swift` 425–687 | `BlueStoneIM/AvatarRealtimeSurfaceProjector.swift` |

- 共移动 1,199 行，四个原文件分别为 768、631、763、570 行。逐段核对原声明，两个网络扩展保留 `@MainActor`。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 14 项 XCTest 全过，覆盖固定协议 URL、同源拒绝、上传 MIME 与错误脱敏、禁止符号链接、会话部分写入失败、跨作用域清理与头像权威批次。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1ab-*.log` 和 `phase1ab-*.xcresult`。


## iOS1 架构重构阶段 1 · 通话截图入口与本地持久化辅助代码

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `6a859e4cbc1601e2215c1378b980914a73bd660f`。通话截图场景和宿主从正式通话视图搬出。本地消息持久化的清理围栏与墓碑存储，以及媒体缓存转发方法分别归组。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `VideoCallViews.swift` 33–223 | `BlueStoneIM/VideoCallScreenshotHost.swift` |
| `MessagePersistenceCoordinator.swift` 4–278 | `BlueStoneIM/MessagePersistenceScopeCleanup.swift` |
| `MessagePersistenceCoordinator.swift` 699–806 | `BlueStoneIM/MessagePersistenceMediaCache.swift` |

- 共移动 574 行，两个原文件分别为 656、704 行。保留截图场景的 Debug 条件及正式界面的无障碍标识。两种清理辅助类型和仓储取用方法扩大至模块内可见，其余边界保留。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 11 项 XCTest 全过，覆盖退出清理、同作用域重登、清理失败隔离、墓碑恢复、共享附件回收、通话布局与无障碍。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1ac-*.log` 和 `phase1ac-*.xcresult`。


## iOS1 架构重构阶段 1 · SQLite 消息仓储

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `3286144e52fb830eed5e651aac2f490db6ec5cbb`。把消息投影、出站队列、媒体缓存及回执分到同 App target 的四个 actor 扩展，开库、连接配置、迁移、诊断与写入者校验留在仓储主文件。SQL、数据库 schema、数据位置和作用域键沿用原实现。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `SQLiteMessageRepository.swift` 131–397, 723–730, 2016–2020, 2134–2554, 2726–2752 | `BlueStoneIM/SQLiteMessageRepository+Projection.swift` |
| `SQLiteMessageRepository.swift` 398–722, 1144–1365, 1902–1928, 2055–2133 | `BlueStoneIM/SQLiteMessageRepository+Outbox.swift` |
| `SQLiteMessageRepository.swift` 731–825, 1389–1901, 1943–2015, 2021–2054 | `BlueStoneIM/SQLiteMessageRepository+MediaCache.swift` |
| `SQLiteMessageRepository.swift` 826–1143, 2555–2725 | `BlueStoneIM/SQLiteMessageRepository+Acknowledgements.swift` |

- 共移动 2,585 行，主文件 168 行。十个已跨文件调用的属性、类型及方法改为模块内可见，写入者 fence 本身保持私有。源码搬移与工程登记按原片段核对。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 16 项 XCTest，均 15 项通过。旧库损坏用例两边同一断言失败，预置的 keep.pending 文件在恢复后找不到，空库及 quick_check 断言通过。其余旧作用域迁移、WAL 重开、写入隔离、出站幂等、回执重放与缓存撤权用例通过。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1ad-*.log` 和 `phase1ad-*.xcresult`。


## iOS1 架构重构阶段 1 · IM API 客户端主文件

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `c875288657460eca91aae286abcaa8f02c37a337`。基础路由配置、运行时路由、请求执行、响应日志、API 错误映射分别保留在同一个 App target 的 MainActor 扩展中。共享初始化和租户地址写入留在主文件，保留 private(set)。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `Core/Networking/IMAPIClient.swift` 432–747, 923–984, 993–1052 | `BlueStoneIM/Core/Networking/IMAPIClient+RouteConfiguration.swift` |
| `Core/Networking/IMAPIClient.swift` 748–922, 1256–1392 | `BlueStoneIM/Core/Networking/IMAPIClient+RuntimeRouting.swift` |
| `Core/Networking/IMAPIClient.swift` 1053–1255, 1393–1895 | `BlueStoneIM/Core/Networking/IMAPIClient+RequestExecution.swift` |
| `Core/Networking/IMAPIClient.swift` 1896–2229 | `BlueStoneIM/Core/Networking/IMAPIClient+ResponseAndLogging.swift` |
| `Core/Networking/IMAPIClient.swift` 2230–2702 | `BlueStoneIM/Core/Networking/IMAPIClient+APIErrorMapping.swift` |

- 共移动 2,263 行，主文件 460 行。保留原有权限边界及 iOS 16 时钟可用性分支。逐段核对代码正文、编译条件和工程登记。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 14 项 XCTest 全过，覆盖运行时回退、不可重放写入、GET 去重、原始身份授权、注入编解码、失败脱敏和生产 WebSocket 路由。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1ae-*.log` 和 `phase1ae-*.xcresult`。


## iOS1 架构重构阶段 1 · 应用入口、通知与主界面

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `40a7b8d113e9dc72529d80424140763d24a82528`。通知模型、权限和运行时，以及策略画面、覆盖层和主界面各归组。AppDelegate、RootView 和进入正式应用的路由仍在原文件，沿用同一 App target。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `BlueStoneIMApp.swift` 7–65, 267–595 | `BlueStoneIM/IOSNotificationModels.swift` |
| `BlueStoneIMApp.swift` 66–207 | `BlueStoneIM/IOSNotificationAuthorization.swift` |
| `BlueStoneIMApp.swift` 227–266, 596–865 | `BlueStoneIM/IOSNotificationRuntime.swift` |
| `BlueStoneIMApp.swift` 1536–1833 | `BlueStoneIM/ApplicationPolicyScreens.swift` |
| `BlueStoneIMApp.swift` 1834–2119 | `BlueStoneIM/ApplicationOverlayViews.swift` |
| `BlueStoneIMApp.swift` 2120–2396 | `BlueStoneIM/MainShellView.swift` |

- 共移动 1,701 行，入口文件 694 行。8 个由根界面使用的视图类型改为模块内可见。WDT_IOS1_REFACTOR_APPLICATION_ENTRY_20261110 将原有的无在线状态泄漏源码断言覆盖到新文件及上一批的视频截图宿主，断言内容沿用原样。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 14 项 XCTest 全过。同一 iPhone 17 模拟器用调试夹具冷启动策略页、群管理页和通知设置页，三个 PNG 逐字节一致，见 phase1af-app-snapshots。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1af-*.log` 和 `phase1af-*.xcresult`。


## iOS1 架构重构阶段 1 · 实时连接客户端

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `2712bd40a257e971357d6cd78d72aaeb15ee77f0`。连接合同、诊断类型和 QUIC/WebSocket 连接生命周期分到同 App target。连接代次写入、失败裁决、收到的信封处理和公开入口仍在原类。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `RealtimeClient.swift` 5–81, 87–115, 303–446 | `BlueStoneIM/RealtimeTransportContracts.swift` |
| `RealtimeClient.swift` 116–302 | `BlueStoneIM/RealtimeConnectionDiagnostics.swift` |
| `RealtimeClient.swift` 765–1052, 1084–1209, 1534–1608, 1618–1686 | `BlueStoneIM/RealtimeClient+ConnectionLifecycle.swift` |

- 共移动 995 行，主文件 713 行。64 处跨文件访问作最小可见性调整，其中仅需读的当前请求保留私有 setter。连接代次、连接状态和当前信封诊断继续使用原 private(set)。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 15 项 XCTest，均 14 项通过。精确 connect ACK 用例均超时且四个值断言一致。其余连接代次上限、QUIC 回退、心跳、收包顺序、去重及网络恢复用例通过。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1ag-*.log` 和 `phase1ag-*.xcresult`。


## iOS1 架构重构阶段 1 · 语音媒体与系统接听

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `fb8d7d3254b13e58b2421e8b92f3e1f3a5ab031d`。分开诊断日志、语音会话合同、CallKit/PushKit 集成以及 WebRTC 信令、质量和恢复逻辑。系统接听的设备条件、语音质量的 Debug 条件以及未引入 WebRTC 时的替代实现保持原合同。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `VoiceMediaClient.swift` 18–22, 198–478 | `BlueStoneIM/VoiceMediaSession.swift` |
| `VoiceMediaClient.swift` 23–197 | `BlueStoneIM/RTCCallDiagnosticLogStore.swift` |
| `VoiceMediaClient.swift` 479–1014 | `BlueStoneIM/CallKitVoiceCallIntegration.swift` |
| `VoiceMediaClient.swift` 1370–1477 | `BlueStoneIM/WebRTCVoiceMediaClient+QualityDiagnostics.swift` |
| `VoiceMediaClient.swift` 1478–1951 | `BlueStoneIM/WebRTCVoiceMediaClient+Signaling.swift` |
| `VoiceMediaClient.swift` 1952–2169 | `BlueStoneIM/WebRTCVoiceMediaClient+Recovery.swift` |

- 共移动 1,797 行，主文件 724 行。45 处跨文件访问按调用需要调整，三处只读调用保留私有 setter。启用 CallKit 条件的 arm64 iOS 15.0 语法解析通过。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 12 项 XCTest 全过，覆盖接听等待音频激活、失败补偿、过期加入回调、语音就绪、信令重试、恢复超时及来电终止路由。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1ah-*.log` 和 `phase1ah-*.xcresult`。


## iOS1 架构重构阶段 1 · 视频媒体、渲染与质量采样

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `ba668055482a1290af97d57424c42f78bec95d1d`。把视频策略、渲染视图、质量采样与上报、媒体就绪探测、信令与恢复分别搬到同 App target。摄像头的启动停止、原始媒体实例与第一帧观察仍留在主文件。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `VideoMediaClient.swift` 12–485 | `BlueStoneIM/RTCVideoMediaPolicies.swift` |
| `VideoMediaClient.swift` 486–626, 640–1048 | `BlueStoneIM/RTCQualitySampling.swift` |
| `VideoMediaClient.swift` 1049–1249 | `BlueStoneIM/RTCQualityTelemetrySession.swift` |
| `VideoMediaClient.swift` 1328–1389, 1420–1503, 3216–3225 | `BlueStoneIM/RTCVideoRenderer.swift` |
| `VideoMediaClient.swift` 627–639, 2645–2765, 2857–2929, 2970–3050 | `BlueStoneIM/WebRTCVideoMediaClient+Media.swift` |
| `VideoMediaClient.swift` 1983–2320, 2469–2644 | `BlueStoneIM/WebRTCVideoMediaClient+Signaling.swift` |
| `VideoMediaClient.swift` 2321–2468, 3053–3215 | `BlueStoneIM/WebRTCVideoMediaClient+Recovery.swift` |

- 共移动 2,494 行，主文件 733 行。58 处跨文件访问调整，五处只读调用保留私有 setter。保留 WebRTC 可用条件及降级渲染视图。WDT_IOS1_REFACTOR_VIDEO_MEDIA_20261110 将原渲染源码检查扩展到搬移后的渲染文件，保留同样的断言。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 15 项 XCTest 全过，覆盖 WebRTC 渲染器重新绑定、首帧、关停、ICE、凭据、质量脱敏、后台摄像头和旧通话回调隔离。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1ai-*.log` 和 `phase1ai-*.xcresult`。


## iOS1 架构重构阶段 1 · 测试源码拆分首批

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `018b579fe3228f5c1cf28e50512984910f740177`。同步引擎实时恢复、系统预览下载、接入诊断显示和头像展示投影各搬到对应测试文件，保留 XCTestCase 与用例名称。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `SyncEngineTests.swift` 517–571, 578–749 | `BlueStoneIMTests/SyncEngineRealtimeTests.swift` |
| `FilePreviewTests.swift` 571–694, 745–844 | `BlueStoneIMTests/SystemPreviewDownloadTests.swift` |
| `AccessDiagnosticsTests.swift` 605–762, 838–937 | `BlueStoneIMTests/AccessDiagnosticsOverlayPresentationTests.swift` |
| `AvatarRealtimeProjectionTests.swift` 328–556, 706–829 | `BlueStoneIMTests/AvatarRealtimeSurfaceProjectionTests.swift` |

- 共移动 1,062 行，四个原文件分别为 589、619、719、644 行。头像两处共享夹具辅助函数改为测试模块内可见。测试断言及旧文件位置的查找相对路径保持。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 13 项 XCTest 全过。Xcode 发现的 116 个目标类用例标识及工程总计 2,032 个用例标识前后逐项一致，见 phase1aj-*-enumeration.json。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1aj-*.log` 和 `phase1aj-*.xcresult`。


## iOS1 架构重构阶段 1 · 附件、通话生命周期和通话记录测试

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `bc3075ac135369fb34df4f5cb65dcb20269daa6e`。把来电重放与建立竞争、通话记录投影、附件下载与租户授权测试按原职责搬移。所有 XCTestCase 和用例名称沿用原值。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `CallLifecycleTests.swift` 667–1075 | `BlueStoneIMTests/RTCCallLifecycleIntegrationTests.swift` |
| `RTCCallRecordMessageTests.swift` 348–717 | `BlueStoneIMTests/RTCCallRecordProjectionTests.swift` |
| `AttachmentDownloadTests.swift` 543–1151, 1154–1291 | `BlueStoneIMTests/AttachmentDownloadPipelineTests.swift` |

- 共移动 1,526 行，三个原文件分别为 665、579、543 行。14 处共享夹具和测试辅助函数改为测试模块内可见。前后发现的 99 个目标用例标识及工程总计 2,032 个用例标识逐项一致。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 13 项 XCTest，均 12 项通过。来电列表早于语音接入的用例在两轮均抛出 conditionTimedOut。其他附件授权、通话投影和终止用例通过。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1ak-*.log` 和 `phase1ak-*.xcresult`。


## iOS1 架构重构阶段 1 · 预登录解析器与媒体缓存测试

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `464a5637494c1988b161b8689948fcc537474473`。把预登录三源解析与恢复测试、媒体身份和 GIF 播放测试分开。原 XCTestCase、测试方法、fixture 键和期望值保留。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `PreloginBootstrapTests.swift` 255–392, 418–831, 1139–1303, 1348–1384 | `BlueStoneIMTests/PreloginResolverTests.swift` |
| `MediaPipelineTests.swift` 404–683, 1169–1178, 1200–1251 | `BlueStoneIMTests/MediaCacheIdentityTests.swift` |
| `MediaPipelineTests.swift` 684–1134, 1195–1199, 1319–1338 | `BlueStoneIMTests/MediaGIFPlaybackTests.swift` |

- 共移动 1,572 行，预登录及媒体测试主文件分别为 629、536 行。13 处被多个文件使用的测试辅助成员改为测试模块内可见。前后发现的 61 个目标用例标识及工程总计 2,032 个用例标识逐项一致。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 13 项 XCTest 全过，覆盖三源解析、篡改拒绝、旧配置复验、媒体身份、缓存校验及 GIF 恢复。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1al-*.log` 和 `phase1al-*.xcresult`。


## iOS1 架构重构阶段 1 · 设计系统与身份展示测试

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `f3caa316cd1c5ea8100e1fb93f6543d8039da10c`。导航兼容、图片加载、联系人展示和聊天展示分别归组。保留原测试类、用例名、断言和截图基准。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `DesignSystemTests.swift` 7–45, 48–94, 190–489, 1596–1654 | `BlueStoneIMTests/DesignSystemNavigationTests.swift` |
| `DesignSystemTests.swift` 877–1403, 1412–1429, 1454–1577, 1655–1668 | `BlueStoneIMTests/DesignSystemImageLoadingTests.swift` |
| `IdentityPresentationTests.swift` 587–726 | `BlueStoneIMTests/IdentityContactPresentationTests.swift` |
| `IdentityPresentationTests.swift` 727–1333, 1489–1599 | `BlueStoneIMTests/IdentityChatPresentationTests.swift` |

- 共移动 1,986 行，两个原文件分别为 540、740 行。13 处跨测试文件的辅助成员改为测试模块内可见，继续使用原测试 target。两个测试类的 91 个用例和工程总计 2,032 个用例前后逐项一致。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 13 项 XCTest 全过。聊天标题、禁言横幅、工具栏和联系人行共 10 张 PNG 逐像素一致。另在保留仓库目录结构的 f3caa316 候选检出中单独补跑 testFrozenIdentityVectorsMatchCanonicalContract 并通过，见 proper-layout-fixture.xcresult。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1am-*.log` 和 `phase1am-*.xcresult`。


## iOS1 架构重构阶段 1 · 消息数据库测试

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `b4a70fb79e277b9fe3f7913bc2f2925315cb1821`。作用域、媒体缓存、消息语义、出站队列、重新认证、性能和共用夹具按职责归组，保留 XCTestCase、原测试期望及同仓库的夹具相对路径。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `MessageDatabaseTests.swift` 545–739, 769–1129, 1137–1145, 1148–1189 | `BlueStoneIMTests/MessageDatabaseMediaCacheTests.swift` |
| `MessageDatabaseTests.swift` 1190–1647, 2469–2653 | `BlueStoneIMTests/MessageDatabaseSemanticsTests.swift` |
| `MessageDatabaseTests.swift` 1648–2143 | `BlueStoneIMTests/MessageDatabaseOutboxTests.swift` |
| `MessageDatabaseTests.swift` 2144–2468 | `BlueStoneIMTests/MessageDatabaseReauthenticationTests.swift` |
| `MessageDatabaseTests.swift` 2654–2823 | `BlueStoneIMTests/MessageDatabasePerformanceTests.swift` |
| `MessageDatabaseTests.swift` 2824–3031 | `BlueStoneIMTests/LocalMessageTestFixture.swift` |

- 共移动 2,449 行，原文件 581 行，新增六个文件均在 800 行内。四处共用测试辅助声明改为测试模块内可见。前后发现的 49 个目标用例标识及工程总计 2,032 个用例标识逐项一致。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 17 项 XCTest 全过，覆盖旧库迁移、授权撤销、出站恢复、重登隔离、缓存状态向量和五千条消息样本。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1an-*.log` 和 `phase1an-*.xcresult`。


## iOS1 架构重构阶段 1 · 实时传输与接入发现测试

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `0b354a68f3f0a5440bf2f9681094f4225356a267`。将连接拨号、帧处理、恢复、回执、测试传输、接入签名、运行时路由和引导回退分开。保留原 XCTestCase、用例标识及夹具路径。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `RealtimeTransportTests.swift` 383–832 | `BlueStoneIMTests/RealtimeTransportDialingTests.swift` |
| `RealtimeTransportTests.swift` 833–1323 | `BlueStoneIMTests/RealtimeTransportWireTests.swift` |
| `RealtimeTransportTests.swift` 1324–1912 | `BlueStoneIMTests/RealtimeTransportRecoveryTests.swift` |
| `RealtimeTransportTests.swift` 1915–2648 | `BlueStoneIMTests/RealtimeTransportTestFixtures.swift` |
| `RealtimeTransportTests.swift` 2649–3098 | `BlueStoneIMTests/RealtimeReceiptRecoveryTests.swift` |
| `AccessDiscoveryTests.swift` 628–794 | `BlueStoneIMTests/AccessDiscoveryContractTests.swift` |
| `AccessDiscoveryTests.swift` 8–65, 795–1448, 1663–1689 | `BlueStoneIMTests/AccessDiscoveryTrustTests.swift` |
| `AccessDiscoveryTests.swift` 1449–1660, 1690–1829 | `BlueStoneIMTests/AccessDiscoveryTestFixtures.swift` |
| `AccessDiscoveryTests.swift` 1830–2445, 3603–3704 | `BlueStoneIMTests/RuntimeRoutesP0Tests.swift` |
| `AccessDiscoveryTests.swift` 2446–2782 | `BlueStoneIMTests/AppBootstrapHostConfigurationTests.swift` |
| `AccessDiscoveryTests.swift` 2783–3133 | `BlueStoneIMTests/AppBootstrapFailoverTests.swift` |
| `AccessDiscoveryTests.swift` 3134–3602 | `BlueStoneIMTests/AppBootstrapLastGoodTests.swift` |

- 共移动 5,847 行，两个原文件分别为 383、571 行，新增 12 个文件。44 处已有跨文件调用的测试声明改为模块内可见，默认值存储仍保留原 setter 边界。目标 156 项及工程总计 2,032 个用例标识一致。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 17 项 XCTest 全过，覆盖 QUIC 回退、旧作用域诊断、回执重放、签名篡改、引导源切换和路由权威。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1ao-*.log` 和 `phase1ao-*.xcresult`。


## iOS1 架构重构阶段 1 · API 模型测试

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `0dc9eb465e52dcee4c24e872c0913bf4310b8080`。将 RTC 质量、视频与信令、群历史、工作台和文件、消息与在线状态、身份、贴纸、策略、租户和搜索模型测试按接口归组。保留原 XCTestCase、用例名及请求、响应和拒绝路径断言。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `RemoteAPIModelsTests.swift` 263–434, 585–866 | `BlueStoneIMTests/RemoteRTCQualityModelTests.swift` |
| `RemoteAPIModelsTests.swift` 867–1425 | `BlueStoneIMTests/RemoteRTCVideoSignalModelTests.swift` |
| `RemoteAPIModelsTests.swift` 1426–1679, 1840–1888 | `BlueStoneIMTests/RemoteGroupHistoryModelTests.swift` |
| `RemoteAPIModelsTests.swift` 1680–1839, 1889–2321 | `BlueStoneIMTests/RemoteWorkspaceAndFileModelTests.swift` |
| `RemoteAPIModelsTests.swift` 2322–2775, 5802–5813 | `BlueStoneIMTests/RemoteMessageAndPresenceModelTests.swift` |
| `RemoteAPIModelsTests.swift` 2776–3256, 5693–5801 | `BlueStoneIMTests/RemoteIdentityModelTests.swift` |
| `RemoteAPIModelsTests.swift` 3257–3583 | `BlueStoneIMTests/RemoteStickerAndEmojiModelTests.swift` |
| `RemoteAPIModelsTests.swift` 3584–4073 | `BlueStoneIMTests/RemoteRTCCallAndPushModelTests.swift` |
| `RemoteAPIModelsTests.swift` 4074–4400 | `BlueStoneIMTests/RemoteRTCSignalContractModelTests.swift` |
| `RemoteAPIModelsTests.swift` 4401–4781, 5631–5692, 5818–5854 | `BlueStoneIMTests/RemoteAppPolicyModelTests.swift` |
| `RemoteAPIModelsTests.swift` 4782–5192 | `BlueStoneIMTests/RemoteTenantContextModelTests.swift` |
| `RemoteAPIModelsTests.swift` 5193–5630, 5814–5817 | `BlueStoneIMTests/RemoteSearchModelTests.swift` |

- 共移动 5,442 行，原文件 413 行，新增十二个文件。一处跨文件共用的强制认证用户夹具改为测试模块内可见。目标 209 项及工程总计 2,032 个用例标识一致。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 16 项 XCTest 全过，覆盖 DTO 兼容、授权快照、消息编辑、RTC 凭据、搜索和策略字段。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1ap-*.log` 和 `phase1ap-*.xcresult`。


## iOS1 架构重构阶段 1 · HTTP 传输与业务入口测试

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `d5e90b96af0ecf046648516f59d39c25ffeb33c3`。将 HTTP 响应、登录注册、会话持久化、工作台、聊天发送、上传、群资料和 RTC 入口测试及其共用夹具分组。保留同一测试类、原断言和原入口。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `HTTPTransportTests.swift` 731–1420 | `BlueStoneIMTests/HTTPHistoryDiagnosticsAndReauthenticationTests.swift` |
| `HTTPTransportTests.swift` 1421–2128 | `BlueStoneIMTests/HTTPReauthenticationAndAttachmentTransportTests.swift` |
| `HTTPTransportTests.swift` 2129–2855 | `BlueStoneIMTests/HTTPRuntimeRouteAndOutboxTests.swift` |
| `HTTPTransportTests.swift` 2856–3563 | `BlueStoneIMTests/HTTPProductionRoutingAndEnterpriseContextTests.swift` |
| `HTTPTransportTests.swift` 3564–4283 | `BlueStoneIMTests/HTTPEnterpriseLoginAndCaptchaTests.swift` |
| `HTTPTransportTests.swift` 4284–5001 | `BlueStoneIMTests/HTTPCaptchaPasswordAndSocialContractTests.swift` |
| `HTTPTransportTests.swift` 5002–5717 | `BlueStoneIMTests/HTTPGroupAnnouncementAndLegalDocumentTests.swift` |
| `HTTPTransportTests.swift` 5718–6415 | `BlueStoneIMTests/HTTPLegalTenantEntryAndDiagnosticsTests.swift` |
| `HTTPTransportTests.swift` 6416–7122 | `BlueStoneIMTests/HTTPAccountPolicyAndGroupLifecycleTests.swift` |
| `HTTPTransportTests.swift` 7123–7846 | `BlueStoneIMTests/HTTPVerificationContactAndRemarkTests.swift` |
| `HTTPTransportTests.swift` 7847–8530 | `BlueStoneIMTests/HTTPRegistrationSubmissionTests.swift` |
| `HTTPTransportTests.swift` 8531–9221 | `BlueStoneIMTests/HTTPRegistrationPendingRecoveryTests.swift` |
| `HTTPTransportTests.swift` 9222–9929 | `BlueStoneIMTests/HTTPRegistrationAuthorityAndInviteTests.swift` |
| `HTTPTransportTests.swift` 9930–10636 | `BlueStoneIMTests/HTTPRememberedLoginTests.swift` |
| `HTTPTransportTests.swift` 10637–11361 | `BlueStoneIMTests/HTTPProtectedSessionTests.swift` |
| `HTTPTransportTests.swift` 11362–12015 | `BlueStoneIMTests/HTTPWorkspaceSessionRefreshTests.swift` |
| `HTTPTransportTests.swift` 12016–12732 | `BlueStoneIMTests/HTTPWorkspaceAndMessageSendTests.swift` |
| `HTTPTransportTests.swift` 12733–13452 | `BlueStoneIMTests/HTTPMessageSendAndMediaRecoveryTests.swift` |
| `HTTPTransportTests.swift` 13453–14165 | `BlueStoneIMTests/HTTPMediaRecoveryAndVideoUploadTests.swift` |
| `HTTPTransportTests.swift` 14166–14860 | `BlueStoneIMTests/HTTPHeadersRemarksAndRTCContractTests.swift` |
| `HTTPTransportTests.swift` 14861–15548 | `BlueStoneIMTests/HTTPRTCParticipantAdmissionTests.swift` |
| `HTTPTransportTests.swift` 15549–16242 | `BlueStoneIMTests/HTTPRTCSignalStickerAndUploadTests.swift` |
| `HTTPTransportTests.swift` 16243–16903 | `BlueStoneIMTests/HTTPPhonePolicyAndProfileProjectionTests.swift` |
| `HTTPTransportTests.swift` 16904–17633 | `BlueStoneIMTests/HTTPGroupProfileAuthorityTests.swift` |
| `HTTPTransportTests.swift` 17634–18338 | `BlueStoneIMTests/HTTPAuthenticationFixtureTests.swift` |
| `HTTPTransportTests.swift` 18339–19011 | `BlueStoneIMTests/HTTPGroupAvatarAndAttachmentContractTests.swift` |
| `HTTPTransportTests.swift` 19014–19618 | `BlueStoneIMTests/HTTPRoutingAndSessionTestFixtures.swift` |
| `HTTPTransportTests.swift` 19619–20348 | `BlueStoneIMTests/HTTPIntegrationRaceTestFixtures.swift` |
| `HTTPTransportTests.swift` 20349–20627 | `BlueStoneIMTests/HTTPGroupAndRTCTransportTestFixtures.swift` |

- 共移动 19,895 行，原文件 731 行，新增 29 个文件。96 处测试辅助声明按跨文件调用改为测试模块内可见。目标 470 项及工程总计 2,032 个用例标识一致。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 26 项，均 21 项通过。上传失败、企业码校验、注册状态、生产路由期望和发送重试五项原有失败两边一致，已比较八处错误内容并登记。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1aq-*.log` 和 `phase1aq-*.xcresult`。


## iOS1 架构重构阶段 1 · 领域存储与通知状态测试

- `BASED_ON_CANONICAL_HEAD=0581a0f8f906221deb4cb5106a02e218aa8228a1`，承接 `84d9762698cd15bf2262e58cd421c9319f0eaf75`。会话、历史、已读、聊天视口、媒体与附件、通话生命周期、目录、消息动作及通知测试按原职责分组。保留原测试类、用例标识、原断言与作用域夹具。

| 原文件及区间 | 目标文件 |
| --- | --- |
| `DomainStoreTests.swift` 710–1439 | `BlueStoneIMTests/DomainGroupProjectionAndScopeTests.swift` |
| `DomainStoreTests.swift` 1440–2117 | `BlueStoneIMTests/DomainPresenceAndSplashTests.swift` |
| `DomainStoreTests.swift` 2118–2810 | `BlueStoneIMTests/DomainSplashCacheTests.swift` |
| `DomainStoreTests.swift` 2811–3482 | `BlueStoneIMTests/DomainUserAuthorityAndSearchJumpTests.swift` |
| `DomainStoreTests.swift` 3483–4201 | `BlueStoneIMTests/DomainOlderHistoryAndConversationListTests.swift` |
| `DomainStoreTests.swift` 4202–4925 | `BlueStoneIMTests/DomainChatViewportAndGestureTests.swift` |
| `DomainStoreTests.swift` 4926–5631 | `BlueStoneIMTests/DomainChatTranscriptAndContactStoreTests.swift` |
| `DomainStoreTests.swift` 5632–6341 | `BlueStoneIMTests/DomainInboxAndConversationReadStateTests.swift` |
| `DomainStoreTests.swift` 6342–7023 | `BlueStoneIMTests/DomainHistoryAndReadReceiptTests.swift` |
| `DomainStoreTests.swift` 7024–7718 | `BlueStoneIMTests/DomainMessageMergeAndForwardTests.swift` |
| `DomainStoreTests.swift` 7719–8442 | `BlueStoneIMTests/DomainBatchForwardAndUnreadProjectionTests.swift` |
| `DomainStoreTests.swift` 8443–9115 | `BlueStoneIMTests/DomainUnreadListAndFileStoreTests.swift` |
| `DomainStoreTests.swift` 9116–9839 | `BlueStoneIMTests/DomainFileLifecycleAndCallStoreTests.swift` |
| `DomainStoreTests.swift` 9840–10509 | `BlueStoneIMTests/DomainRTCLicenseAndVoiceAdmissionTests.swift` |
| `DomainStoreTests.swift` 10510–11237 | `BlueStoneIMTests/DomainRTCSystemAnswerAndPreviewFenceTests.swift` |
| `DomainStoreTests.swift` 11238–11989 | `BlueStoneIMTests/DomainRTCPreviewAndCallOwnershipTests.swift` |
| `DomainStoreTests.swift` 11990–12637 | `BlueStoneIMTests/DomainRTCJoinAndPeerResolutionTests.swift` |
| `DomainStoreTests.swift` 12638–13346 | `BlueStoneIMTests/DomainRTCInboundAndColdLaunchTests.swift` |
| `DomainStoreTests.swift` 13347–14076 | `BlueStoneIMTests/DomainRTCAudioVideoLifecycleTests.swift` |
| `DomainStoreTests.swift` 14077–14781 | `BlueStoneIMTests/DomainRTCPreviewAndMediaStateTests.swift` |
| `DomainStoreTests.swift` 14782–15478 | `BlueStoneIMTests/DomainRTCHeartbeatTests.swift` |
| `DomainStoreTests.swift` 15479–16201 | `BlueStoneIMTests/DomainRTCTerminalAndMainShellTests.swift` |
| `DomainStoreTests.swift` 16202–16892 | `BlueStoneIMTests/DomainAttachmentAndQueuedReadTests.swift` |
| `DomainStoreTests.swift` 16893–17600 | `BlueStoneIMTests/DomainQueuedReadAndGroupProjectionTests.swift` |
| `DomainStoreTests.swift` 17601–18305 | `BlueStoneIMTests/DomainMessageMutationAndActionMenuTests.swift` |
| `DomainStoreTests.swift` 18306–19026 | `BlueStoneIMTests/DomainMessageActionsAndInitialSyncTests.swift` |
| `DomainStoreTests.swift` 19027–19733 | `BlueStoneIMTests/DomainChatTimelineAndHistorySyncTests.swift` |
| `DomainStoreTests.swift` 19734–20454 | `BlueStoneIMTests/DomainHistoryBoundaryAndDirectoryTests.swift` |
| `DomainStoreTests.swift` 20455–20919 | `BlueStoneIMTests/DomainStoreTestFixtures.swift` |
| `DomainStoreTests.swift` 20922–21649 | `BlueStoneIMTests/DomainRTCSetupTestFixtures.swift` |
| `DomainStoreTests.swift` 21650–22297 | `BlueStoneIMTests/DomainNetworkTestFixtures.swift` |
| `DomainStoreTests.swift` 22298–22561 | `BlueStoneIMTests/DomainRTCAndBiometricTestFixtures.swift` |
| `DomainStoreTests.swift` 22562–23258 | `BlueStoneIMTests/IOSNotificationStateMachineTests.swift` |

- 共移动 22,547 行，原文件 710 行，新增 33 个文件。61 处测试辅助声明按跨文件使用改为测试模块内可见。前后目标 623 项及工程 2,032 个用例标识逐项一致。Debug arm64 构建、Swift 语法和工程检查通过，最低部署版本为 iOS 15.0。回退时整体反向应用本批。
- iOS 26.5 前后各 32 项，均 31 项通过。同作用域通话权限 ABA 的原有断言在两边一致。所有 XCTest Swift 文件均在 800 行内。AppState.swift 集中存储属性、属性观察器和初始化保持原所有权，按阶段 2 分领域迁移，作为阶段 1 的 800 行例外。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/` 的 `phase1ar-*.log` 和 `phase1ar-*.xcresult`。


## iOS1 架构重构阶段 2 · 主界面角标观察

- `WDT_IOS1_REFACTOR_MAIN_TAB_OBSERVATION_20261110`。从 `RootView` 注入 Tab 选择、标题、会话和联系人 Store 以及原启动和系统角标动作。`MainShellView` 直接消费三个 Store 发布值，聊天 Tab 和系统角标共用同一次未读计数发布。保留原角标格式、载入时机、好友请求和公告的计数条件。
- 修改 `BlueStoneIMApp.swift`、`MainShellView.swift` 和 `DomainGroupProjectionAndScopeTests.swift`。其他页面的全局转发保留，待对应消费者迁完再逐路收回。
- iOS 26.5 上基线 8 项通过，候选 9 项通过，新增挂载视图测试校验独立注入的 Store、实时刷新、无关变化、上限及清空。最低部署版本 15.0。日志及结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2a-*.xcresult`。


## iOS1 架构重构阶段 2 · 设计组件动作注入

- `WDT_IOS1_REFACTOR_DESIGN_ACTIONS_20261110`。用户 ID 复制组件从原 11 个调用点接收 `AppState.copyUserID` 动作。审批卡从聊天气泡接收当前请求的处理标记、原审批和复制入口。标签、复制值、审批权限、端点和触控优先级沿用原规则。
- 设计系统内的复制和审批组件脱离 `AppState` 观察。调用方仍使用原会话作用域完成复制、风险事件和审批。认证徽标及剩余全局转发属于后续阶段 2 批次。
- iOS 26.5 前后各 7 项全过，10 张联系人和聊天截图逐像素一致。最低部署版本 15.0。日志及结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2b-*.xcresult`。


## iOS1 架构重构阶段 2 · 登录日志观察与所有权

- `WDT_IOS1_REFACTOR_LOGIN_LOG_OBSERVATION_20261110`。三个登录日志发布字段迁入 `LoginLogStore`，账号安全页只有日志区观察该 Store。`AppState` 暂留三个只读计算属性供现有调用方使用。
- 保留日志刷新入口、租户和账号校验、空态、失败重试、旧列表与提示规则。原远端数据重置清空专用 Store。Store 的变化未加入全局转发。
- iOS 26.5 基线 5 项全过，候选 6 项全过，新增测试经真实日志刷新入口验证加载及结果发布、AppState 无发布与会话数据重置。最低部署版本 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2c-*.xcresult`。


## iOS1 架构重构阶段 2 · 认证徽标观察

- `WDT_IOS1_REFACTOR_CERTIFICATION_OBSERVATION_20261110`。认证徽标由认证 revision 驱动，普通行继续按规范化 UID 读投影，作用域变更后按原入口重新请求。已预取行只渲染调用方的值。
- 主界面、来电窗口与 UIKit 列表宿主注入同一个作用域的观察源。认证权限、缓存和请求逻辑仍由原入口负责。三个原先观察 AppState 的设计组件均已完成迁移。
- iOS 26.5 基线 7 项、候选 8 项全过，新增挂载测试覆盖投影更新、作用域重查与预取行隔离。10 张联系人与聊天截图逐像素一致，最低部署版本为 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2d-*.xcresult`。



## iOS1 架构重构阶段 2 · 贴纸面板观察与转发

- `WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110`。表情面板直接观察 `StickerStore`，刷新、缩略图解析、上传重试、删除和排序仍经原业务入口。贴纸列表和进度退出 `AppState` 的全局转发。
- iOS 26.5 基线 7 项通过，候选 8 项通过。新增挂载测试验证贴纸行从 2% 更新为 36%，并验证贴纸变化及重置不触发 AppState 发布。1 张输入区截图逐像素一致。现有 `testStickerMessageViewResolvesTenantFilePayloadsBeforeRendering` 的 6 条源码断言前后同样失败。最低部署版本为 15.0，证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2e-*.xcresult`。



## iOS1 架构重构阶段 2 · 文件下载与群文件观察

- `WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110`。资料页文件行、文件预览和群文件中的进度直接观察对应作用域、文件版本、原件及预览键，保留原件优先与原取消入口。群文件列表、同步标记和错误通过群 ID 订阅。
- `FileStore.swift` 的文件及群文件投影配合 `AppState+AttachmentDownload.swift` 中已有下载键生成逻辑。消费入口为 `FileListSupportViews.swift`、`FilesView.swift`、`FilePreviewViews.swift` 和 `GroupSharingViews.swift`。聊天附件与配置仍使用原转发。
- iOS 26.5 基线 9 项、候选 10 项通过。`DomainFileLifecycleAndCallStoreTests.swift` 新增挂载测试，验证跨作用域下载隔离、预览回退与原件提交态。`DomainUnreadListAndFileStoreTests.swift` 验证其他群的变化不发送通知，以及本群的同步、错误、重试和重置。最低部署版本 15.0。结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2f-*.xcresult`。



## iOS1 架构重构阶段 2 · 聊天附件观察与文件转发

- `WDT_IOS1_REFACTOR_CHAT_ATTACHMENT_OBSERVATION_20261110`。聊天文件和语音气泡、详情、图片和视频预览、消息动作菜单使用对应附件的下载、重试和缓存观察。继续使用原消息及文件键、资源查找顺序、播放、取消、重试及菜单条件。资源观察与资源读取复用同一组作用域缓存键。
- `FileStore.swift`、`AppState+AttachmentCacheResources.swift`、`AttachmentRuntimeSupport.swift` 提供附件级观察输入，入口在 `ChatAttachmentDetail.swift`、`ChatAttachmentPreview.swift`、`ChatMediaBubbleViews.swift`、`ChatViewLayout.swift`。`AppState+RuntimeBindings.swift` 把文件 Store 的整体转发收窄为上传和权限配置发布，保留同值配置刷新后建立新作用域权限的通知。
- iOS 26.5 基线 10 项、候选 11 项全过，8 张截图逐像素一致。新增挂载用例验证跨作用域隔离、进度、失败、缓存、重试，以及文件变化不再触发 AppState 发布。另 3 项回执和通话权限定向测试通过。最低部署版本 15.0，结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2g-*.xcresult`。



## iOS1 架构重构阶段 2 · 通话窗口、弹层与记录观察

- `WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110`。主界面通过 `CallStore.RootPresentation` 观察来电、全屏弹层、最小化和当前通话 ID。弹层绑定沿用 AppState 写入与清理规则。全局来电窗口、来电和通话控件、最近通话页与截图入口直接读取 `CallStore`，移除 AppState 的整路通话转发。
- `CallStore.swift` 提供发布投影。`BlueStoneIMApp.swift`、`ApplicationOverlayViews.swift`、`CallScreenViews.swift`、`FilesRTCViews.swift` 和 `VideoCallViews.swift` 消费。通过 `appStateEnvironment` 向正常根和独立来电窗口注入 Store。通话写入、权限、媒体和持久化继续沿用原业务入口。
- iOS 26.5 基线 9 项通过，候选 11 项通过。新增用例覆盖通话记录和控件不唤醒主界面、视频最小化不丢会话，以及挂载根视图的终止弹层打开和关闭。已有 `testMinimizedVideoCallDismissalKeepsActiveSessionAndCanRestore` 的 4 条挂断阶段断言前后同样失败。最低部署版本 15.0，结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2h-*.xcresult`。



## iOS1 架构重构阶段 2 · 收藏资料观察与所有权

- `WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110`。收藏资料分页集合与可见状态由 `FileStore.swift` 持有。列表、加载、失败通过同一快照发布。资料页订阅该快照，`AppState.swift` 保留只读入口。
- `AppState+FilesAttachments.swift` 保留分页请求、重试及取消收藏入口，原作用域校验、群历史边界、远端重置、缓存清理和截图夹具继续通过原入口修改 FileStore。资料页现有筛选与异步重建规则保留。
- iOS 26.5 基线 7 项、候选 8 项全过。新增 HTTP 入口测试验证成功、失败保留当前作用域缓存、会话重置和无 AppState 发布。最低部署版本为 15.0，结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2i-*.xcresult`。



## iOS1 架构重构阶段 2 · 设备列表与群邀请审批观察

- `WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110`。在线设备页直接接收设备列表，群邀请审批卡只接收对应请求 ID 的处理状态。封禁、审批与复制仍调用原入口。两项变化退出 AppState 转发，其他 11 个联系人发布字段保留原合并通知。
- `ContactStore.swift` 提供单请求订阅与过渡期转发清单。`DeviceSessionsView.swift`、`MeSettingsViews.swift` 与 `MessageBubble.swift` 接线。共享观察视图迁入 `SwiftUICompatibility.swift`，文件进度、聊天附件和群文件沿用该实现。
- iOS 26.5 基线 8 项、候选 9 项全过。新增挂载用例验证无关审批不更新当前卡、设备列表和审批变化不通知 AppState，以及其余联系人字段仍可通知。7 张聊天截图逐像素一致，最低部署版本 15.0。结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2j-*.xcresult`。



## iOS1 架构重构阶段 2 · 公告收件箱观察

- `WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110`。公告收件箱、个人页计数、会话列表的未读公告缓存使用 `ContactStore.announcementUpdates` 发出的值。Tab 角标继续直接从联系人 Store 计数。收件箱变化退出 AppState 转发，普通系统消息仍通过原会话投影。
- 修改 `ContactStore.swift`、`InboxCenterViews.swift`、`MeSettingsViews.swift`、`ConversationViews.swift` 和 `ConversationListRenderCache.swift`。公告详情的标记已读入口和权限沿用原业务流程。
- iOS 26.5 基线 7 项、候选 8 项全过。新增用例验证普通系统消息不更新公告投影、已读和重置正常、无全局通知。7 张截图逐像素一致，最低部署版本 15.0。结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2k-*.xcresult`。



## iOS1 架构重构阶段 2 · 好友申请与取消状态观察

- `WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110`。新朋友页订阅申请列表与取消状态的合并快照。个人资料页只观察该账号候选身份是否有待处理的出站申请，保持空值、大小写和空白规范化。联系人入口和 Tab 角标使用当前发布列表。
- `ContactStore.swift` 接管取消状态和会话重置，移除好友申请全局转发。`AppState+ContactsInboxDevices.swift` 继续执行原取消请求、作用域校验和结果处理。`ContactRelationshipViews.swift`、`ContactUserProfile.swift` 与 `ContactsViews.swift` 接入对应订阅。
- iOS 26.5 基线 8 项、候选 9 项全过。新增用例验证别名匹配、忽略其他人和入站申请、取消状态、重置与无全局发布。2 张联系人截图逐像素一致，最低部署版本 15.0。结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2l-*.xcresult`。



## iOS1 架构重构阶段 2 · 黑名单观察

- `WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110`。黑名单列表和计数直接订阅列表。个人资料、已解锁聊天、通话记录详情和通话联系人选择按相关身份订阅状态，撤掉黑名单全局转发。保留原始和规范化 ID 匹配差异、发送/通话权限与会话身份回退。
- `ContactStore.swift` 提供按身份过滤的观察。`ContactsViews.swift`、`ContactRelationshipViews.swift`、`ContactUserProfile.swift`、`ChatViews.swift`、`ChatViewHeaderAndStatus.swift`、`FilesRTCViews.swift` 接线。原写入、回滚、缓存与会话投影规则保持。
- iOS 26.5 基线 7 项通过，候选 8 项通过。两个已存在测试 `testCancelledUserDisplayAndVoiceCallAreBlocked`、`testContactMutationFailuresRollbackOptimisticProjectionAndExposeActionableErrors` 前后失败一致。新增挂载测试验证无关对象隔离及发送、通话判断。8 张聊天截图逐像素一致，最低部署版本 15.0。结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2m-*.xcresult`。



## iOS1 架构重构阶段 2 · 群公告横幅与详情观察

- `WDT_IOS1_REFACTOR_GROUP_ANNOUNCEMENT_OBSERVATION_20261110`。聊天横幅订阅当前群的当前公告，群公告详情独立订阅指定公告或最新项。退出三个群公告与入群申请字段的全局转发。入群申请集合仍参与原同步和头像投影，当前没有直接的视图消费方。
- `ContactStore.swift` 按群和公告标识提供投影。`ChatViewLayout.swift` 与 `ChatViewReply.swift` 保留公告 ID 变化时恢复横幅及记录诊断。`ChatConversationSheets.swift` 保留详情、读人数权限、标记已读与编辑入口。
- iOS 26.5 基线 7 项、候选 8 项全过。新增用例验证其他群不唤醒、当前公告和选中详情分离、当前项清空及无全局转发。7 张聊天截图逐像素一致，最低部署版本 15.0。结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2n-*.xcresult`。



## iOS1 架构重构阶段 2 · 通讯录同步与通话就绪状态

- `WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110`。通讯录加载与错误由目录页订阅。聊天通话入口、通话详情及联系人选择观察对应黑名单身份与好友关系就绪状态。通讯录同步和错误退出 AppState 转发。
- `ContactStore.swift` 持有发布值和原好友就绪判定。`ContactsViews.swift`、`ChatViews.swift` 与 `FilesRTCViews.swift` 订阅。原加载、重试、空态、通话资格和权限判断继续沿用原入口。联系人列表、备注和群资料三个字段仍有旧观察者。
- iOS 26.5 基线 7 项、候选 8 项全过。新增用例验证同步开始、就绪、错误和无全局发布，以及错误消息不影响通话就绪。3 张联系人和聊天截图逐像素一致，最低部署版本 15.0。结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2o-*.xcresult`。



## iOS1 架构重构阶段 2 · 群详情与目录观察

- `WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110`。群资料详情、编辑、成员和管理页、群公告详情及截图入口按群 ID 订阅。群目录与联系人入口计数直接使用发布的群列表，继续保留原群权限、同步与路由。
- `ContactStore.swift` 提供按群 ID 的发布值，`GroupDetailMembers.swift` 复用挂载视图观察。群资料过渡转发保留到聊天别名与转发入口迁完。
- iOS 26.5 基线 7 项、候选 8 项全过。新增挂载用例验证忽略其他群、选中群变化及移除。7 张截图逐像素一致，最低部署版本 15.0。结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2p-*.xcresult`。



## iOS1 架构重构阶段 2 · 群聊与转发入口观察

- `WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110`。群聊及消息行观察相关群，保留精确群与会话按群 ID、频道 ID、名称的原匹配顺序。群来源资料页按群观察。群转发、群邀请和群计数入口使用群目录发布。群资料退出 AppState 全局转发。
- `ContactStore.swift`、`GroupDetailMembers.swift`、`AppState+GroupDetailProjection.swift` 共用投影与匹配。`ChatViews.swift`、`MessageBubble.swift`、`ConversationViews.swift` 以及相关资料、成员、转发、截图页面接入。原群权限、成员投影、读取和写入路径保留。
- iOS 26.5 基线 8 项、候选 9 项全过。新增测试验证精确和别名选择次序、忽略无关群及无全局发布。7 张截图逐像素一致，最低部署版本 15.0。结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2q-*.xcresult`。



## iOS1 架构重构阶段 2 · 语音消息播放观察

- `WDT_IOS1_REFACTOR_VOICE_PLAYBACK_OBSERVATION_20261110`。正在播放的 ID 和播放进度迁入 `VoiceMessagePlaybackStore`。语音气泡按消息 ID 接收等值去重的播放快照，其他气泡与 AppState 不再收到计时更新。
- `AppState+VoiceMessagePlayback.swift` 保留音频会话、播放、暂停、停止、文件缓存和代际检查。仅改变发布对象，`AppState.swift` 持有专用 Store，`ChatMediaBubbleViews.swift` 接入局部快照。
- iOS 26.5 基线 7 项、候选 8 项全过。新增用例验证进度、暂停、停止、其他语音消息和 AppState 隔离。最低部署版本 15.0。结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2r-*.xcresult`。


## iOS1 架构重构阶段 2 · 联系人目录和备注观察

- `WDT_IOS1_REFACTOR_CONTACT_PRESENTATION_OBSERVATION_20261110`。承接 `95880a2bd740e41b558cbd8fe04caafe38911235`。核对 `BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`，iOS1 导入 tree 保持 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- `ContactStore.swift:266–282` 发布等值去重的联系人和备注快照。通讯录 `ContactsViews.swift:304–309` 和会话列表 `ConversationViews.swift:218–225` 继续延迟重建缓存，等存储提交后读取；`ChatViews.swift:356–364` 的已解锁聊天订阅快照，保留原发件人、标题和引文投影。尚未迁完的入口继续通过兼容转发刷新。
- `IdentityContactPresentationTests.swift:39–81` 关闭全局转发并挂载真实通讯录，验证写入、清除备注和新增联系人后三次分组更新。替代 `IdentityPresentationTests.swift:355` 对旧监听方法名的断言，保留原展示合同断言。
- iOS 26.5：基线 6 通过 / 2 失败，候选 7 通过 / 2 失败，新增用例通过，8 张截图逐像素一致。既有两项仍在相同断言失败，HTTP 的一个实际会话标题不同，严格断言值对照未通过；见 `docs/REFACTOR_FINDINGS.md` 和 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2s-*`。最低部署版本 15.0。
- 回退：反向应用本批提交。无数据迁移。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立 iOS 审查待进行。


## iOS1 架构重构阶段 2 · 个人资料与联系人选择

- `WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110`。承接 `8105fc8c86e43a50b76efe773d9f6e5f661b01d9`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。视图直接观察挂载期间的联系人和备注快照，继续通过原 resolver 解析当前登录作用域的名字和头像。
- `ContactCommonRows.swift:4–19` 提供目录快照容器；`ContactUserProfile.swift:102–106,576–580` 用于资料和分享；`QuickAddViews.swift:246–250,431–435` 用于建群和发起单聊；`ChatComposerPanels.swift:638–642` 用于发送联系人名片。保留现有群、黑名单、好友申请、导航与提交逻辑。
- iOS 26.5 基线和候选各 8 项全过，覆盖实际目录打开资料、备注和自身排除、两类快捷入口路由、资料合并、群资料开单聊和联系人卡片确认。最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2t-*.xcresult`。
- 回退：反向应用本批提交。无数据迁移。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立 iOS 审查待进行。


## iOS1 架构重构阶段 2 · 部门与群成员入口观察

- `WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110`。承接 `ef06b4c35e9596e3a20aec9e57a76831a5640d98`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。部门管理、部门邀请、群邀请和禁言相关入口按页面挂载观察联系人和备注。
- `DepartmentManagementSheets.swift:45–49,359–363`、`GroupMemberManagementViews.swift:697–699`、`GroupMuteListViews.swift:38–40,115–116,166–167,254–258`。禁言名单向行传入原解析器算出的显示名，解除禁言确认继续使用同一解析函数。保留群快照、权限、成员搜索与筛选、提交和重试入口。
- iOS 26.5 基线和候选各 7 项全过，7 张聊天截图逐像素一致。部署目标 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2u-*.xcresult`。
- 回退：反向应用本批提交。无数据迁移。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立 iOS 审查待进行。


## iOS1 架构重构阶段 2 · 搜索与通话联系人观察

- `WDT_IOS1_REFACTOR_SEARCH_AND_CALL_CONTACT_OBSERVATION_20261110`。承接 `21100cf26386abd49244fdca7e454dc90d621e4f`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。当前源码基线的 iOS1 tree 为 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- `ConversationListSearch.swift` 的联系人搜索区块接收目录快照，行读取当前备注解析值。原查询、精确身份匹配、结果过滤、字段高亮和选择路径保留。`FilesRTCViews.swift` 的通话详情和拨号联系人选择只订阅联系人数组，继续用现有黑名单和通话就绪投影判断按钮状态。
- iOS 26.5 基线及候选各 7 项全过。验证搜索返回、显示和安全过滤、通话记录存储与归属、通讯录动态更新。构建部署目标 15.0，结果在 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2v-*`。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 聊天弹层联系人观察

- `WDT_IOS1_REFACTOR_MESSAGE_SHEET_CONTACT_OBSERVATION_20261110`。承接 `a8cf49c2fe91992dcaaf68c9a31407cedad38dc5`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- `ReadReceiptSheet.swift`、`ChatMessageActionViews.swift`、`ChatConversationSheets.swift`、`MessageActionSheets.swift` 的回执、回应、消息预览、用户快捷操作、置顶和举报入口按挂载订阅联系人展示。回执与回应行接收同一解析器的显示名。测试中的显示名来源检查随实际调用位置调整。
- iOS 26.5 基线和候选均 7 通过、1 失败，原备注源码测试失败断言逐条一致。7 张截图逐像素一致，最低部署版本 15.0。结果见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2w-*`。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 已读明细权限观察

- `WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110`。承接 `5d77db8642eb51d935289a41fedb4ab2650321d7`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- `AppState.swift` 与 `AppState+ReadReceiptPresentation.swift` 将会话授权和失效代次交给独立 Store。权限判定仍使用原账号、租户、登录代次、企业角色和配置条件。`AppState+MessageSidecarSync.swift` 比较同一授权版本与作用域，保留迟到响应围栏。
- `MessageBubble.swift` 中可显示读数的群消息标签，以及 `ReadReceiptSheet.swift` 的群回执详情，直接观察对应会话权限。`DomainStoreTests.swift` 验证授权、重复授权、单会话撤权和全量失效，权限更新不单独触发 AppState 广播。AppState 发布属性降到 97。
- iOS 26.5 基线 7 项、候选 8 项全过，7 张截图逐像素一致。补充的迟到响应验证通过。回应合并测试仍复现既有请求次数波动，实际 2 次、期望 1 次，人员和回应内容断言通过。见 `docs/REFACTOR_FINDINGS.md` 和 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2x-*`。最低部署版本 15.0。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 聊天气泡联系人展示

- `WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110`。承接 `a72fce092d736ec2af6fe1c1ab4cf46d24b39743`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- `ContactCommonRows.swift` 将页面收到的联系人快照传到视图子树。`ChatViews.swift`、`ChatBubbleTextViews.swift`、`ChatBubbleMetadataViews.swift` 与 `MessageBubble.swift` 让引文、名片和通话记录卡片消费同一份快照。名片身份、备注别名优先级、本人排除、拨号目标解析及引文回退沿用原逻辑。
- iOS 26.5 基线 8 项、候选 9 项全过。新测试用场景内窗口挂载引文及名片，停用 AppState 全局转发后验证写入和清除备注、变更和恢复联系人名称均触发实际重绘。7 张既有截图逐像素一致。最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2y-*`。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 移除联系人全局转发

- `WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110`。承接 `d2cab1c1a6a87accc0f1e7ff0081ad2505aa035e`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- `ChatForwardViews.swift`、`GroupSharingViews.swift`、`ConversationListRows.swift` 的消息转发、文件转发和单聊操作菜单挂载时直接订阅目录。`ContactStore.swift` 与 `AppState+RuntimeBindings.swift` 删除联系人和备注的过渡转发。保留其他域各自的订阅。
- `ConversationViews.swift` 用页面已处理的群和联系人快照过滤 Combine 重放，避免 SwiftUI 重订阅把同一快照再次排入列表缓存重建。改动前的千会话用例持续高 CPU 并在主线程采样中反复重订阅，约 96 秒后取消。候选约 4 秒执行到结束，仍复现原有三条拖拽期间重建和交互状态断言，见 `phase1h-*` 与 `phase2z-*`。
- iOS 26.5 共同比较基线和候选均 6 通过、1 失败。原好友关系同步提示失败断言一致。改写的隔离用例通过，联系人和备注更新只发给目录订阅，不重绘审批视图，也无 AppState 广播。挂载的通讯录、聊天名片和引文正常更新。7 张共有截图逐像素一致，构建最低版本 15.0。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 文件配置和通话授权快照

- `WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110`。承接 `f7ce3c56b4e14bdd4086219895091478e69e07ff`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- `FileStore.swift` 同时持有上传配置和通话授权的作用域。收到新作用域下相同的配置值仍发布新授权。回执开关修改仅更新配置字段，保留现有授权。换作用域、请求失败和数据重置沿用原撤权条件；撤权同样有明确的快照。
- `AppState.swift`、`AppState+ConversationsHistory.swift`、`AppState+FilesAttachments.swift` 与 `AppState+RemoteAuthState.swift` 使用同一存储。原有同步、来电、设备上报和权限判断继续使用原入口。本批保留过渡转发供下一批迁移消费者。
- iOS 26.5 基线 6 通过、1 失败，候选 7 通过、1 失败。原通话授权 ABA 用例的失败断言一致。新增用例验证不同作用域收到同值配置、撤权和回执独立更新。7 张共有截图逐像素一致。构建最低版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2aa-*`。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 移除文件配置全局转发

- `WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110`。承接 `3f1f8774ef83bc29a913d25b7d27b94784615ad1`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- `FileStore.swift` 和 `ChatAttachmentDetail.swift` 提供按字段等值去重的配置订阅。附件确认从所收到的配置显示限制，发送时重新检查当前限制。聊天时间线和回执弹层直接订阅回执开关，消息菜单订阅配置，聊天工具和通话记录详情订阅授权作用域与语音/视频能力。`AppState+RuntimeBindings.swift` 移除 FileStore 的最后一条全局转发。
- iOS 26.5 基线与候选各 8 项全过。覆盖配置同值跨作用域授权、附件进度和回执开关隔离、已有群回执授权与拒绝、聊天工具入口。7 张共有截图逐像素一致。最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ab-*`。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 聊天历史与加好友观察

- `WDT_IOS1_REFACTOR_CHAT_AVAILABILITY_OBSERVATION_20261110`。承接 `7a44351e8827c63ae4a2cbf5ce8dbc3d13b9297a`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- `ConversationStore.swift` 的会话可用状态快照包含历史加载、失败或提示、发消息限制、好友申请进度和申请上下文，按会话 ID 发布且去重。`ConversationStore+Lifecycle.swift` 用字段发布替换原申请上下文的手动全局变化信号。`ChatViews.swift` 在打开的聊天页订阅。
- `AppState+RuntimeBindings.swift` 仅继续兼容转发会话数组变化。历史状态、好友申请状态和从会话数组导出的未读总数不再有单独的全局转发。
- iOS 26.5 基线 7 项、候选 8 项全过。新增用例验证非当前会话不会唤醒订阅、当前会话五种字段和结束动作通知、会话数组仍可触发兼容刷新。7 张共有截图逐像素一致。最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ac-*`。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 聊天会话与返回未读观察

- `WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110`。承接 `22554b171e4d346aa2dbd7c51069227ca770c293`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- `ConversationStore.swift` 按 ID 发布会话展示快照。与 `AppState+ConversationsHistory.swift` 共用系统会话回退，精确 ID 优先，仍按原顺序选择系统会话。`ChatViews.swift` 中的聊天页直接订阅当前会话，消息新增、撤回和历史锚点仍由已有时间线入口处理。
- `ChatViewHeaderAndStatus.swift` 的返回角标独立订阅未读总数，继续排除当前未静音会话自己的未读数。其他会话的未读变化可独立更新工具栏。
- iOS 26.5 基线 7 项、候选 8 项全过。新增挂载用例关闭 AppState 转发，验证群聊标题和其它会话未读角标独立更新。7 张共有截图逐像素一致，最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ad-*`。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 群目录、置顶和会话操作观察

- `WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110`。承接 `2276ffdf982c4d718afb5af5937fe7ac74e54c40`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- `ContactGroupList.swift` 接收群会话元数据快照，目录仍按原 ID/名称及顺序选择会话，未读数实时刷新。群列表无需加载消息正文。`ContactGroupDetail.swift` 订阅当前会话的置顶状态和未撤回置顶消息数，`ConversationListRows.swift` 的操作菜单直接观察对应会话。
- 群免打扰仍由群资料提供，删除与该状态无关的会话查找。历史截图宿主固定使用原精确会话 ID。验证复用同一场景窗口测试工具。
- iOS 26.5 基线 7 项、候选 8 项全过，挂载用例关闭全局转发后验证群目录未读更新和恢复。7 张共有截图逐像素一致，最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ae-*`。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 转发、名片分享和快捷单聊的会话观察

- `WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110`。承接 `7e87b96689a6071e5907acbc90a3a40641bce362`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- `ChatForwardViews.swift`、`GroupSharingViews.swift` 和 `QuickAddViews.swift` 接收会话元数据，保留群/好友合并、原排序、搜索字段、身份和旧会话匹配。候选不再因纯消息正文变化重建。名片分享继续使用含消息的会话快照供早期记录解析对端，排除系统会话。
- iOS 26.5 基线与候选各 7 项全过。强化转发用例覆盖无好友记录的历史会话，验证元数据候选与原候选完整相同。7 张共有截图逐像素一致，最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2af-*`。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 会话列表与聊天弹层观察

- `WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110`。承接 `f589a155c6dd7e6895a7055fae7cfe5f3b2e54e3`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- `ConversationViews.swift` 从现有会话订阅读取空态，并独立订阅未读总数驱动筛选角标。顺序和滚动延迟重建保留。`ChatViewLayout.swift` 与 `ChatConversationSheets.swift` 的置顶和回执弹层按对应会话刷新；置顶和时间线复用原过滤条件。
- `ChatMessageActionViews.swift` 的消息操作预览订阅所在会话，引用正文、撤回或删除变化仍用原解析。时间线气泡的间接依赖待继续迁移，AppState 兼容转发仍保留。
- iOS 26.5 基线 7 项、候选 8 项全过。新增挂载用例关闭 AppState 转发后验证会话列表未读显示及已打开置顶弹层随置顶和取消置顶刷新。7 张共有截图逐像素一致，最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ag-*`。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 时间线引用与成员观察

- `WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110`。承接 `3ddf79df292399174c942aabcc14cf8b7f9c23dc`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 聊天页把当前会话的消息快照、成员和通话展示输入传给子视图。引用只在存在引用正文时进入独立视图，按消息 ID 或序号查找原序列中首个匹配项。共享索引按消息数组的存储复用，原处理提示、撤回/删除和回退展示保留。
- iOS 26.5 基线 7 项、候选 8 项全过。新增挂载测试停用全局转发，验证 ID 与序号同时匹配时保留原顺序，撤回和恢复来源消息时引用刷新。7 张共有截图逐像素一致，最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ah-*`。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。


## iOS1 架构重构阶段 2 · 撤除最后一条会话数组转发

- `WDT_IOS1_REFACTOR_CONVERSATION_RELAY_RETIREMENT_20261110`。承接 `188ea043153b2e304459f07ea432d60a8835f8cc`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 删除 `AppState+RuntimeBindings.swift` 的域 Store 全局转发绑定及 AppState 中的调度状态。设备撤销继续用原系统通知绑定。会话列表、当前聊天、角标、群资料和弹层各自观察已有本域投影。
- 批量转发的会话订阅使用发布值更新来源和候选，避免 `@Published` 在存储更新前发出时误用旧数据。相同转发状态无需重复发布。实测收到撤回快照但存储仍为原值时，转发来源按新快照处理。
- iOS 26.5 基线与候选各 11 项全过，7 张共有截图逐像素一致。验证同作用域换票和历史合并、未读投影、挂载聊天/群目录/会话列表/置顶/引用刷新、会话数据只通知对应订阅方。构建最低版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ai-*`。AppState 仍有 97 个发布属性待继续分域。
- 回退采用本批完整逆向差分。NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=0；PROD_MUTATION=false；AUTO_ROLLBACK=false。独立审查待进行。



## iOS1 架构重构阶段 2 · 群禁言名单与设置观察

- `WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110`。承接 `491146a62209aac6ea4090e151df6d1cb3ad8a04`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 群禁言名单、加载、成员操作和错误迁到 GroupModerationStore。名单、添加成员选择页和全员禁言设置页各自订阅对应群的快照。头像投影和权限、接口、禁言生效判断沿用现有逻辑。
- 合并时同时迁移写入、头像投影、会话清理和三个页面的订阅。以 `85e5e3df9ae43bd7522abde561b9f3c781c9284f` 差分及标识为准。当前导航为 `BlueStoneIM/AppState.swift:245`、`BlueStoneIM/GroupMuteMode.swift:294–451`、`BlueStoneIM/Core/AppSupport/AppState+GroupMuteList.swift:20–205,252–288`、`BlueStoneIM/Core/AppSupport/AppState+GroupCreationAndSettings.swift:248–390`、`BlueStoneIM/Core/AppSupport/AppState+RealtimeGroupAndReadEvents.swift:269`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift:384`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+AvatarRealtimeAuthority.swift:157,538–542`、`BlueStoneIM/Features/Contacts/GroupMuteListViews.swift:36–167,244–286`、`BlueStoneIM/Features/Contacts/GroupModerationSettingsViews.swift:68–220`、`BlueStoneIMTests/HTTPPhonePolicyAndProfileProjectionTests.swift:90–178,760–800`。
- 名单加载及成员操作用独立请求标识核对结果与收尾归属。重置后迟到的旧成功响应不回填名单，也不清除当前操作。全员禁言版本冲突重新拉取群资料后再核对请求归属。
- iOS 26.5 基线 9 项通过、候选 11 项通过，两轮在原测试 `testMutationFailureRollsBackOptimisticMode` 有同一处旧断言失败。新增的订阅隔离和迟到请求回归均通过。7 张原聊天和群禁言横幅截图逐像素一致，最低部署版本 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2aj-*`。AppState 发布属性由 97 减至 91。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。




## iOS1 架构重构阶段 2 · 群描述与群主转让观察

- `WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110`。承接 `85e5e3df9ae43bd7522abde561b9f3c781c9284f`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 群描述与群主转让的防重和进度迁至 GroupModerationStore，成员操作页只订阅当前群的转让进度。原服务端版本、权限、幂等键及权威刷新路径继续生效。会话重置后的旧请求失去写入和清理归属。
- 整批应用新增订阅、原状态删除及清理调整。以标识及本节所在提交差分为准。当前导航为 `BlueStoneIM/GroupMuteMode.swift:318–353,440`、`BlueStoneIM/AppState.swift:245`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift:384`、`BlueStoneIM/Core/AppSupport/AppState+GroupAdministration.swift:256–414,463–489`、`BlueStoneIM/Features/Contacts/GroupMemberManagementViews.swift:512–526,598–618`、`BlueStoneIMTests/HTTPCaptchaPasswordAndSocialContractTests.swift:662–694`。
- iOS 26.5 基线 9 项、候选 10 项全过。新增测试覆盖同群不同操作、其他群与会话重置后的迟到清理。7 张原聊天和群禁言横幅截图逐像素一致，最低部署版本 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ak-*`。AppState 发布属性由 91 减至 89。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · 群内自己的昵称与成员资料

- `WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110`。承接 `4d91c027a4c0df28e101a3e83b8adbe5e00b1044`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- ContactStore 按现有账号、租户及群键一次发布昵称与成员资料。群详情只订阅昵称行，成员管理与聊天只订阅当前群成员投影。资料版本检查、退群和会话清理、头像投影、历史消息与引用快照合同沿用原路径。
- 合并时一起迁移写入、清理和页面订阅。以标识及本节所在提交差分为准。导航为 `BlueStoneIM/AppState.swift:251`、`BlueStoneIM/ContactStore.swift:234,720,735–781`、`BlueStoneIM/Core/AppSupport/AccountSession/AppState+GroupProfileEditing.swift:139–147,286–322`、`BlueStoneIM/Core/AppSupport/AppState+GroupMembershipLifecycle.swift:220`、`BlueStoneIM/Core/AppSupport/GroupFileMapping/AppState+GroupAuthorityProjection.swift:249–259`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+AvatarRealtimeAuthority.swift:459,616`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift:408`、`BlueStoneIM/Features/Chat/ChatViewTimeline.swift:14–40,151–154`、`BlueStoneIM/Features/Contacts/ContactGroupDetail.swift:97–114,213`、`BlueStoneIM/Features/Contacts/GroupMemberManagementViews.swift:37–47,166–189`、`BlueStoneIMTests/IdentityContactPresentationTests.swift:292–336`。
- iOS 26.5 基线 10 项、候选 11 项通过，同一旧用例 `testGroupMemberListSelfMemberHydratesNicknameOutsideFirstPageAndKeepsGenerationFence` 对历史全局名快照的断言失败。新增挂载用例验证当前群昵称更新聊天行、其他群不影响当前聊天、移除投影恢复显示。7 张原有截图逐像素一致，最低部署版本 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2al-*`。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · 企业目录搜索与入企进度

- `WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110`。承接 `64aaa77c89e6c7755557b29b700df42efd1fe988`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 企业目录区域订阅独立快照，保留入企权限、审批状态、企业禁用投影和既有切换完成回调。清空、重搜或重置使旧搜索失去发布和清理资格。入企请求按企业和会话核对进度归属，清空搜索时仍保留在途入企进度。
- 整批应用 Store、页面订阅、权限投影和会话清理。以标识及本节所在提交差分为准。导航为 `BlueStoneIM/AppState.swift:391`、`BlueStoneIM/Core/AppSupport/AccountSession/AppState+EnterpriseMembership.swift:62–292,323–421`、`BlueStoneIM/Core/AppSupport/AppState+PresentationPolicy.swift:189`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift:411`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+WorkspaceAccessErrors.swift:395`、`BlueStoneIM/Core/AppSupport/TenantSession/AppState+WorkspaceAndTenantAuthority.swift:119–130`、`BlueStoneIM/Features/Me/EnterpriseSwitcherView.swift:153,173–268`、`BlueStoneIMTests/HTTPRegistrationSubmissionTests.swift:8–57,744–788`。
- iOS 26.5 基线 5 项、候选 7 项通过，`testEnterpriseCodeUserFacingCopyDoesNotRevealCanonicalLength` 同一条原有源码文案断言失败。新增用例通过，覆盖真实搜索入口的清空和迟到响应，以及同企业旧请求清理隔离。最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2am-*`。AppState 余 83 个发布属性。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · 个人邀请码观察

- `WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110`。承接 `a0f70fc0e81cb62fa9f212836935c392be3ad4e5`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 我的页面只让邀请码卡片订阅结果、进度和错误。成功与失败均一次发布完整快照，保留原账户、租户、会话和最新请求校验及卡片的隐藏、复制与重试规则。
- 一起迁移请求、身份清理及页面观察。以标识及本节所在提交差分为准。导航为 `BlueStoneIM/AppState.swift:413–418`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift:430–463,483,498–505,548–592`、`BlueStoneIM/MeSettingsViews.swift:27–48,62`、`BlueStoneIMTests/HTTPRegistrationAuthorityAndInviteTests.swift:302–336`。
- iOS 26.5 首轮基线 8 项、候选 9 项通过，身份测试同样因后台请求先使用了顺序响应队列而失败。该用例改用已有的按端点分配响应的夹具后，候选 10 项全部通过。新增快照用例验证加载和结果一致，并且清空时不通知 AppState。最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2an-*`。AppState 余 80 个发布属性。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · 协议正文和弹层请求归属

- `WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110`。承接 `a4cb7038d772cc20a9dccaed04ec314646fc94b8`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- AppState 返回本次正文或错误，弹层管理加载和重试。移除未读取的全局清单、共享错误及加载锁。关闭重开与重试以请求标识隔离迟到结果。错误在弹层内保留原提示与重试入口，移除重复的全局提示。保留原固定协议地址、请求上下文、内嵌同源限制及同意交互。
- 合并时一起迁移加载、弹层和测试，移除已无调用的 URL 转发。以标识及本节所在提交差分为准。导航为 `BlueStoneIM/AppState.swift:410`、`BlueStoneIM/Core/AppSupport/AccountSession/AppState+AppPolicyAndLegal.swift:16`、`BlueStoneIM/Core/AppSupport/AccountSession/AppState+AuthenticationProfileWorkspace.swift:374–387`、`BlueStoneIM/Core/Networking/DTO/RemoteLegalModels.swift:183–187`、`BlueStoneIM/Features/Auth/AuthLegalViews.swift:241–360`、`BlueStoneIMTests/PreloginBootstrapStartupTests.swift:416–460`、`BlueStoneIMTests/HTTPLegalTenantEntryAndDiagnosticsTests.swift:8–24,724–744`。
- iOS 26.5 基线 9 项、候选 10 项全过。新增并发协议请求验证错误隔离。路由用例扩展重试和同协议关闭重开后迟到结果的覆盖。最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ao-*`。AppState 余 77 个发布属性。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · 搜索失效事件订阅

- `WDT_IOS1_REFACTOR_SEARCH_INVALIDATION_OBSERVATION_20261110`。承接 `074fe85ecb627cc3676e49fe1782b2afb05ad497`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 以 SearchInvalidationStore 逐条投递已验租户和版本的事件，移除 AppState 的事件和版本号发布。全局及会话内搜索直接消费事件值，同批事件可以逐条处理。保留缓存清理优先、结果匹配、分页过滤和租户重置。
- 合并时同步迁移事件源和两个结果页。以标识及本节所在提交差分为准。导航为 `BlueStoneIM/AppState.swift:551`、`BlueStoneIM/Core/AppSupport/AppState+SearchConversationSettings.swift:17–62,71–83`、`BlueStoneIM/ConversationViews.swift:272–276`、`BlueStoneIM/Features/Conversations/ConversationListSearch.swift:230`、`BlueStoneIM/Features/Chat/ChatViewLayout.swift:735–739`、`BlueStoneIM/Features/Chat/ChatViewNavigation.swift:168`、`BlueStoneIMTests/DomainFileLifecycleAndCallStoreTests.swift:135–198`。
- iOS 26.5 基线与候选各 8 项全过。扩展用例验证同批按序、去重、错租户拒绝、重置后可重新应用，以及 AppState 不发布。7 张聊天与群禁言横幅截图逐像素一致，最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ap-*`。AppState 余 75 个发布属性。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · 媒体重连局部刷新

- `WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110`。承接 `bb5bbba66b20881fb73feb718112dbd9b1ab34e7`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 实时连接确认后由 FileStore 发布重连序号，文件页、聊天缩略图、视频封面和附件详情直接订阅。保留文件页的 15 秒节流、缩略图失败重试及原缓存键，首次订阅采用当前值。
- 合并时一起迁移重连入口与媒体订阅。以标识及本节所在提交差分为准。导航为 `BlueStoneIM/AppState.swift:244,1272`、`BlueStoneIM/FileStore.swift:28–34`、`BlueStoneIM/Features/Files/FilesView.swift:33,219–235`、`BlueStoneIM/Features/Files/FilePreviewViews.swift:298–361`、`BlueStoneIM/Features/Chat/ChatAttachmentDetail.swift:45–58,263–291`、`BlueStoneIM/Features/Chat/ChatAttachmentThumbnailViews.swift:512–526,587–603`、`BlueStoneIM/Features/Chat/ChatMediaBubbleViews.swift:273–298`、`BlueStoneIMTests/AttachmentDownloadTests.swift:58–94`。
- iOS 26.5 基线 8 项、候选 9 项全过。挂载用例验证仅 FileStore 重连事件即可重试已失败的缩略图，AppState 无发布。缓存首帧、封面持久化和重连测试通过，7 张聊天截图逐像素一致。最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2aq-*`。AppState 余 74 个发布属性。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · 组织架构读取与刷新

- `WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110`。承接 `ec15b341289364d9f5c65a46543b5fcc5fa9ffda`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- OrganizationDirectoryStore 保存部门树、成员和身份索引、租户开关及加载和错误。底部导航、通讯录、部门树、部门成员与资料卡各自订阅对应投影。保留部门树权威优先、角色回退和头像处理。
- 会话重置清空组织快照。刷新使用独立请求标识和原会话校验，旧请求不能写入新快照或结束新加载。合并需同时应用数据、清理与视图订阅。
- 当前标识导航为 `BlueStoneIM/AppState.swift:417,427–431,598–610`、`BlueStoneIM/ApplicationPolicyScreens.swift:103,264`、`BlueStoneIM/BlueStoneIMApp.swift:470–481`、`BlueStoneIM/ContactsViews.swift:234–242,330,578–596`、`BlueStoneIM/Core/AppSupport/AppState+PresentationPolicy.swift:229–240,399`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+AvatarRealtimeAuthority.swift:447,595`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+OrganizationDirectorySync.swift:289–341,437–454,465,470–569`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift:414`、`BlueStoneIM/Core/AppSupport/TenantSession/AppState+WorkspaceAndTenantAuthority.swift:490`、`BlueStoneIM/Core/Networking/DTO/RemoteDirectoryModels.swift:256`、`BlueStoneIM/Features/Chat/ChatMessageActionViews.swift:590–599`、`BlueStoneIM/Features/Contacts/ContactUserProfile.swift:324–330`、`BlueStoneIM/Features/Contacts/DepartmentManagementSheets.swift:48–53,367–381`、`BlueStoneIM/Features/Contacts/OrganizationDirectoryViews.swift:4–39,45–63,145–154,203,247–270,300,338`、`BlueStoneIM/MeSettingsViews.swift:375–389`、`BlueStoneIMTests/IdentityContactPresentationTests.swift:338–387,424`。
- iOS 26.5 基线 7 项、候选 8 项全过。新增挂载测试验证部门计数只因本部门成员变化而刷新，成员索引可补全资料路径，重置清理旧数据和刷新归属。7 张聊天与群禁言横幅截图逐像素一致，最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ar-*`。AppState 余 69 个发布属性。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · 部门管理进度

- `WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110`。承接 `3c68ab2326b8b22bb537a3899665bc500132e0c8`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 部门与成员管理页直接观察 OrganizationDirectoryStore 的操作进度。保留输入、角色、租户及服务端入口校验。应用内串行执行已有互斥语义的管理操作，完成、刷新与错误均核对请求归属和当前会话。
- 整批应用写入口、会话重置与订阅。导航为 `BlueStoneIM/AppState.swift:432`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+OrganizationDirectorySync.swift:139–291,497–525`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift:414`、`BlueStoneIM/Features/Contacts/DepartmentManagementSheets.swift:5–17,62–73,393–402`、`BlueStoneIMTests/HTTPWorkspaceAndMessageSendTests.swift:8–42`、`BlueStoneIMTests/HTTPIntegrationRaceTestFixtures.swift:737–782`。
- iOS 26.5 基线 4 项、候选 5 项全过。新增测试通过实际创建入口验证重置前的成功响应不会刷新新会话、显示成功或清除当前进度。最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2as-*`。AppState 余 68 个发布属性。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · 启动叠层局部观察

- `WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110`。承接 `0f9d6c69098ca8f7795e1502c6bc8d541f9df192`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 启动叠层的图片、秒数及跳过状态一次发布。底部导航只接收展示布尔值，叠层收到倒计时。沿用原冷启动许可、会话及租户校验、时长与自动关闭。
- 整批应用计时、调试场景清理与 RootView 订阅。导航为 `BlueStoneIM/AppState.swift:401–404`、`BlueStoneIM/BlueStoneIMApp.swift:425–435,555–561,569–589`、`BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift:410,466–473,490–495,697–738`、`BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift:139`、`BlueStoneIMTests/DomainSplashCacheTests.swift:97–140`。
- iOS 26.5 基线 7 项、候选 8 项全过。验证倒计时和跳过更新不会发布到 AppState 或底部导航的显示投影，旧回调不会更新替代叠层。最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2at-*`。AppState 余 65 个发布属性。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · Face ID 保护与授权观察

- `WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110`。承接 `8de6ff0f1f3c38f3508365bfc347ad1555bb9227`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- BiometricAccessStore 一次提交设置与当前授权。聊天和文件预览分别订阅自己的授权结果，设置页面订阅当前设置。保留账号存储键、授权令牌校验、会话变动使旧验证失效及场景失活和后台清除已有授权的规则。
- 合并时同步迁移上下文重绑、场景事件与三个页面的订阅。当前标识导航为 `BlueStoneIM/AppState.swift:132–135,759–764,1063–1068`、`BlueStoneIM/ChatViews.swift:347–350`、`BlueStoneIM/Core/AppSupport/AccountSession/AppState+ProtectedContentAccess.swift:15–71,74–112,141,152,163–167`、`BlueStoneIM/Core/AppSupport/AppState+Realtime.swift:70,166`、`BlueStoneIM/Features/Files/FilePreviewViews.swift:17–20`、`BlueStoneIM/Features/Me/SecuritySettingsViews.swift:39–48,189–198,273`、`BlueStoneIMTests/DomainPresenceAndSplashTests.swift:12–39`。
- iOS 26.5 基线 7 项、候选 8 项全过。新增用例通过本地模拟认证验证聊天授权和撤销不通知文件预览或 AppState，既有同意、失败、账号切换和场景回归通过。7 张聊天与群禁言横幅截图逐像素一致，最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2au-*`。AppState 余 62 个发布属性。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · 实名认证提交结果

- `WDT_IOS1_REFACTOR_REAL_NAME_FORM_OBSERVATION_20261110`。承接 `eb7c95b790d80402efe11a4b331cd098148fc132`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 提交方法返回本次请求的成功或错误。表单用局部状态展示错误，只有输入仍匹配原请求时才写回。保留姓名与证件号校验、服务端状态映射、租户校验、Toast 及受理后的关闭行为。
- 整批迁移入口、表单与测试。当前标识导航为 `BlueStoneIM/AppState.swift:404`、`BlueStoneIM/Core/AppSupport/AccountSession/AppState+PhoneBinding.swift:15–20,325–369`、`BlueStoneIM/Features/Me/RealNameVerificationViews.swift:54,70–86,98`、`BlueStoneIMTests/HTTPAccountPolicyAndGroupLifecycleTests.swift:474–530`。
- iOS 26.5 基线 7 项、候选 8 项全过。新增测试验证两类本地校验错误分别返回且不会发送请求，服务端拒绝和认证门禁用例通过。最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2av-*`。AppState 余 61 个发布属性。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · 强制认证弹层路由

- `WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110`。承接 `0a4a5484729b3cfefd07113cc116912688f93842`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 提示、认证目的地和延后令牌由 ForcedAppPolicyAuthStore 一次更新。群审批页订阅排队提示，根弹层只订阅可展示路由。保留登录校验、手机和实名优先级，以及 UIKit 提示关闭后再打开全屏页的原等待时间。已取消的转换任务在等待后退出。
- 整批迁移路由、群审批页、根弹层与调试入口。当前标识导航为 `BlueStoneIM/AppState.swift:432–436`、`BlueStoneIM/BlueStoneIMApp.swift:437–481,674`、`BlueStoneIM/Core/AppSupport/AccountSession/AppState+AppPolicyAndLegal.swift:317–328,348–447`、`BlueStoneIM/Core/AppSupport/AppState+PresentationPolicy.swift:15–54`、`BlueStoneIM/Core/AppSupport/AppStatePolicySupport.swift:89,131–211`、`BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift:389–405`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift:328–348`、`BlueStoneIM/Features/Contacts/GroupModerationSettingsViews.swift:373–377`、`BlueStoneIMTests/HTTPAccountPolicyAndGroupLifecycleTests.swift:604,605,642–670,672–695,771,772`、`BlueStoneIMTests/HTTPVerificationContactAndRemarkTests.swift:108,180`。
- iOS 26.5 基线 7 项、候选 9 项全过。事件用例验证多个延后令牌、提示显隐和 AppState 不发布。挂载用例验证真实组件等待延后结束才显示系统提示。原全屏交接和服务端门禁用例通过。最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2aw-*`。AppState 余 59 个发布属性。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。



## iOS1 架构重构阶段 2 · 会话重新验证界面

- `WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110`。承接 `faf3988dad4226f90377c0629715a3efa5458faf`，`BASED_ON_CANONICAL_HEAD=b0a69f9f1b93315e488c7e1af6f6b97edd5c7320`。
- 工作台只订阅交互锁，覆盖层按表单标识挂载，表单订阅自己的进度与错误。原会话凭据保持在非发布状态。取消或重开后，旧表单的退出和提交只校验原标识，不能影响替代页。
- 保留在途请求单写者与原身份、数据库票据和路由提交校验。整批迁移入口与 UI。当前标识导航为 `BlueStoneIM/AppState.swift:105–109`、`BlueStoneIM/AuthViews.swift:63,74–84,166,171,178,191`、`BlueStoneIM/BlueStoneIMApp.swift:529–544,578–587`、`BlueStoneIM/Core/AppSupport/AccountSession/AppState+AuthenticationProfileWorkspace.swift:25–82,93–109,112–132,143,240,318,332–337,352–357,375`、`BlueStoneIMTests/HTTPHistoryDiagnosticsAndReauthenticationTests.swift:590–657`。
- iOS 26.5 基线 8 项、候选 9 项全过。覆盖身份相同的恢复、旧请求和表单收尾、账号 ABA、路由撤销、保护存储读回与局部反馈。7 张聊天与群禁言横幅截图逐像素一致，最低部署版本 15.0。见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ax-*`。AppState 余 56 个发布属性。
- 回退采用本批完整逆向差分。`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=0`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`。待固定 iOS reviewer 独立审查。


## iOS1 架构重构阶段 2 · 登录企业码挑战局部观察

- `WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110`。承接 `aed87cc9b9114bddb931d6c1cb9a1a460a492028`，`BASED_ON_CANONICAL_HEAD=554b5771af17b2ae49fe0c5bb8301782dc9751b4`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 409 企业码挑战表单直接订阅账号显示、提交进度和错误快照。密码和请求上下文保留在文件私有运行态，保留原登录世代检查和导航时的清理。
- `BlueStoneIM/AppState.swift` 152, 167。
- `BlueStoneIM/AuthViews.swift` 298–399, 403–406。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+PreAuthEnterpriseContext.swift` 15–54, 255–420。
- `BlueStoneIMTests/HTTPEnterpriseLoginAndCaptchaTests.swift` 54–112。
- iOS 26.5 模拟器基线 6 项、候选 7 项全过。新增用例经普通登录收到 409，验证无效企业码不发请求、清除错误只通知挑战表单以及取消返回。Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ay-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 企业优先验证局部观察

- `WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110`。承接 `400900890e55a18c6594d3b8bd1feb4b267f4082`，`BASED_ON_CANONICAL_HEAD=554b5771af17b2ae49fe0c5bb8301782dc9751b4`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 企业码表单直接观察验证进度和错误，登录注册页观察企业名称与 Logo。原上下文继续由登录与注册运行路径读取，令牌和路由快照不进入 UI 投影。保留原登录路由、App 与设备身份校验、代际和过期判断。
- `BlueStoneIM/AppState.swift` 163。
- `BlueStoneIM/AuthViews.swift` 204–287, 291。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+PreAuthEnterpriseContext.swift` 56–103, 106, 205–289。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+RememberedLoginAndEntry.swift` 264, 270。
- `BlueStoneIM/Core/AppSupport/AppState+PresentationPolicy.swift` 76。
- `BlueStoneIM/Features/Auth/AuthFlipView.swift` 86–191, 399, 406, 517, 523, 722–765。
- `BlueStoneIM/Features/Auth/LoginRegisterViews.swift` 414–419, 421。
- `BlueStoneIMTests/HTTPEnterpriseLoginAndCaptchaTests.swift` 235。
- `BlueStoneIMTests/HTTPProductionRoutingAndEnterpriseContextTests.swift` 567–623。
- iOS 26.5 模拟器基线 9 项、候选 10 项全过。新增用例覆盖无效输入、进度、品牌呈现与清除，相关用例覆盖嵌套会话身份、企业邀请和普通登录 409。Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2az-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 登录企业选择与滑动验证观察

- `WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110`、`WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110`。承接 `221492178eee0a02b108a5d12fc46c55aa06d492`，`BASED_ON_CANONICAL_HEAD=554b5771af17b2ae49fe0c5bb8301782dc9751b4`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 登录企业选择直接观察提示和默认企业，设置卡片只观察默认企业 ID。滑动验证由弹层直接观察，原等待者的替换、取消与完成顺序和平台请求保持。
- `BlueStoneIM/AppState.swift` 167, 168。
- `BlueStoneIM/BlueStoneIMApp.swift` 589–600。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+AuthenticationProfileWorkspace.swift` 88, 388–396。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+LoginTransportAndWorkspace.swift` 103, 107, 117, 121, 239, 259, 308。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+RememberedLoginAndEntry.swift` 299, 313, 322, 358, 375, 436。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift` 38, 570, 571, 634, 635, 681, 682。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkspaceSelection.swift` 15–36, 102, 117, 124, 148, 169, 188, 193, 207, 213, 318, 328, 337, 347, 351, 366, 367, 377, 384, 388。
- `BlueStoneIM/Core/AppSupport/AppStateSlideCaptchaSupport.swift` 1–4, 88–133。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugAvatarFixtures.swift` 345。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugGroupFixtures.swift` 152, 471。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift` 138, 325。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RegistrationResolution.swift` 40, 51, 671。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteRegistrationSnapshotSync.swift` 274。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+WorkspaceAccessErrors.swift` 426, 429, 558, 570。
- `BlueStoneIM/Core/Networking/DTO/RemoteAuthChallengeModels.swift` 193。
- `BlueStoneIM/Features/Auth/AuthCaptchaViews.swift` 7, 32, 164。
- `BlueStoneIM/Features/Auth/AuthWorkspaceViews.swift` 62–68, 70, 77, 120, 156, 169。
- `BlueStoneIM/Features/Me/EnterpriseSwitcherView.swift` 93, 117–173。
- `BlueStoneIMTests/HTTPCaptchaPasswordAndSocialContractTests.swift` 8–46。
- `BlueStoneIMTests/HTTPWorkspaceSessionRefreshTests.swift` 124, 142–179, 214。
- iOS 26.5 模拟器基线 8 通过、1 失败，候选 10 通过、1 失败。原测试 `testWorkspaceSelectionRefreshesExpiredPlatformTokenBeforeEnteringTenant` 的三处断言一致。新增用例验证平台默认企业清除、验证替换与续接的观察隔离。7 张聊天对照截图逐像素一致。Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2ba-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 提示条与会话列表导航观察

- `WDT_IOS1_REFACTOR_TOAST_OBSERVATION_20261110`、`WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110`。承接 `fb0fb76620102945d0a8f1e23732fe40e8fd7150`，`BASED_ON_CANONICAL_HEAD=554b5771af17b2ae49fe0c5bb8301782dc9751b4`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 保留既有 toast 写入入口、替换计时、动效和调试截图保留条件。根提示条及来电提示直接订阅提示文字。会话列表直接观察公告显示、群退出返回信号和推送打开请求，保留授权检查、请求标识和首次进入时读取。
- `BlueStoneIM/AppState.swift` 386–399, 176。
- `BlueStoneIM/BlueStoneIMApp.swift` 563–582。
- `BlueStoneIM/ConversationViews.swift` 128–134, 137, 151, 160, 190, 319, 325, 356, 363, 368。
- `BlueStoneIM/Core/AppSupport/AppState+GroupMembershipLifecycle.swift` 15–30, 122, 198。
- `BlueStoneIM/Core/AppSupport/AppStateLifecycleSupport.swift` 34–62。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+CallSystemEvents.swift` 114, 156, 189–192。
- `BlueStoneIM/Features/Calls/CallScreenViews.swift` 68–79。
- `BlueStoneIM/Features/Conversations/ConversationListHeaderViews.swift` 86, 145。
- `BlueStoneIMTests/DomainChatViewportAndGestureTests.swift` 12–36。
- `BlueStoneIMTests/IdentityContactPresentationTests.swift` 249–275。
- iOS 26.5 模拟器基线 7 项、候选 9 项全过。新增用例验证提示替换与到时清除，及实际挂载列表打开通知会话、旧请求确认不会清除新请求和返回列表。7 张聊天对照截图逐像素一致。Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bb-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 注册确认与记住登录观察

- `WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110`、`WDT_IOS1_REFACTOR_REMEMBER_LOGIN_PREFERENCE_OBSERVATION_20261110`、`WDT_IOS1_REFACTOR_CACHE_CLEARING_RUNTIME_FLAG_20261110`。承接 `33705c98bfe240e981e3156251c1f933ed3b5e3e`，`BASED_ON_CANONICAL_HEAD=554b5771af17b2ae49fe0c5bb8301782dc9751b4`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 注册提示与按钮直接观察确认快照，成对更新一次发布。记住登录行观察已保存的选择，仍经原入口写偏好并清理对应凭据。清理缓存防重标记只在运行时使用。
- `BlueStoneIM/AppState.swift` 112–119, 120–123, 124。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+RegistrationAndRecoveryUI.swift` 15–42。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+RememberedLoginAndEntry.swift` 15–24, 41, 54。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift` 532, 579。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift` 26, 35, 40。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RegistrationResolution.swift` 208。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteRegistrationSnapshotSync.swift` 138, 142, 286, 318, 328, 345, 484, 538, 645, 656, 667, 683。
- `BlueStoneIM/Features/Auth/AuthFlipView.swift` 48, 55, 654–673, 460。
- `BlueStoneIM/Features/Auth/AuthFormControls.swift` 252–261, 264。
- `BlueStoneIM/Features/Auth/LoginRegisterViews.swift` 314, 321, 543–556, 162。
- `BlueStoneIMTests/HTTPRegistrationSubmissionTests.swift` 716–724。
- `BlueStoneIMTests/HTTPRememberedLoginTests.swift` 24–36。
- iOS 26.5 模拟器基线和候选均 7 通过、1 失败，注册持久化失败用例的原路由断言一致。实际确认链按序发布待确认和成功，记住登录切换只通知开关。开启减弱动态效果后，待确认和超时两张整屏截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bc-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 启动恢复与远程同步观察

- `WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110`。承接 `41a36e0245c411cdb898c5c2de1e0bc8cf1662d1`，`BASED_ON_CANONICAL_HEAD=554b5771af17b2ae49fe0c5bb8301782dc9751b4`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 启动动画观察恢复与启动遮罩。会话列表观察同步与分页状态，通讯录和资料页只观察初始加载。原会话作用域、凭据轮换、分页重试与错误处理规则保持。
- `BlueStoneIM/AppState.swift` 129–139, 1066, 1106, 1160, 1195, 1310。
- `BlueStoneIM/BlueStoneIMApp.swift` 489, 493, 509, 661–667。
- `BlueStoneIM/ContactsViews.swift` 256–260, 388, 394, 669, 671。
- `BlueStoneIM/ConversationViews.swift` 131–135, 141, 161, 166, 381, 402, 408, 413, 439, 446, 449。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift` 27, 29, 43, 48, 408, 557, 627, 665。
- `BlueStoneIM/Core/AppSupport/AppState+ColdLaunchSessionRestore.swift` 11, 16, 22, 23。
- `BlueStoneIM/Core/AppSupport/AppState+InboxAndDevices.swift` 241。
- `BlueStoneIM/Core/AppSupport/AppState+RealtimeEventDispatch.swift` 379。
- `BlueStoneIM/Core/AppSupport/AppState+RemoteErrorHandling.swift` 20, 21, 24。
- `BlueStoneIM/Core/AppSupport/AppStateLifecycleSupport.swift` 15–48。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugAvatarFixtures.swift` 337, 338, 339, 340。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugGroupFixtures.swift` 144, 145, 146, 147, 463, 464, 465, 466。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift` 130, 131, 132, 133, 317, 318, 319, 320。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+CachedRemoteSnapshot.swift` 82, 83, 84, 116, 117, 118。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+PrimarySnapshotSync.swift` 21, 53, 59, 161, 163, 239, 240, 243, 275, 309, 310, 312。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift` 352, 353, 375, 376, 378, 379。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+WorkspaceAccessErrors.swift` 559, 571, 583, 595。
- `BlueStoneIM/Core/AppSupport/TenantSession/AppState+WorkspaceAndTenantAuthority.swift` 559。
- `BlueStoneIM/Features/Files/FilesView.swift` 67–73, 76, 96。
- `BlueStoneIMTests/DomainSplashCacheTests.swift` 12–40。
- `BlueStoneIMTests/DomainStoreTests.swift` 222, 233。
- `BlueStoneIMTests/HTTPGroupProfileAuthorityTests.swift` 405。
- `BlueStoneIMTests/SnapshotCacheTests.swift` 362, 363。
- iOS 26.5 模拟器基线 7 项、候选 8 项全过。新增用例覆盖启动、初始加载和分页订阅隔离。真实入口覆盖会话恢复、分页凭据轮换和挂载列表。7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bd-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 批量转发与企业切换观察

- `WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110`、`WDT_IOS1_REFACTOR_FILE_FORWARD_RUNTIME_FLAG_20261110`、`WDT_IOS1_REFACTOR_ENTERPRISE_SWITCH_COMPLETION_OBSERVATION_20261110`。承接 `7df6f02fb18146970fb5b403c071888031e2b0da`，`BASED_ON_CANONICAL_HEAD=21dbd7c39f20c573a280d3497d81c0a8f56d4b0a`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 批量转发按来源会话发布草稿，聊天行使用选中 ID 投影，目标弹窗接收自己的草稿。文件转发占用仅用于运行防重，企业选择器直接订阅原成功信号。原授权、代际、取消和幂等合同保持。
- `BlueStoneIM/AppState.swift` 191–195, 196, 383。
- `BlueStoneIM/ChatViews.swift` 157, 306–316, 386–390。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+PhoneBinding.swift` 438。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift` 225。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkspaceSelection.swift` 25–28。
- `BlueStoneIM/Core/AppSupport/AppState+BatchForwarding.swift` 15–72, 121, 144, 166, 320, 470, 476, 482, 491, 502, 512, 552, 578, 600。
- `BlueStoneIM/Features/Chat/ChatForwardViews.swift` 59, 67–74, 77, 81, 85, 89, 93, 103, 113, 163–167, 296, 358, 471。
- `BlueStoneIM/Features/Chat/ChatViewTimeline.swift` 407。
- `BlueStoneIM/Features/Me/EnterpriseSwitcherView.swift` 46–56, 58, 118, 120。
- `BlueStoneIMTests/BatchForwardStateTests.swift` 107, 113, 119。
- `BlueStoneIMTests/DomainBatchForwardAndUnreadProjectionTests.swift` 37–41, 65, 278–290, 303–308。
- iOS 26.5 模拟器基线和初次候选均 9 通过、1 项消息行源码检查定位失败，其他断言一致。修复原定位后，该检查单独复测通过。新增断言覆盖退出清除、目标变更不通知聊天选中状态以及不同会话隔离。7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2be-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · RTC 能力提示与启动场景观察

- `WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110`、`WDT_IOS1_REFACTOR_SCREENSHOT_LAUNCH_FIXTURES_20261110`、`WDT_IOS1_REFACTOR_UNUSED_GOVERNANCE_OBSERVATION_20261110`。承接 `74d51a640df9dbdbc6640fdd4f032c1bb26d52c2`，`BASED_ON_CANONICAL_HEAD=21dbd7c39f20c573a280d3497d81c0a8f56d4b0a`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- RTC 能力提示与根窗口协调器直接观察提示状态。保持窗口层级、关闭和来电回退行为。六个截图场景在创建根视图前选择，撤除全局发布。移除从未读取的治理占位及其重置。
- `BlueStoneIM/AppState.swift` 689–692, 799, 62–71, 338。
- `BlueStoneIM/BlueStoneIMApp.swift` 386–392, 394, 396, 407, 735–750。
- `BlueStoneIM/Core/AppSupport/AppState+ConversationsHistory.swift` 128。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugAvatarFixtures.swift` 382。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugGroupFixtures.swift` 171, 489。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift` 416。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteFailurePresentation.swift` 15–24, 170。
- `BlueStoneIMTests/DomainRTCLicenseAndVoiceAdmissionTests.swift` 81, 84, 347, 353, 407, 423–469。
- iOS 26.5 模拟器基线 4 通过、3 失败，候选 5 通过、3 失败。隔离挂载用例的启动页面后，共有用例结果和失败断言一致。新增真实窗口用例验证能力提示出现、模态性和关闭后释放控制器。7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bf-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 头像实时更新与在线状态观察

- `WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110`。承接 `25910718d7bf3b5a6ac99870c091fabb6f63f5ce`，`BASED_ON_CANONICAL_HEAD=21dbd7c39f20c573a280d3497d81c0a8f56d4b0a`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 查找用户直接观察头像投影的版本。保留批量应用和各领域的发布，撤除在线状态冗余的全局通知，保留后台投影、作用域清理和 iOS 隐藏在线状态的合同。
- `BlueStoneIM/AppState.swift` 243–247。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+CurrentProfileEditing.swift` 148。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+AvatarRealtimeAuthority.swift` 15–20, 88, 541, 555–625。
- `BlueStoneIM/Features/Conversations/FindUserSheet.swift` 23, 107–114。
- `BlueStoneIMTests/AvatarRealtimeSurfaceProjectionTests.swift` 270–278, 296–299。
- iOS 26.5 模拟器基线和候选各 6 项全过。批量真实头像投影只触发一次搜索及会话更新，重复或跨租户批次不发布，远端头像变化不触发 AppState。7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bg-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 认证头像、标签与作用域观察

- `WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110`。承接 `762da298b36bfeed197badb58a61096c3c879fb3`，`BASED_ON_CANONICAL_HEAD=21dbd7c39f20c573a280d3497d81c0a8f56d4b0a`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 认证信号独立发布，作用域先更新再通知。头像、认证标签与无障碍标签按精确 UID 观察，身份变化重建对应投影。通讯录与会话列表保持预取缓存和合并更新，复挂载可读取当前版本。头像观察不发起认证查询。
- `BlueStoneIM/AppState.swift` 556–559, 563–567。
- `BlueStoneIM/ContactsViews.swift` 158, 333–338。
- `BlueStoneIM/ConversationViews.swift` 84, 270–275, 563。
- `BlueStoneIM/Core/AppSupport/AppState+RealtimeEventDispatch.swift` 51, 135。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+CertificationRefresh.swift` 15–29, 62, 174, 349。
- `BlueStoneIM/DesignSystem/AvatarViews.swift` 59, 81–91, 93, 223–259, 276–295, 308–342。
- `BlueStoneIM/Features/Calls/CallScreenViews.swift` 41, 167, 250。
- `BlueStoneIM/Features/Calls/RTCCallRecordRow.swift` 64。
- `BlueStoneIM/Features/Chat/ChatBubbleMetadataViews.swift` 46。
- `BlueStoneIM/Features/Chat/ChatBubbleTextViews.swift` 226。
- `BlueStoneIM/Features/Chat/ChatComposerPanels.swift` 571, 592, 661, 696。
- `BlueStoneIM/Features/Chat/ChatForwardViews.swift` 411, 456。
- `BlueStoneIM/Features/Chat/ChatMessageActionViews.swift` 440, 442, 573。
- `BlueStoneIM/Features/Chat/MessageActionSheets.swift` 304。
- `BlueStoneIM/Features/Chat/MessageBubble.swift` 259, 267, 274, 332。
- `BlueStoneIM/Features/Chat/ReadReceiptSheet.swift` 216, 310。
- `BlueStoneIM/Features/Contacts/ContactCommonRows.swift` 106。
- `BlueStoneIM/Features/Contacts/ContactRelationshipViews.swift` 26, 152。
- `BlueStoneIM/Features/Contacts/ContactUserProfile.swift` 417, 596, 631。
- `BlueStoneIM/Features/Contacts/DepartmentManagementSheets.swift` 274, 461, 514。
- `BlueStoneIM/Features/Contacts/GroupMemberManagementViews.swift` 410, 534, 736。
- `BlueStoneIM/Features/Contacts/GroupMuteListViews.swift` 181, 309。
- `BlueStoneIM/Features/Contacts/GroupSharingViews.swift` 275–295。
- `BlueStoneIM/Features/Conversations/ConversationListMentions.swift` 348, 375。
- `BlueStoneIM/Features/Conversations/ConversationListRows.swift` 136。
- `BlueStoneIM/Features/Conversations/FindUserSheet.swift` 178。
- `BlueStoneIM/Features/Conversations/QuickAddViews.swift` 322, 354, 499, 540。
- `BlueStoneIM/Features/Me/ProfileEditViews.swift` 25, 227。
- `BlueStoneIM/FilesRTCViews.swift` 468, 706。
- `BlueStoneIM/MeSettingsViews.swift` 285。
- `BlueStoneIM/VideoCallViews.swift` 497。
- `BlueStoneIMTests/CertificationPresentationTests.swift` 2, 16–87。
- `BlueStoneIMTests/IdentityChatPresentationTests.swift` 255。
- iOS 26.5 模拟器基线 6 项、候选 7 项全过，额外的群发言人无障碍顺序检查通过。挂载的头像对照覆盖无关 UID、认证显示、作用域清除和行复用。7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bh-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · App 登录策略与支持信息观察

- `WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110`。承接 `099ccacaf1af5b737c55aad4d0cc94b6c23db136`，`BASED_ON_CANONICAL_HEAD=21dbd7c39f20c573a280d3497d81c0a8f56d4b0a`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 登录、注册、部门、企业切换和联系支持各自观察策略投影。原手机号拒绝、企业优先、最后可用缓存、失效路由和策略权限不变。
- `BlueStoneIM/AppState.swift` 410–416, 1080, 1084, 1085。
- `BlueStoneIM/AuthViews.swift` 207。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+AppPolicyAndLegal.swift` 15–88, 209, 210, 223, 236, 243, 251, 288, 290, 368, 406, 413, 491, 554, 555, 558。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+AuthenticationProfileWorkspace.swift` 403, 404, 412, 417, 418。
- `BlueStoneIM/Core/AppSupport/AppState+PresentationPolicy.swift` 56, 58, 60, 83。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugAvatarFixtures.swift` 359, 372。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift` 25, 372, 385。
- `BlueStoneIM/Features/Auth/AuthFlipView.swift` 89。
- `BlueStoneIM/Features/Auth/LoginRegisterViews.swift` 106–112, 418。
- `BlueStoneIM/Features/Contacts/DepartmentManagementSheets.swift` 396–402。
- `BlueStoneIM/Features/Contacts/OrganizationDirectoryViews.swift` 20–27, 36–43, 263–276。
- `BlueStoneIM/Features/Conversations/QuickAddViews.swift` 11–21。
- `BlueStoneIM/Features/Me/AccountInfoViews.swift` 137–143。
- `BlueStoneIM/MeSettingsViews.swift` 56–65。
- `BlueStoneIMTests/HTTPVerificationContactAndRemarkTests.swift` 569–581。
- iOS 26.5 模拟器基线和候选各 8 项全过。覆盖服务端手机号禁用、缓存回退、应用停用、企业优先和策略权限。联系邮箱更新仅通知支持信息。7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bi-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 设备上限与手机号入口实际刷新

- `WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110`、`WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110`。承接 `9f982381b2be89d90a2aeda5a91fde5252d655a8`，`BASED_ON_CANONICAL_HEAD=21dbd7c39f20c573a280d3497d81c0a8f56d4b0a`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 设备上限直接观察由原授权检查产生的显示文本。登录卡片用当前认证策略快照渲染手机号入口、注册入口与企业模式，动作仍查询实时授权。
- `BlueStoneIM/AppState.swift` 433–436, 410–416, 1083, 1087, 1088。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+ProfileAndTenantAuthority.swift` 15–28, 194, 212, 227–231, 247。
- `BlueStoneIM/Features/Auth/AuthFlipView.swift` 8, 89–95, 98, 101, 142, 151, 155, 159, 165, 172, 174, 180, 183, 187, 189, 404, 411, 414, 490, 517, 523, 525, 537, 728, 729。
- `BlueStoneIM/Features/Me/SecuritySettingsViews.swift` 59–63。
- `BlueStoneIMTests/DomainUserAuthorityAndSearchJumpTests.swift` 321–325, 351。
- `BlueStoneIMTests/HTTPRememberedLoginTests.swift` 4, 5, 10–71。
- iOS 26.5 模拟器基线 6 项、候选 7 项全过。旧设备响应未污染文本序列。实际挂载登录页在账号路由和 AppState 全局状态稳定时显示手机号入口关闭与恢复。7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bj-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 租户交互和消息操作的作用域观察

- `WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110`。承接 `a12e29cd64c9d122290a35f0a690ab60ba3265e9`，`BASED_ON_CANONICAL_HEAD=21dbd7c39f20c573a280d3497d81c0a8f56d4b0a`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 将租户交互和消息操作策略迁入 TenantInteractionPresentationStore，按当前会话作用域输出退群、好友关系、处理提示和转发编辑权限。聊天行接收处理提示输入，操作菜单、附件详情和转发入口各自观察所需策略。账号或租户切换立即撤下旧策略，执行路径保留当前作用域校验和原有请求归属。
- `BlueStoneIM/AppState.swift` 427, 775, 1073。
- `BlueStoneIM/ChatViews.swift` 157, 319, 320, 335, 340, 378, 391。
- `BlueStoneIM/ConversationViews.swift` 134–138, 166, 224。
- `BlueStoneIM/Core/AppSupport/AppState+BatchForwarding.swift` 78, 80。
- `BlueStoneIM/Core/AppSupport/AppState+MessageEditing.swift` 174, 175。
- `BlueStoneIM/Core/AppSupport/AppState+MessageModerationAndReports.swift` 141, 142。
- `BlueStoneIM/Core/AppSupport/InteractionPolicy/AppInteractionPolicy.swift` 1, 3, 120–166, 169–205, 208, 239, 257, 264, 266, 289, 291, 297, 298, 306, 309。
- `BlueStoneIM/Features/Chat/ChatAttachmentDetail.swift` 183, 198–204, 208, 239, 356, 365。
- `BlueStoneIM/Features/Chat/ChatBubbleTextViews.swift` 4–15, 30, 36, 120, 131。
- `BlueStoneIM/Features/Chat/ChatForwardViews.swift` 10–18, 165–169, 185。
- `BlueStoneIM/Features/Chat/ChatHistorySearchViews.swift` 6, 178。
- `BlueStoneIM/Features/Chat/ChatMessageActionViews.swift` 396, 464。
- `BlueStoneIM/Features/Chat/ChatViewLayout.swift` 300–395。
- `BlueStoneIM/Features/Chat/MessageBubble.swift` 79, 432。
- `BlueStoneIM/Features/Contacts/ContactGroupDetail.swift` 129–133, 142, 296。
- `BlueStoneIM/Features/Contacts/ContactUserProfile.swift` 104–110, 115, 117, 119, 124, 136, 143, 183, 189。
- `BlueStoneIM/Features/Contacts/GroupSharingViews.swift` 65, 73, 142, 143, 240–244, 254, 322。
- `BlueStoneIM/Features/Conversations/ConversationListRows.swift` 182–189。
- `BlueStoneIM/Features/Conversations/ConversationListSearch.swift` 263, 299。
- `BlueStoneIMTests/DomainBatchForwardAndUnreadProjectionTests.swift` 35, 36, 131, 132, 190, 191, 259, 260。
- `BlueStoneIMTests/HTTPCaptchaPasswordAndSocialContractTests.swift` 445, 446。
- `BlueStoneIMTests/HTTPTransportTests.swift` 72, 73, 74, 81, 82。
- `BlueStoneIMTests/IdentityContactPresentationTests.swift` 9–45。
- iOS 26.5 模拟器基线 8 项、候选 9 项全过。新增实际挂载测试验证转发栏关闭、恢复及切换租户撤权，策略更新不发布 AppState。原有禁用/未知权限不出站、批量转发取消和重试用例通过。7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bk-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 租户客户端策略、群人数与成员入口局部观察

- `WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110`。承接 `5a78a7412e3d00c8a1fb5dfbb53f00a0e81f7bd4`，`BASED_ON_CANONICAL_HEAD=a72b193b995716ba834adb9718989e787c2aac61`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 租户客户端策略、策略作用域与群人数权威状态由 TenantClientPolicyPresentationStore 统一发布。当前作用域变化立即收回旧策略投影，权威更新与缓存恢复按完整快照发布。会话、群列表、群详情、成员管理、解散预览和已读弹层订阅人数开关，聊天行与群统计行接收标量输入。建群和好友申请入口只观察各自策略，执行时继续使用原授权判断。
- `BlueStoneIM/AppState.swift` 425, 453, 773, 1072。
- `BlueStoneIM/ApplicationPolicyScreens.swift` 34–36, 197–199。
- `BlueStoneIM/ChatViews.swift` 157, 336, 380, 394–398。
- `BlueStoneIM/ConversationViews.swift` 136–140, 190, 221。
- `BlueStoneIM/Core/AppSupport/AppState+PresentationPolicy.swift` 1, 3, 6–64, 368–372, 381, 387, 388。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+CachedRemoteSnapshot.swift` 22–38。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+ProfileAndTenantAuthority.swift` 288, 295, 308–315, 334, 339–347, 364。
- `BlueStoneIM/Features/Chat/ChatViewHeaderAndStatus.swift` 226, 247。
- `BlueStoneIM/Features/Chat/MessageBubble.swift` 79, 773。
- `BlueStoneIM/Features/Chat/ReadReceiptSheet.swift` 94–98。
- `BlueStoneIM/Features/Contacts/ContactGroupDetail.swift` 131–135, 167, 454。
- `BlueStoneIM/Features/Contacts/ContactGroupList.swift` 38–48, 238, 268。
- `BlueStoneIM/Features/Contacts/ContactUserProfile.swift` 107–111。
- `BlueStoneIM/Features/Contacts/GroupMemberManagementViews.swift` 170–175, 301, 339, 346。
- `BlueStoneIM/Features/Contacts/GroupSettingsAndLifecycleSheets.swift` 373–379。
- `BlueStoneIM/Features/Conversations/FindUserSheet.swift` 25–31。
- `BlueStoneIM/Features/Conversations/QuickAddViews.swift` 73–77。
- `BlueStoneIMTests/IdentityContactPresentationTests.swift` 10–77。
- iOS 26.5 模拟器基线 9 项、候选 10 项全过。实际挂载群列表验证人数隐藏、恢复、建群入口关闭与恢复、代际失效和租户切换。策略更新无 AppState 全局发布。原群人数代际、水位、成员与特权角色及最后登录时间隐私测试通过。7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bl-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 认证加载局部观察与显式渲染输入

- `WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110`。承接 `6f238c5b2432b34465dbf8f01967f2346e71d047`，`BASED_ON_CANONICAL_HEAD=a72b193b995716ba834adb9718989e787c2aac61`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 认证加载迁入 AuthenticationPresentationStore，AppState 保留只读入口。登录、注册、挑战和工作区执行路径保留原取消与请求代际保护。各认证卡片观察加载，翻转容器、卡片正反面和按钮接收显式加载值，提交动作仍读取实时状态。
- `BlueStoneIM/AppState.swift` 107–110。
- `BlueStoneIM/AuthViews.swift` 325, 324–326, 330。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+EnterpriseMembership.swift` 305, 311。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+PreAuthEnterpriseContext.swift` 342, 370, 376。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+RememberedLoginAndEntry.swift` 26–55, 222, 241。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift` 555, 625, 663。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkspaceSelection.swift` 256, 263。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteRegistrationSnapshotSync.swift` 56, 62, 528。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+StoredSessionRefresh.swift` 660, 663。
- `BlueStoneIM/Features/Auth/AuthFlipView.swift` 49, 55, 56, 93, 96, 92–100, 106, 109, 180, 188, 191, 195, 197, 400, 472, 474, 513, 665, 667, 668。
- `BlueStoneIM/Features/Auth/AuthWorkspaceViews.swift` 66, 65–67, 72, 128, 147。
- `BlueStoneIM/Features/Auth/LoginRegisterViews.swift` 109, 110, 108–112, 115, 176, 324, 330, 331, 423, 424, 422–426, 432, 568。
- `BlueStoneIMTests/HTTPRegistrationSubmissionTests.swift` 571。
- `BlueStoneIMTests/IdentityContactPresentationTests.swift` 77–117。
- iOS 26.5 模拟器基线 7 项、候选 8 项全过。新增实际挂载测试曾发现加载事件未更新翻转卡片按钮，已用显式输入修复。验证加载和恢复画面、重复值去重以及无 AppState 发布。原注册取消、待确认、迟到登录、工作区等待和失败恢复测试通过。7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bm-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 嵌套策略观察的实际资料页和回执弹层回归

- `WDT_IOS1_REFACTOR_SCOPED_POLICY_RENDER_INPUTS_20261110`。承接 `e32c1f8c9e933bb3f442d9be76cbf6b41929293d`，`BASED_ON_CANONICAL_HEAD=a72b193b995716ba834adb9718989e787c2aac61`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 补充真实挂载的联系人资料页和群消息回执弹层，逐一覆盖好友申请策略与群人数策略在嵌套观察链中的关闭和恢复，检查策略存储更新的 AppState 发布次数，并使用当前回执权限判断验证测试前置。
- `BlueStoneIMTests/IdentityContactPresentationTests.swift` 10–76。
- iOS 26.5 模拟器基线 5 项、候选 6 项全过。两种实际界面均随策略变化更新并恢复原画面，直接策略存储变更无 AppState 发布。原群列表局部观察、回执作用域、好友角色及群人数权威用例通过，7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bn-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 认证路由、初始化与实际屏幕更新

- `WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110`。承接 `dde92cee783d864d550c9f6df46af27d7653b209`，`BASED_ON_CANONICAL_HEAD=a72b193b995716ba834adb9718989e787c2aac61`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 认证路由由 AuthenticationPresentationStore 持有，运行期写入统一经过 setAuthScreen，复用原规范化、注册取消、企业码挑战清理和诊断重置。初始化恢复使用原存储属性初始化语义。认证根页与翻转卡片显式接收屏幕值，根页背景动效作为展示输入，用例冻结该输入并等待转场稳定。复用 AuthViews 的卡片框架辅助方法，AuthFlipView 为 796 行。新增用例加入既有 Xcode 测试 target，并校正认证加载标识定位。
- `BlueStoneIM/AppState.swift` 146, 1106, 1144。
- `BlueStoneIM/AuthViews.swift` 9–70, 285, 622–637。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+EnterpriseMembership.swift` 296。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+LoginTransportAndWorkspace.swift` 255。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+PreAuthEnterpriseContext.swift` 217, 244, 251, 283, 318, 343, 464。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+RegistrationAndRecoveryUI.swift` 68, 81。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+RememberedLoginAndEntry.swift` 29–44, 58–80, 328, 334, 364, 378, 498。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift` 37, 567, 631, 678。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkspaceSelection.swift` 150, 241, 246, 322, 330, 341, 373。
- `BlueStoneIM/Core/AppSupport/AppState+PresentationPolicy.swift` 167。
- `BlueStoneIM/Core/AppSupport/AppState+RemoteErrorHandling.swift` 429。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugAvatarFixtures.swift` 342。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugGroupFixtures.swift` 149, 467。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift` 33, 70, 134, 321。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RegistrationResolution.swift` 41, 52, 670。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteRegistrationSnapshotSync.swift` 72, 274。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+StoredSessionRefresh.swift` 744。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+WorkspaceAccessErrors.swift` 425, 428, 557。
- `BlueStoneIM/Core/AppSupport/TenantSession/AppState+WorkspaceAndTenantAuthority.swift` 562。
- `BlueStoneIM/Features/Auth/AuthFlipView.swift` 94–98, 106, 118, 174, 206, 290, 363, 480。
- `BlueStoneIM/Features/Auth/AuthWorkspaceViews.swift` 23。
- `BlueStoneIM/Features/Auth/ForgotPasswordView.swift` 24, 40。
- `BlueStoneIM/Features/Auth/LoginRegisterViews.swift` 185, 205, 378, 382, 578, 580。
- `BlueStoneIMTests/DomainUserAuthorityAndSearchJumpTests.swift` 461。
- `BlueStoneIMTests/HTTPAccountPolicyAndGroupLifecycleTests.swift` 35。
- `BlueStoneIMTests/HTTPAuthenticationFixtureTests.swift` 463。
- `BlueStoneIMTests/HTTPEnterpriseLoginAndCaptchaTests.swift` 236, 309, 574, 633。
- `BlueStoneIMTests/HTTPLegalTenantEntryAndDiagnosticsTests.swift` 707。
- `BlueStoneIMTests/HTTPPhonePolicyAndProfileProjectionTests.swift` 31。
- `BlueStoneIMTests/HTTPProtectedSessionTests.swift` 289, 418。
- `BlueStoneIMTests/HTTPRTCParticipantAdmissionTests.swift` 531。
- `BlueStoneIMTests/HTTPRTCSignalStickerAndUploadTests.swift` 694, 696, 698。
- `BlueStoneIMTests/HTTPRegistrationAuthorityAndInviteTests.swift` 83, 128, 472, 506, 556, 608, 648, 688。
- `BlueStoneIMTests/HTTPRegistrationPendingRecoveryTests.swift` 452, 529, 563, 599。
- `BlueStoneIMTests/HTTPRememberedLoginTests.swift` 25。
- `BlueStoneIMTests/HTTPWorkspaceAndMessageSendTests.swift` 104。
- `BlueStoneIMTests/HTTPWorkspaceSessionRefreshTests.swift` 119, 207, 251, 335, 421, 499, 563, 621, 679。
- `BlueStoneIMTests/IdentityContactPresentationTests.swift` 81, 634。
- `BlueStoneIMTests/IdentityAuthRoutingTests.swift` 7–112。
- `BlueStoneIM.xcodeproj/project.pbxproj` 368, 954, 1193, 2586。
- iOS 26.5 模拟器基线 9 项、候选 11 项全过。两个新增挂载用例覆盖根页的忘记密码、工作区、手机号禁用规范化，以及翻转卡片注册和登录返回，路由切换无 AppState 全局发布。原注册取消、挑战取消、恢复和记住登录生命周期用例通过。测试发现列表确认只增加这两个用例，7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bo-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 认证会话局部观察与主界面切换

- `WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110`。承接 `fa00df51ae6232a8c2f71c56e229cea504f53ace`，`BASED_ON_CANONICAL_HEAD=a72b193b995716ba834adb9718989e787c2aac61`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 登录标记由 AuthenticationPresentationStore 持有，运行期通过 setAuthenticated 执行原注册确认、诊断、会话重验证、工作台、表情目录及 RTC 生命周期处理。初始化沿用原存储属性恢复语义。根视图、工作区卡片、输入框和反应面板分别观察认证值，根视图与工作区接收显式输入。强制认证展示修饰器迁至 AuthViews，主 App 文件为 781 行。
- `BlueStoneIM/AppState.swift` 87, 1123, 1161。
- `BlueStoneIM/AuthViews.swift` 639–685。
- `BlueStoneIM/BlueStoneIMApp.swift` 445, 455–462, 500, 598, 611, 632。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+LoginTransportAndWorkspace.swift` 249。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+RememberedLoginAndEntry.swift` 29–43, 73–93, 358, 395, 414, 524。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift` 30, 52, 554, 629, 676。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkspaceSelection.swift` 321, 329, 340, 364。
- `BlueStoneIM/Core/AppSupport/AppState+RemoteErrorHandling.swift` 428。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugAvatarFixtures.swift` 341。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugGroupFixtures.swift` 148, 466。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift` 32, 69, 135, 322。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RegistrationResolution.swift` 34, 46, 203。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteRegistrationSnapshotSync.swift` 265。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+StoredSessionRefresh.swift` 742。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+WorkspaceAccessErrors.swift` 422, 555。
- `BlueStoneIM/Core/AppSupport/TenantSession/AppState+WorkspaceAndTenantAuthority.swift` 560。
- `BlueStoneIM/Features/Auth/AuthWorkspaceViews.swift` 67–71。
- `BlueStoneIM/Features/Chat/ChatComposer.swift` 185–193, 640。
- `BlueStoneIM/Features/Chat/ReactionPickerView.swift` 180–188, 268。
- `BlueStoneIMTests/DomainAttachmentAndQueuedReadTests.swift` 572, 643。
- `BlueStoneIMTests/DomainPresenceAndSplashTests.swift` 589, 603。
- `BlueStoneIMTests/DomainQueuedReadAndGroupProjectionTests.swift` 110, 197。
- `BlueStoneIMTests/DomainRTCHeartbeatTests.swift` 385。
- `BlueStoneIMTests/DomainRTCLicenseAndVoiceAdmissionTests.swift` 62。
- `BlueStoneIMTests/DomainRTCPreviewAndMediaStateTests.swift` 195, 269, 379, 445, 499, 560, 599。
- `BlueStoneIMTests/DomainRTCTerminalAndMainShellTests.swift` 392, 551, 577。
- `BlueStoneIMTests/DomainStoreTestFixtures.swift` 350。
- `BlueStoneIMTests/DomainStoreTests.swift` 681。
- `BlueStoneIMTests/DomainUserAuthorityAndSearchJumpTests.swift` 125, 186, 247, 290, 319, 375, 460。
- `BlueStoneIMTests/GroupMuteModeTests.swift` 441, 522, 621, 647。
- `BlueStoneIMTests/HTTPAccountPolicyAndGroupLifecycleTests.swift` 553, 603, 622, 645, 675, 715, 752。
- `BlueStoneIMTests/HTTPEnterpriseLoginAndCaptchaTests.swift` 741。
- `BlueStoneIMTests/HTTPGroupAvatarAndAttachmentContractTests.swift` 493。
- `BlueStoneIMTests/HTTPGroupProfileAuthorityTests.swift` 17, 156, 232, 273, 305, 335, 370, 406。
- `BlueStoneIMTests/HTTPHistoryDiagnosticsAndReauthenticationTests.swift` 244, 635。
- `BlueStoneIMTests/HTTPMessageSendAndMediaRecoveryTests.swift` 33, 74, 115。
- `BlueStoneIMTests/HTTPPhonePolicyAndProfileProjectionTests.swift` 144, 389, 410, 459, 497。
- `BlueStoneIMTests/HTTPProductionRoutingAndEnterpriseContextTests.swift` 463, 528。
- `BlueStoneIMTests/HTTPRTCParticipantAdmissionTests.swift` 530。
- `BlueStoneIMTests/HTTPRTCSignalStickerAndUploadTests.swift` 528。
- `BlueStoneIMTests/HTTPReauthenticationAndAttachmentTransportTests.swift` 372, 425, 454, 495, 543。
- `BlueStoneIMTests/HTTPRegistrationAuthorityAndInviteTests.swift` 176, 194, 308, 338, 357, 380, 399, 422, 437, 446。
- `BlueStoneIMTests/HTTPRuntimeRouteAndOutboxTests.swift` 502。
- `BlueStoneIMTests/HTTPVerificationContactAndRemarkTests.swift` 25, 50, 89, 128, 161, 218, 265, 323, 386, 419, 447, 464, 494, 521, 535。
- `BlueStoneIMTests/HTTPWorkspaceAndMessageSendTests.swift` 332, 445, 731。
- `BlueStoneIMTests/IdentityAuthRoutingTests.swift` 4, 11–56, 140。
- `BlueStoneIMTests/RealtimeReceiptRecoveryTests.swift` 330, 397。
- `BlueStoneIMTests/RealtimeTransportTests.swift` 45, 47。
- `BlueStoneIMTests/RealtimeTransportWireTests.swift` 280, 296。
- `BlueStoneIMTests/SnapshotCacheTests.swift` 361, 380, 420, 437, 466, 490。
- iOS 26.5 模拟器基线 11 项为 10 项通过和 1 项既有失败，候选 12 项为 11 项通过和同一失败。testEnabledVideoConfigReportsCapabilitiesOncePerAuthenticatedSession 的上报次数 0/1 与 payload 字典为空两处断言前后相同。新增真实根视图用例验证认证后实际 TabBar 出现、退出后消失，认证值序列正确，状态设置不发布 AppState。原登录、退出、强制认证、重新验证、表情目录和通话展示用例通过，7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bp-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 当前企业、成员列表与角色局部观察

- `WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110`。承接 `6cd405219911f22d98dda4d322e5458f944129b7`，`BASED_ON_CANONICAL_HEAD=a72b193b995716ba834adb9718989e787c2aac61`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 当前企业和成员列表由 EnterpriseMembershipPresentationStore 持有，AppState 提供只读访问。运行期写入保留角色/企业变化的回执权限失效与遥测处理，初始化沿用原恢复语义。工作区观察列表及选中 ID，标题观察企业展示，权限入口观察角色并组合已绑定策略，聊天行接收企业名称。输入与表情面板任务键接收企业 ID，目录动作继续读取实时成员列表。共享联系人助手原样移到既有行组件文件，ContactsViews 为 799 行。
- `BlueStoneIM/AppState.swift` 142–146, 1148, 1149。
- `BlueStoneIM/ApplicationPolicyScreens.swift` 36–40, 205–209。
- `BlueStoneIM/ChatViews.swift` 157, 337, 382, 398–402。
- `BlueStoneIM/ContactsViews.swift` 5, 550–570。
- `BlueStoneIM/ConversationViews.swift` 138–142, 175, 225–230, 387。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+LoginTransportAndWorkspace.swift` 336。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+PhoneBinding.swift` 444。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+RememberedLoginAndEntry.swift` 452, 453, 532, 533。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift` 640。
- `BlueStoneIM/Core/AppSupport/AppState+PresentationPolicy.swift` 266–277, 284–295, 415, 418–430。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugAvatarFixtures.swift` 375, 376。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugGroupFixtures.swift` 166, 167, 484, 485。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift` 31, 68, 168, 169, 350, 351。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift` 127, 128。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+StoredSessionRefresh.swift` 474。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+WorkspaceAccessErrors.swift` 391, 394。
- `BlueStoneIM/Core/AppSupport/TenantSession/AppState+TenantSwitchingRemoteMapping.swift` 51, 329, 331, 333, 425, 427, 429。
- `BlueStoneIM/Core/AppSupport/TenantSession/AppState+WorkspaceAndTenantAuthority.swift` 15–47, 49–60, 63–83, 88, 89, 95, 98, 174, 180, 202, 204, 347, 351, 420, 424, 427。
- `BlueStoneIM/Features/Auth/AuthWorkspaceViews.swift` 54, 69–73, 83, 132。
- `BlueStoneIM/Features/Chat/ChatBubbleMetadataViews.swift` 5。
- `BlueStoneIM/Features/Chat/ChatComposer.swift` 188–192, 635。
- `BlueStoneIM/Features/Chat/ChatComposerActions.swift` 87。
- `BlueStoneIM/Features/Chat/ChatViewReply.swift` 67, 86。
- `BlueStoneIM/Features/Chat/ChatViewTimeline.swift` 633。
- `BlueStoneIM/Features/Chat/MessageBubble.swift` 78。
- `BlueStoneIM/Features/Chat/ReactionPickerView.swift` 47, 183–187, 269。
- `BlueStoneIM/Features/Contacts/ContactCommonRows.swift` 198–240。
- `BlueStoneIM/Features/Contacts/ContactGroupDetail.swift` 133–137。
- `BlueStoneIM/Features/Contacts/ContactGroupList.swift` 41–46, 53。
- `BlueStoneIM/Features/Contacts/ContactUserProfile.swift` 109–113。
- `BlueStoneIM/Features/Conversations/FindUserSheet.swift` 28–32。
- `BlueStoneIM/Features/Conversations/QuickAddViews.swift` 75–79, 88。
- `BlueStoneIM/Features/Me/EnterpriseSwitcherView.swift` 42–46, 54–58, 139, 205, 231, 239。
- `BlueStoneIM/MeSettingsViews.swift` 50–57, 65, 66, 157。
- `BlueStoneIMTests/DomainStoreTests.swift` 436, 653, 679。
- `BlueStoneIMTests/DomainUserAuthorityAndSearchJumpTests.swift` 126, 127, 187, 188, 462, 463。
- `BlueStoneIMTests/HTTPTransportTests.swift` 71。
- `BlueStoneIMTests/HTTPWorkspaceAndMessageSendTests.swift` 105, 381, 382, 456, 457。
- `BlueStoneIMTests/HTTPWorkspaceSessionRefreshTests.swift` 336, 422, 500, 564, 622, 680, 681。
- `BlueStoneIMTests/IdentityAuthRoutingTests.swift` 11–94。
- `BlueStoneIMTests/IdentityContactPresentationTests.swift` 51, 58, 126。
- iOS 26.5 模拟器基线 12 项为 11 项通过及 1 项既有失败，候选 14 项为 13 项通过及同一失败。testWorkspaceSelectionRefreshesExpiredPlatformTokenBeforeEnteringTenant 的认证状态、企业名称和请求数三处断言前后相同。两个新增实际挂载用例覆盖列表、选中项、标题更新与角色升降的建群入口，企业状态更新无 AppState 发布。原企业名称/Logo、角色权威、回执围栏、工作区与表情目录用例通过，7 张聊天对照截图逐像素一致。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bq-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 当前用户、个人资料与自己的聊天展示（2026-11-10）

- `WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110`。承接 `40a9a8acf1d2263eadbc9c101a8ab1207fca1d4e`，`BASED_ON_CANONICAL_HEAD=9ce08459d1abdd6bbe1e6fb25cf9c7378b584be4`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 最后的 currentUser 发布属性迁入 CurrentUserPresentationStore，AppState 保留只读计算属性和稳定的 ObservableObject 发布器身份。setCurrentUser 保持先安装新用户、再应用头像/在线状态展示覆盖、最后按 suppressCurrentUserIdentityPersistence 保存身份缓存的原顺序；既有 120 处完整用户赋值统一改走命令。Me 使用完整资料，聊天按身份、名称、部门、状态、企业、头像与徽标变化观察，手机和实名流程各订阅其验证字段，身份筛选/群主展示/回执与表情任务接入局部观察。聊天每页观察一次并通过环境向气泡提供展示值，头像点击、生命周期授权和动作初始化继续读取实时状态。纯移动通话动作标签到 RTCCallRecordRow、群成员统计行到 ContactCommonRows，触及的应用视图文件保持 800 行内。AppState 当前无 @Published；StickerLibrary 尚有两处既有手动 objectWillChange.send，留待下一批迁移真实资产消费者，阶段 2 尚未整体验收。
- `BlueStoneIM/AppState.swift` 58, 538–541。
- `BlueStoneIM/ChatViews.swift` 113, 114, 359, 385, 405。
- `BlueStoneIM/ConversationViews.swift` 71–642。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+CurrentProfileEditing.swift` 15–93, 96–107, 152, 277。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift` 641。
- `BlueStoneIM/Core/AppSupport/AppState+ColdLaunchSessionRestore.swift` 61, 77。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugAvatarFixtures.swift` 377。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugGroupFixtures.swift` 168, 486。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift` 202, 370。
- `BlueStoneIM/Core/AppSupport/GroupFileMapping/AppState+GroupDetailProjection.swift` 296。
- `BlueStoneIM/Core/AppSupport/GroupFileMapping/AppState+RemoteConversationProjection.swift` 36。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+AvatarRealtimeAuthority.swift` 433, 581。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift` 58, 192, 230, 267, 323。
- `BlueStoneIM/Core/AppSupport/TenantSession/AppState+TenantSwitchingRemoteMapping.swift` 406。
- `BlueStoneIM/Core/AppSupport/TenantSession/AppState+WorkspaceAndTenantAuthority.swift` 449, 614。
- `BlueStoneIM/Features/Calls/RTCCallRecordRow.swift` 110–154。
- `BlueStoneIM/Features/Chat/ChatComposer.swift` 193, 1–678。
- `BlueStoneIM/Features/Chat/ChatComposerActions.swift` 1–594。
- `BlueStoneIM/Features/Chat/ChatViewTimeline.swift` 1–708。
- `BlueStoneIM/Features/Chat/MessageBubble.swift` 79, 80, 140, 244, 255, 264, 535。
- `BlueStoneIM/Features/Chat/ReactionPickerView.swift` 49, 50, 188, 1–294。
- `BlueStoneIM/Features/Chat/ReadReceiptSheet.swift` 4–316。
- `BlueStoneIM/Features/Contacts/ContactCommonRows.swift` 242–285。
- `BlueStoneIM/Features/Contacts/ContactGroupDetail.swift` 5–582。
- `BlueStoneIM/Features/Contacts/ContactGroupList.swift` 5–209。
- `BlueStoneIM/Features/Contacts/GroupMemberManagementViews.swift` 10–319, 351, 450–634。
- `BlueStoneIM/Features/Conversations/FindUserSheet.swift` 14–390。
- `BlueStoneIM/Features/Conversations/QuickAddViews.swift` 236–431。
- `BlueStoneIM/Features/Me/PhoneBindingFlowView.swift` 6–160。
- `BlueStoneIM/Features/Me/ProfileEditViews.swift` 6–97, 224–382。
- `BlueStoneIM/Features/Me/RealNameVerificationViews.swift` 6–178。
- `BlueStoneIM/Features/Me/SecuritySettingsViews.swift` 6–96。
- `BlueStoneIM/FilesRTCViews.swift` 347, 574–772。
- `BlueStoneIM/MeSettingsViews.swift` 7–500。
- `BlueStoneIMTests/DomainGroupProjectionAndScopeTests.swift` 16。
- `BlueStoneIMTests/DomainOlderHistoryAndConversationListTests.swift` 59。
- `BlueStoneIMTests/DomainRTCAudioVideoLifecycleTests.swift` 21, 369, 425, 489, 536, 565, 587, 627, 656, 680, 727。
- `BlueStoneIMTests/DomainRTCHeartbeatTests.swift` 648。
- `BlueStoneIMTests/DomainRTCInboundAndColdLaunchTests.swift` 48, 90, 148, 296, 329, 376, 397, 415, 438, 479, 516, 560, 595, 623, 654, 691。
- `BlueStoneIMTests/DomainRTCJoinAndPeerResolutionTests.swift` 297, 358, 369, 428, 460, 484, 523, 536, 567, 593。
- `BlueStoneIMTests/DomainRTCLicenseAndVoiceAdmissionTests.swift` 19, 63, 112, 342。
- `BlueStoneIMTests/DomainRTCPreviewAndCallOwnershipTests.swift` 22, 67, 591。
- `BlueStoneIMTests/DomainRTCPreviewAndMediaStateTests.swift` 63, 95, 446, 500。
- `BlueStoneIMTests/DomainRTCSystemAnswerAndPreviewFenceTests.swift` 190, 235, 357, 678, 712。
- `BlueStoneIMTests/DomainRTCTerminalAndMainShellTests.swift` 438。
- `BlueStoneIMTests/DomainStoreTests.swift` 60, 220, 258, 346, 425, 680。
- `BlueStoneIMTests/DomainUserAuthorityAndSearchJumpTests.swift` 141。
- `BlueStoneIMTests/HTTPAccountPolicyAndGroupLifecycleTests.swift` 513, 569, 768。
- `BlueStoneIMTests/HTTPGroupProfileAuthorityTests.swift` 233, 274, 306, 371。
- `BlueStoneIMTests/HTTPPhonePolicyAndProfileProjectionTests.swift` 276, 390, 411, 498, 701, 745。
- `BlueStoneIMTests/HTTPRTCParticipantAdmissionTests.swift` 267, 385。
- `BlueStoneIMTests/HTTPRTCSignalStickerAndUploadTests.swift` 90, 529。
- `BlueStoneIMTests/HTTPVerificationContactAndRemarkTests.swift` 30, 55, 105, 133, 177, 234, 283, 338。
- `BlueStoneIMTests/IdentityAuthRoutingTests.swift` 219–363。
- `BlueStoneIMTests/IdentityChatPresentationTests.swift` 332, 348。
- `BlueStoneIMTests/IdentityPresentationTests.swift` 233, 251, 448, 658, 705。
- `BlueStoneIMTests/RTCCallLifecycleIntegrationTests.swift` 133, 305。
- iOS 26.5 模拟器基线 14 项为 12 项通过和 2 项既有失败，候选 18 项为 16 项通过及同一两项失败，头像上传预签名及过期平台票据续接的原断言前后一致。新增 4 项全部通过，覆盖 Me/头像编辑/手机绑定/实名认证/聊天自己的头像五个实际界面，以及私人资料不发布聊天、身份缓存保存和抑制逻辑；当前用户修改无 AppState 发布。Me 测试的策略和邀请码请求使用受控 HTTP transport，保持更新、恢复的截图断言。7 张原聊天截图逐像素一致；修改 Swift 语法、差分、声明路径及制品源码镜像核对通过。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2br-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 贴纸消息资源观察与绑定隔离（2026-11-10）

- `WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110`。承接 `0c6919561bfcc2cf601b913e52002024f1cb0771`，`BASED_ON_CANONICAL_HEAD=4a23dc84bcedfc80c8af7785abaa09556446bc69`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- StickerMessageAssetStore 接管原 AppState 的贴纸消息资源字典，气泡只观察对应缩略图、动图 URL 和绑定标识的投影；保留原 URL 选择、本地优先级和资源缓存顺序，撤除远端解析及本地资源就绪后的两处手动全局通知。AppState 中 107 个发布属性及全部 Core/AppSupport 全局 send/转发调用均已迁出。绑定以 UUID 隔离，在会话/租户改变及显式重置时清空资源；请求前、API 返回、本地获取及提交位置校验绑定与现有 authSessionFence，旧完成和旧失败不得释放或污染新请求。实际并发用例发现公共文件 GET 在途合并会让新绑定复用旧绑定响应，已通过仅在内存使用的 coalescingScope 隔离贴纸 GET；三条既有路由分支均传递该参数。普通 GET 保留原合并键，scope 不进入 URL、Header 或 Body。IMAPIProtocol 保留原两参接口，并为作用域重载提供默认兼容实现，生产 IMAPIClient 显式实现作用域调用。StickerResolvedFileAsset 移至 Domain 并增加 Equatable/Sendable，不新增持久化格式。手工合并须完整取 Store、气泡、模型、AppState/重置、协议和请求执行/合并键的全部标识块；回退按完整提交反向恢复。阶段 2 的完整输出矩阵、历史/实时/回执作用域验收和固定 reviewer 独审仍待完成。
- `BlueStoneIM/AppState.swift` 735, 897–900。
- `BlueStoneIM/Core/AppSupport/AppState+StickerLibrary.swift` 19, 47, 15–486。
- `BlueStoneIM/Core/AppSupport/AppState+StickerUploadAndHydration.swift` 29。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift` 403。
- `BlueStoneIM/Core/Networking/IMAPIClient+Files.swift` 1–648。
- `BlueStoneIM/Core/Networking/IMAPIClient+RequestExecution.swift` 1–720。
- `BlueStoneIM/Core/Networking/IMAPIClient+ResponseAndLogging.swift` 1–347。
- `BlueStoneIM/Domain/StickerMessageModels.swift` 238–254。
- `BlueStoneIM/Features/Chat/ChatMediaBubbleViews.swift` 4–81。
- `BlueStoneIM/IMAPIProtocol.swift` 220。
- `BlueStoneIM/StickerStore.swift` 326–355。
- `BlueStoneIMTests/IdentityAuthRoutingTests.swift` 394–642。
- iOS 26.5 模拟器基线 11 项为 10 项通过和 1 项过期平台票据续接既有失败，候选 14 项为 13 项通过及同一失败，原断言一致。新增 3 项全部通过，覆盖前台实际挂载贴纸从占位到解析资源、切换本地资源、无关资源不发射及清空恢复；四种切换（换租户、退出重登、A→B→A、同作用域重认证）分别延迟成功和失败，共 8 个场景验证旧响应隔离、新请求所有权与可继续加载；现会话失败保留去重，新绑定可重试。另有普通 GET 合并、在途所有权及清除型 GET 不合并 3 项定向回归全部通过。原 7 张聊天截图逐像素一致；修改 Swift 语法、差分、标识、行数与构建源码镜像核对通过。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bs-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 提示条写入命令与只读展示入口（2026-11-10）

- `WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110`。承接 `84fdfb798dcfb2dc529b358bcce63ec6541f52b6`，`BASED_ON_CANONICAL_HEAD=2d5618fb9408a91a8c531b34d8e8d519c3849554`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 复核阶段 2 的只读兼容入口时，发现 toast 仍保留可写计算属性。AppState.toast 现为只读，既有 setter 的调试截图持久显示判断与 ToastPresentationStore.present 调用原样移入 setToast 命令。842 处源码/测试赋值改走命令，包括弱引用可选调用；字符串、错误转换、条件分支、返回与调用位置保持。未改变提示替换、清空、自动消失、任务取消或截图模式。现有语法/类型检查已覆盖全部修改调用点，未新增测试或修改任何原断言。必须按完整标识块合入只读属性、命令和全部调用点；回退按完整提交反向恢复。阶段 2 的全量输出矩阵、历史/实时/回执四种作用域验收、固定 reviewer 独审与整合仍未完成。
- `BlueStoneIM/AppState.swift` 353, 1153, 1159, 1208。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+AppPolicyAndLegal.swift` 407, 414, 566。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+AuthenticationProfileWorkspace.swift` 90, 384。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+CurrentProfileEditing.swift` 305, 310, 314, 318, 322, 330, 368, 393, 396, 401, 407, 413, 421, 428, 444, 450, 455, 466, 470, 476, 478, 480, 504, 508, 513, 581。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+EnterpriseMembership.swift` 19, 22, 76, 124, 134, 139, 143, 147, 151, 160, 164, 169, 210, 215, 222, 231, 241, 249, 258, 268, 276, 287, 297。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+GroupProfileEditing.swift` 19, 24, 35, 39, 73, 90, 122, 131, 152, 159, 162, 168, 191, 196, 216, 227, 230。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+LoginTransportAndWorkspace.swift` 78, 104, 108, 118, 122, 240, 242, 270, 281, 283, 285。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+PhoneBinding.swift` 57, 62, 66, 84, 116, 260, 265, 275, 292, 304, 312, 315, 328, 354, 360, 373, 377, 381, 386, 391, 437, 462, 467, 477。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+PreAuthEnterpriseContext.swift` 216, 250, 286, 319, 358, 463。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+ProtectedContentAccess.swift` 126, 131, 142, 145, 156, 160。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+RegistrationAndRecoveryUI.swift` 69, 74, 82, 95, 99, 108, 118, 132, 142, 152, 165, 170, 177, 187, 190, 213, 215, 217。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+RememberedLoginAndEntry.swift` 250, 368, 374, 376, 403, 417–419, 462, 479。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift` 39, 68, 580–582, 589, 595, 599, 690。
- `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkspaceSelection.swift` 112, 115, 118, 123, 130, 136, 149, 240, 245, 251, 324, 334, 343, 353, 357, 379, 383, 393。
- `BlueStoneIM/Core/AppSupport/AppState+AttachmentURLsAndProgress.swift` 48, 445。
- `BlueStoneIM/Core/AppSupport/AppState+AttachmentUpload.swift` 49, 73, 126, 604。
- `BlueStoneIM/Core/AppSupport/AppState+BatchForwarding.swift` 97, 101, 105, 124, 169, 225, 233, 239, 264, 309, 323, 498, 508, 516, 577, 580。
- `BlueStoneIM/Core/AppSupport/AppState+ColdLaunchSessionRestore.swift` 15, 24, 47。
- `BlueStoneIM/Core/AppSupport/AppState+ContactRelationships.swift` 19, 23, 27, 31, 36, 67, 99, 126, 131, 141, 165, 188, 193, 202, 207, 342, 346, 350, 354, 359, 377, 388, 399–401, 426–428。
- `BlueStoneIM/Core/AppSupport/AppState+ContactsInboxDevices.swift` 22, 32, 45, 55, 69, 74, 88, 116, 132, 143, 160, 377, 387, 416, 438, 541, 563。
- `BlueStoneIM/Core/AppSupport/AppState+ConversationReadState.swift` 127。
- `BlueStoneIM/Core/AppSupport/AppState+ConversationsHistory.swift` 309, 313, 317, 367, 397, 406, 412, 419, 425, 538。
- `BlueStoneIM/Core/AppSupport/AppState+FileOpenAndSnapshots.swift` 29。
- `BlueStoneIM/Core/AppSupport/AppState+FilesAttachments.swift` 54, 127, 144, 151, 191, 399, 417, 424, 430。
- `BlueStoneIM/Core/AppSupport/AppState+GroupAdministration.swift` 111, 121, 127, 142, 154, 193, 199, 225, 235, 243, 261, 268, 271, 276, 304, 311, 330, 335, 340, 381, 407, 494, 505, 516, 525。
- `BlueStoneIM/Core/AppSupport/AppState+GroupCreationAndSettings.swift` 18, 43, 47, 52, 69, 135, 140, 153, 158, 172, 177, 194, 207, 218, 271, 277, 292, 296, 344, 347, 350, 371, 400, 405, 420, 425, 454, 465, 470, 491, 496, 511, 516, 522, 529, 532。
- `BlueStoneIM/Core/AppSupport/AppState+GroupMembershipLifecycle.swift` 38, 43, 49, 72, 91, 95, 100, 105, 116, 121, 135, 140, 145, 157, 168, 173, 178, 192, 197, 206, 224。
- `BlueStoneIM/Core/AppSupport/AppState+GroupMuteList.swift` 60, 67, 96, 100, 106, 111, 146, 164, 169, 193。
- `BlueStoneIM/Core/AppSupport/AppState+GroupsAnnouncements.swift` 57, 103。
- `BlueStoneIM/Core/AppSupport/AppState+HistoryPaging.swift` 243。
- `BlueStoneIM/Core/AppSupport/AppState+InboxAndDevices.swift` 18, 23, 28, 52, 54, 61, 68, 151, 244, 289。
- `BlueStoneIM/Core/AppSupport/AppState+MediaSending.swift` 45, 49, 53, 58, 62, 67, 74, 85, 88, 99, 108, 194, 225, 229, 233, 237, 241, 245, 250, 257, 321。
- `BlueStoneIM/Core/AppSupport/AppState+MessageActions.swift` 56, 88, 94, 120, 132, 141, 146, 151, 157, 168, 229, 293。
- `BlueStoneIM/Core/AppSupport/AppState+MessageEditing.swift` 54, 59, 63, 69, 74, 109, 127, 136, 141, 162, 165, 169, 233, 240, 243, 260, 279, 316, 325。
- `BlueStoneIM/Core/AppSupport/AppState+MessageForwardAndReaction.swift` 17, 22, 26, 30, 35, 43, 64, 77, 82, 88, 130, 135, 147。
- `BlueStoneIM/Core/AppSupport/AppState+MessageModerationAndReports.swift` 35, 40, 47, 51, 54, 65, 69, 164, 180, 184, 225, 285, 289, 293, 299, 304, 308, 324, 327。
- `BlueStoneIM/Core/AppSupport/AppState+OutgoingAttachmentRecovery.swift` 190, 198, 215, 220, 225, 230, 238, 250。
- `BlueStoneIM/Core/AppSupport/AppState+PresentationPolicy.swift` 477, 487。
- `BlueStoneIM/Core/AppSupport/AppState+ReadReceiptPresentation.swift` 164, 190, 213, 218, 221。
- `BlueStoneIM/Core/AppSupport/AppState+RealtimeConnectionRecovery.swift` 146, 222, 230。
- `BlueStoneIM/Core/AppSupport/AppState+RealtimeEventDispatch.swift` 355, 361, 381, 401。
- `BlueStoneIM/Core/AppSupport/AppState+RealtimeGroupAndReadEvents.swift` 328。
- `BlueStoneIM/Core/AppSupport/AppState+RemoteErrorHandling.swift` 26, 346, 352, 363, 370, 394, 396, 398, 400, 402, 404, 406, 408, 410, 412, 431, 466。
- `BlueStoneIM/Core/AppSupport/AppState+SearchConversationSettings.swift` 165, 174, 243, 252, 275, 287, 306, 315, 338, 350, 470, 475, 493, 498, 502, 506, 525, 531, 537–539, 558–560, 574, 579, 583, 587, 591, 595, 599, 616, 618, 620–622, 631–633, 647, 652, 675, 682。
- `BlueStoneIM/Core/AppSupport/AppState+StickerLibraryActions.swift` 62, 66, 71, 78, 116, 121, 127, 133, 166, 172, 176, 180, 186, 191, 292。
- `BlueStoneIM/Core/AppSupport/AppState+StickerUploadAndHydration.swift` 57, 102, 117, 125, 134, 148。
- `BlueStoneIM/Core/AppSupport/AppState+TextSending.swift` 104, 108, 112, 118, 221, 234。
- `BlueStoneIM/Core/AppSupport/AppState+VoiceMessagePlayback.swift` 47, 81, 135, 146, 171, 243。
- `BlueStoneIM/Core/AppSupport/AppStateLifecycleSupport.swift` 99–110。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+ActiveCallActions.swift` 25, 43, 61, 147, 152, 238, 271, 366, 511, 515, 518。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+CallSystemEvents.swift` 50, 378。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+IncomingVideoCalls.swift` 34, 39, 82, 208。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+IncomingVoiceCalls.swift` 31, 37, 76, 82, 103, 125, 281, 491。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+OutgoingVideoCalls.swift` 89, 93, 307, 315, 324, 411–413, 550, 584。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+OutgoingVoiceCalls.swift` 19, 24, 28, 32, 37, 47, 203。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+RTCCallEvents.swift` 133, 141, 226。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+RTCCallHistory.swift` 371。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+RTCCallReconciliation.swift` 372–374, 396–398。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+RTCPeerMediaCoordination.swift` 32, 122。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+VideoMediaSession.swift` 40, 247, 328, 349, 365, 415–417, 434, 451。
- `BlueStoneIM/Core/AppSupport/Calls/AppState+VoiceCalls.swift` 207–209, 224–226。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugAvatarFixtures.swift` 344。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugGroupFixtures.swift` 151, 469。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift` 36–38, 41, 72, 137, 324。
- `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift` 628。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+LocalMessageScope.swift` 42。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+OrganizationDirectorySync.swift` 49, 142, 147, 152, 164, 169, 174, 179, 191, 196, 201, 213, 218, 223, 228, 240, 245, 250, 255, 283。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+ProfileAndTenantAuthority.swift` 545。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RegistrationResolution.swift` 42, 53, 128。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteRegistrationSnapshotSync.swift` 31, 40, 45, 51, 73, 85, 90, 101, 126, 139, 224, 239, 290, 293, 295, 297, 319, 611, 646, 657, 668。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+SecondarySnapshotSync.swift` 251。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+StoredSessionRefresh.swift` 92, 149, 247, 690, 729, 758。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+WorkspaceAccessErrors.swift` 431, 561, 574。
- `BlueStoneIM/Core/AppSupport/TenantSession/AppState+TenantInboxMapping.swift` 233–235。
- `BlueStoneIM/Core/AppSupport/TenantSession/AppState+WorkspaceAndTenantAuthority.swift` 195, 635。
- `BlueStoneIM/Features/Auth/AuthFlipView.swift` 209, 273, 281, 298, 303, 308, 354, 358, 372, 379, 388。
- `BlueStoneIM/Features/Auth/LoginRegisterViews.swift` 27, 40, 45, 50, 364, 373, 377, 391, 398, 407。
- `BlueStoneIM/Features/Chat/ChatAttachmentDetail.swift` 257, 259, 419, 426, 478。
- `BlueStoneIM/Features/Chat/ChatAttachmentPreview.swift` 285, 294, 295, 296, 299, 311, 319, 321, 323, 325。
- `BlueStoneIM/Features/Chat/ChatAttachmentSelection.swift` 259。
- `BlueStoneIM/Features/Chat/ChatComposer.swift` 323, 344, 374, 611, 629。
- `BlueStoneIM/Features/Chat/ChatComposerActions.swift` 173, 208, 242, 253, 263, 265, 272, 276, 285, 293, 296, 298, 329, 372, 387, 391, 435, 469, 476, 485。
- `BlueStoneIM/Features/Chat/ChatConversationSheets.swift` 306, 412。
- `BlueStoneIM/Features/Chat/ChatViewAttachmentActions.swift` 45, 63, 81, 146, 156, 157, 158, 164, 172, 174, 176, 178, 186, 194, 196, 198, 200。
- `BlueStoneIM/Features/Chat/ChatViewHeaderAndStatus.swift` 173, 253–255, 261, 263, 272–274, 279。
- `BlueStoneIM/Features/Chat/ChatViewLayout.swift` 341, 590, 592。
- `BlueStoneIM/Features/Chat/ChatViewNavigation.swift` 62, 109, 150, 271, 303, 310, 317, 321, 360, 367, 376, 398。
- `BlueStoneIM/Features/Chat/ChatViewReadAcknowledgement.swift` 43。
- `BlueStoneIM/Features/Chat/ChatViewTimeline.swift` 473。
- `BlueStoneIM/Features/Chat/ReactionPickerView.swift` 166。
- `BlueStoneIM/Features/Contacts/ContactUserProfile.swift` 166。
- `BlueStoneIM/Features/Contacts/GroupSharingViews.swift` 31, 34, 136, 181, 188, 200, 205。
- `BlueStoneIM/Features/Conversations/ConversationListSearch.swift` 52, 57, 69, 73, 81, 200。
- `BlueStoneIM/Features/Conversations/FindUserSheet.swift` 289。
- `BlueStoneIM/Features/Files/FilePreviewViews.swift` 184, 206, 215, 233, 238。
- `BlueStoneIM/Features/Files/FilesView.swift` 492, 541, 547, 587, 698, 717, 735, 740。
- `BlueStoneIM/Features/Me/AccountInfoViews.swift` 224, 230。
- `BlueStoneIM/Features/Me/EnterpriseSwitcherView.swift` 222, 226, 228, 230。
- `BlueStoneIM/Features/Me/ProfileEditViews.swift` 349。
- `BlueStoneIM/Features/Me/RealNameVerificationViews.swift` 123, 128。
- `BlueStoneIM/Features/Me/SecuritySettingsViews.swift` 293, 310。
- `BlueStoneIM/FilesRTCViews.swift` 219。
- `BlueStoneIM/MeSettingsViews.swift` 45。
- `BlueStoneIM/RTCCallRecordRedial.swift` 342, 347。
- `BlueStoneIMTests/DomainChatViewportAndGestureTests.swift` 27, 28。
- `BlueStoneIMTests/DomainGroupProjectionAndScopeTests.swift` 138。
- `BlueStoneIMTests/DomainRTCLicenseAndVoiceAdmissionTests.swift` 92, 136, 200。
- `BlueStoneIMTests/DomainStoreTests.swift` 239, 691。
- `BlueStoneIMTests/HTTPGroupProfileAuthorityTests.swift` 345。
- `BlueStoneIMTests/HTTPRegistrationPendingRecoveryTests.swift` 219, 245。
- `BlueStoneIMTests/SnapshotCacheTests.swift` 497。
- Debug arm64 应用/测试目标编译通过，2102 个 XCTest 标识前后一致。iOS 26.5 基线和候选各 12 项，均 10 项通过和相同两项旧失败：排队已读的未读数两处断言在文本/图片两轮共四处一致；限额截图的预填凭据断言仍失败。基线额外复现一次 accountRegister 路由断言，候选未复现，故原严格明细对照器返回 AssertionError，本批不记为严格对照通过。候选未新增失败断言（基线 6 处、候选 5 处）。提示自动消失及取消、注册恢复、额度/工作区友好提示、迟到昵称错误抑制、主 Tab 角标用例通过，7 张聊天截图逐像素一致。修改 Swift 语法、实际路径、标识、行数、差分和构建源码镜像核对通过。排队已读未读数与限额截图问题继续作为阶段验收未完成项。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bt-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 排队可见已读用例的前置与锚点（2026-11-10）

- `WDT_IOS1_REFACTOR_VISIBLE_ACK_FIXTURE_20261110`。承接 `d9e14c72184632cb6eb8ca34478d1aff2a9bec0b`，`BASED_ON_CANONICAL_HEAD=af37abc058edbe18be55024206dc49a912f7636a`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 定位阶段验收的排队已读旧失败：通用 makeConversation 工厂默认 hasUnreadReaction=true、unreadReactionCount=2，并预填序号 3 的未读锚点；产品按现有规则保留未读回应，导致仅验证消息的用例误带最低计数 2。该用例现显式从一条未读消息、无未读回应、序号 1/消息 incoming-1 锚点开始，后续序号 3 的锚点必须由实际 ACK 推进产生。保持文本/图片两轮、暂停 ACK、新消息交错和全部原断言，通用工厂及产品已读算法保持原实现。回退按此完整标识块恢复本用例前置。其余历史/实时/回执四场景矩阵、限额截图问题和独立审查仍未完成。
- `BlueStoneIMTests/DomainAttachmentAndQueuedReadTests.swift` 651–658。
- iOS 26.5 对照基线 9 项为 8 项通过及该用例四处未读计数失败；候选 9 项全部通过，2102 个 XCTest 标识保持一致。比较时显式声明这一项为预期修复用例，要求其从失败变为通过，其他用例结果和断言严格一致。排队 ACK [1,2]、最高已读 2、未看到的第 3 条消息未读 1、重复确认不吞消息均通过。原未读回应保留、跨覆盖缺口、在途较高目标合并、旧 claim 不释放新代际、同作用域换票后本地历史读取、缓存已读叠加和 Tab/系统角标输入用例均通过，7 张聊天截图逐像素一致。修改文件语法、差分及制品镜像核对通过。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bu-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 实时缓冲绑定与计时器隔离（2026-11-10）

- `WDT_IOS1_REFACTOR_REALTIME_INGEST_BINDING_20261110`。承接 `ac5813ff5a460e25b5bf5138e655bee7ca713090`，`BASED_ON_CANONICAL_HEAD=3d93cdfd8f6e5a6edca73940b014acc4ad115f5c`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 实时缓冲按数据作用域、本地会话代次和远端 sessionEpoch 绑定；普通 credentialRevision 换票保留有效缓冲。计时器只按当前绑定取出消息，避免旧计时器清除新作用域批次。新增真实 AppState/SQLite 特征用例覆盖换企业、退出重登、A→B→A、保留本地历史的同作用域重认证，断言旧消息不展示、不增加投影 revision、不发投递确认且不落当前数据库；另验普通换票保留消息及旧计时器接受新批次。没有新增接口、请求字段或数据库迁移，Android 无同步需求。
- `BlueStoneIM/Core/AppSupport/AppState+RealtimeSequenceRecovery.swift` 253–315。
- `BlueStoneIMTests/ScopedResponseFenceTests.swift` 542–694。
- 测试先行复现退出重登、A→B→A、重认证三种场景共 12 条失败断言，初始证据 phase2bv-initial-* 保留。修复后基线 6 项全过，候选 8 项全过，原用例结果/断言一致，XCTest 标识只增加两个（2,102→2,104）；7 张聊天截图逐像素相等。源文件 333 行，测试 694 行；Swift 语法、diff check 和 Debug arm64 build-for-testing 通过。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bv-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 历史分页及回执迟到响应的会话隔离（2026-11-10）

- `WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110`。承接 `3b5f014e2115892813480c75c8d6236d8897c844`，`BASED_ON_CANONICAL_HEAD=3d93cdfd8f6e5a6edca73940b014acc4ad115f5c`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 历史分页除原 refresh/data-scope 校验外，绑定本地会话代次与远端 sessionEpoch；旧成功、旧失败及后台索引准备后的恢复点均校验绑定，普通 credentialRevision 换票可继续有效补页。新增既有 AppState/IMAPIClient/SQLite 路径特征用例，受控释放 HTTP 响应，覆盖旧/新两方向历史页和回执在换企业、退出重登、A→B→A、同作用域重认证及普通换票下的成功/失败，共 30 组合；失效响应不改当前消息、投影 revision、提示、数据库或确认请求。新测试文件通过现有四处 PBX 引用加入原 XCTest target，不新增部署面。回执运行逻辑未改。没有新增接口/请求字段/数据库迁移，Android 无同步需求。
- `BlueStoneIM.xcodeproj/project.pbxproj` 371, 958, 1198, 2592。
- `BlueStoneIMTests/ScopedMessageCallbackTests.swift` 5–248。
- `BlueStoneIM/Core/AppSupport/AppState+HistoryPaging.swift` 28, 31, 103, 107, 122, 133–136, 181, 253, 256, 302, 307–310, 334, 344–353。
- 测试先行复现旧历史页 19 条失败断言（包括跨企业的迟到失败提示和三类重复数据作用域的旧消息/数据库/确认），保留 phase2bw-initial-*；新增测试最初缺少 HTTPTransport.upload witness 的编译诊断另存 conformance-build，已补齐测试替身。修复后基线 5 项全过、候选 8 项全过，原用例结果与断言一致，三个新增 selector（2,104→2,107）；7 张聊天截图逐像素一致。Swift 解析、工程 plist、diff check 及 Debug arm64 build-for-testing 通过，源文件 397 行、测试 248 行。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bw-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 历史加载占用与旧请求收尾隔离（2026-11-10）

- `WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110`。承接 `dbe6cb0e4142a06b053d37eb2c9fb2040b8be349`，`BASED_ON_CANONICAL_HEAD=793bca82187ff4ec80e4110af82ff5dc878b5137`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 历史/会话同步增加本次请求的 UUID claim；Store reset 撤销旧 claim，收尾只释放匹配占用，同时有同会话其他可见加载时保留加载状态。五个实际异步入口（远端旧页、本地旧页、新页、聊天同步、实时补洞）均捕获 claim 并在 defer 精确释放；保留原 throttle、提示清理顺序及既有布尔便捷接口。新增用例覆盖同键/异键、普通同步/旧页、reset 后重复旧收尾、防重复占用与并存加载。纯客户端内部状态变化，没有新增接口、请求字段、迁移或 Android 同步需求。
- `BlueStoneIM/ConversationStore.swift` 315, 543。
- `BlueStoneIM/Stores/ConversationStore+Sync.swift` 35–84。
- `BlueStoneIM/Stores/ConversationStore+History.swift` 569–595。
- `BlueStoneIM/Core/AppSupport/AppState+HistoryPaging.swift` 76, 93, 207, 216, 270, 285。
- `BlueStoneIM/Core/AppSupport/AppState+ConversationReadState.swift` 161, 174。
- `BlueStoneIM/Core/AppSupport/AppState+RealtimeSequenceRecovery.swift` 104, 123。
- `BlueStoneIMTests/ScopedMessageCallbackTests.swift` 250–287。
- 测试先行复现两个用例共 7 条失败断言，phase2bx-initial-* 保留。修复后基线 9 项全过，候选 11 项全过，原测试输出/断言一致，新增两个 XCTest 标识（2,107→2,109）。三个迟到响应矩阵、换票重启并发修改、可见已读、原节流与同步生命周期均通过；7 张聊天截图逐像素一致。Swift 语法、diff check 和 Debug arm64 build-for-testing 通过；全部改动 Swift 文件不超过 800 行。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bx-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · AppState 存储与转发分离、消除 800 行例外（2026-11-10）

- `WDT_IOS1_REFACTOR_APPSTATE_MEMBERSHIP_SPLIT_20261110`。承接 `65a85182a9088b72b137c12b90ca56b6e1fe2236`，`BASED_ON_CANONICAL_HEAD=9ccea1e2b1932c03f111a73356dcf67e6576bbcc`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- AppState.swift 由 1,363 行减至 785 行。98 个计算属性与两个目录辅助方法原样移至 AppState+StoreFacades.swift（446 行）；apiContext didSet 的同步步骤依原顺序移至 RuntimeBindings（184 行），同文件承载实时回调注册和启动 splash 结束回调。两个原 private 配置方法为跨文件调用改为 internal，仍只有原初始化入口调用。诊断节流类和通知打开请求值类型分别移回 DiagnosticsSupport（743 行）和 IOSNotificationModels（418 行）；删除四个在原文件只有声明且无调用的 private String/URL 辅助方法。原存储成员、指定初始化和 deinit 保留，100 个迁出成员正文、两个回调、完整指定初始化及 didSet 步骤均与原提交逐字核对（必要缩进及配置函数 private→internal 除外）。新增 Swift 文件通过原 App target 四处 PBX 引用加入；不增部署配置或流程。因旧标识块混合存储/转发，本组须按新标识完整取原类、facades、runtime 与工程差分，不能只取旧单一属性块。Android/API 请求、字段、权限和数据库合同均无变更。
- `BlueStoneIM/AppState.swift` 15–785。
- `BlueStoneIM/Core/AppSupport/AppState+RuntimeBindings.swift` 3, 18–184。
- `BlueStoneIM/Core/AppSupport/AppStateDiagnosticsSupport.swift` 706–743。
- `BlueStoneIM/IOSNotificationModels.swift` 395–418。
- `BlueStoneIM/Core/AppSupport/AppState+StoreFacades.swift` 15–446。
- `BlueStoneIM.xcodeproj/project.pbxproj` 37, 623, 1277, 2078。
- 迁移前后 23 项既有用例全过，覆盖会话切换的迟到历史/实时/回执、普通换票并发保护、当前用户、实际认证/群目录/资料/回执界面、冷启、后台断连和通知打开；2,109 个 XCTest 标识/禁用标识保持一致。7 张聊天截图逐像素一致。初次构建发现 RuntimeBindings 缺少 withAnimation 所需 SwiftUI import，补齐后 Debug arm64 build-for-testing、Swift 解析、工程 plist 和 diff check 通过。全部 425 个 App Swift 与 137 个 XCTest Swift 文件均 ≤800 行。新编译索引覆盖 425/425 文件，原 107 属性仍为 48 个只读转发、8 个运行/截图输入、51 个撤销名称；694 个当前读取中 107 个位于 Core 与 AppState.swift 外，该清单仅供继续消费者核对，不代表全部输出已验收。结构映射及字节验证另见 phase2by-move-manifest.json、phase2by-structural-check.json。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2by-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 2 · 完整字段/消费者去向核对与资料页实际输出（2026-11-10）

- `WDT_IOS1_REFACTOR_FAVORITE_VIEW_OUTPUT_20261110`。承接 `8041e20a56a49b2c696a5ce2b9a762e90f0cf5a1`，`BASED_ON_CANONICAL_HEAD=9ccea1e2b1932c03f111a73356dcf67e6576bbcc`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 补充实际挂载 FilesView 的 UI 特征测试：收藏替换、清空和恢复更新图片；无关联系人变化不改该页截图，AppState 全局通知为 0，受控用例不发 HTTP。只改既有测试文件，无产品行为、接口、数据库或 Android 同步差分。另完成原 107 字段的真实去向核对（含已撤销字段的表单/请求局部结果、已有领域投影、纯写占位及运行/启动输入），不得把撤销 51 个旧名称误称为全部新建 Store；原 networkBannerVisible 实为公告显示开关，已由 conversationListPresentationStore.snapshot.showsAnnouncements 承接。当前 33 个界面文件的 107 处原字段读取逐处追到 Store 投影、父视图环境、延迟缓存、动作实时授权或启动/草稿生命周期。认证和会话/通讯录缓存经 80 ms 可取消任务在提交后读取，未发现遗漏的全局刷新依赖。全部对应行保存在 phase2bz-original-field-destinations.tsv 与 phase2bz-ui-read-chain-audit.tsv；该结论属于源码链路审计，iOS 15 运行/性能及整合后全量回归未据此冒充完成。
- `BlueStoneIMTests/IdentityAuthRoutingTests.swift` 8–68。
- 基线 4 项全过，候选 5 项全过，新增 1 项实际资料页用例，原结果/断言保持一致，XCTest 标识只增一项（2,109→2,110）。收藏后端结果发布、跨作用域集合隔离及真实 Tab/系统角标用例保持通过；新增用例保留 initial/replacement/unrelated/empty/restored 五张图片证据。7 张聊天截图逐像素一致，Debug arm64 build-for-testing、Swift 解析与 diff check 通过。测试文件 704 行；AppState 及 StoreFacades 无 @Published，整个 App 无主动 objectWillChange.send，DesignSystem 无 AppState 依赖。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase2bz-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 3 · 3a 本地消息原始发布与值快照特征（2026-11-10）

- `WDT_IOS1_REFACTOR_LOCAL_MESSAGE_MUTATION_BOUNDARY_20261110`。承接 `f5cd63f91f6065c23c8f30912eedff5ab608d1c9`，`BASED_ON_CANONICAL_HEAD=9ccea1e2b1932c03f111a73356dcf67e6576bbcc`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 先在未改消息存储实现时建立特征测试，记录本地编辑的四次既有发布（正文→编辑标志→状态→会话预览），并验证同消息 ID 跨会话隔离、保留的 Conversation/消息数组值快照、上传失败/重试、置顶收藏、附件 ID、回显及移除。阶段 3a 保留该发布粒度；后续 3b 按计划引入原子提交时应以新合同更新本项发布序列要求，不将旧粒度误当最终目标。本批只改既有测试，无产品/接口/数据库/Android 差分。
- `BlueStoneIMTests/ScopedMessageCallbackTests.swift` 2, 290–338。
- 未改产品代码的基线 29 项中 28 过、1 个既有上传重试进度断言失败；增加特征测试后候选 30 项中 29 过、同 1 失败，全部原结果/错误明细一致。失败为 testConversationStoreMarkAttachmentUploadRetryingUpdatesStatusProgressAndUploadStatus：期望 0.06，原实现按既有“重试不写假百分比”逻辑保留 nil，测试以 -1 回退显示；原断言未改，不冒称全过。新增特征用例通过；2,110→2,111 个 XCTest 标识，7 张聊天截图逐像素一致。最初测试夹具错误地赋值不可变 Conversation.id 的编译诊断保存为 fixture-build，已改为分别构造会话。Swift 解析、diff check 与 Debug arm64 build-for-testing 通过。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase3a-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 3 · 3a 首批本地消息与发送确认写入口收口（2026-11-10）

- `WDT_IOS1_REFACTOR_LOCAL_MESSAGE_MUTATION_BOUNDARY_20261110`。承接 `4d09566d75940bc35fed1cf75b820e96b26fa8e4`，`BASED_ON_CANONICAL_HEAD=9ccea1e2b1932c03f111a73356dcf67e6576bbcc`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 将 31 处原有发布数组修改收口到 mutateStoredMessage / mutateStoredMessageWindow 两个非逃逸 inout 入口：LocalMessages 28 处（25 个单消息赋值、追加、移除、管理员删除各一处），主 Store 节流后的上传进度赋值 2 处及远端发送确认整条替换 1 处。保留既有命名业务 API、ID/权限检查、每次原写入的发布边界、返回值和元数据更新顺序；Conversation.messages 及值快照语义继续保留。本批不引入批量提交、revision、作用域框架或消息独立存储；它们属于后续 3b/3c。局部快照/投影构造及其他回执/回应/历史写入仍待后续收口，不能把语义索引的 133 个 write/modify 角色简单减 31 当作真实剩余量。逐条源位置与操作类型见 phase3ab-write-moves.json。纯 iOS 内部状态写入，无请求、API、数据库、Android 或部署差分。
- `BlueStoneIM/Stores/ConversationStore+LocalMessages.swift` 3–608。
- `BlueStoneIM/ConversationStore.swift` 532, 536。
- `BlueStoneIM/Stores/ConversationStore+RemoteMerge.swift` 89。
- 40 项直接相关特征用例在改前/改后均为 39 过及同 1 个上传重试进度旧失败，全部结果与断言明细匹配；期望 0.06/实际 nil 的原断言保留。本地编辑四次发布、保留值快照、同 ID 会话隔离、新回显/删除、附件状态及进度、置顶/收藏、群邀请、撤回/管理员删除、发送确认和两个真实 HTTP 失败重试用例覆盖。补充在精确候选上执行的 4 项 RTC 去重/跨会话水位/重放冲突测试全过（候选补测，不冒称前后各跑）。2,111 个 XCTest 标识保持一致，7 张聊天截图逐像素一致。Debug arm64 build-for-testing、Swift 解析及 diff check 通过。改动 Swift 文件为 608、611、713 行，均不超 800。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase3ab-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 3 · 3a 回应、回执及历史窗口写入收口（2026-11-10）

- `WDT_IOS1_REFACTOR_MESSAGE_SIDECAR_HISTORY_BOUNDARY_20261110`。承接 `6faaf90898b03ef194c665ac2b3b22472de2d3fe`，`BASED_ON_CANONICAL_HEAD=9ccea1e2b1932c03f111a73356dcf67e6576bbcc`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 新增 28 个实际发布数组修改到上一批两种内部非逃逸 inout 入口：MessageExtras 23 处、整条回执替换 1 处、历史窗口保留 1 处、本地历史页追加/排序/线性合并替换 3 处。单元素 RHS 由借入的消息值读取；两处外部 makeReactionDetail 在原调用位置、已完成前一条发布之后且进入借用之前准备。回执 mappers 继续在整条替换前执行。新增两个原代码先行特征验证 mapper 看到的已提交回应/空明细、重复不调用 mapper、回应两步/明细一步发布、回执三个 mapper 依序在整条发布前读取 Store，以及保留值快照。前一批 31 与本批 28 个源语句互不重叠，累计 59；源码字面上直写 conversations[index].messages 的可变地址仅余两个内部入口。局部值快照/整会话/跨会话提交仍待 3b/3c，不据此称全部消息写入或存储分离已完成。没有新增接口、出站字段、数据库迁移或 Android 同步差分。
- `BlueStoneIM/Stores/ConversationStore+MessageExtras.swift` 3–563。
- `BlueStoneIM/Stores/ConversationStore+ReadState.swift` 386。
- `BlueStoneIM/Stores/ConversationStore+History.swift` 299。
- `BlueStoneIM/Stores/ConversationStore+HistoryMerge.swift` 43, 54, 118–121。
- `BlueStoneIMTests/ScopedMessageCallbackTests.swift` 340–416。
- 未改产品时，基线 27 项全过，增加两个 mapper 特征后 29 项全过（characterization-* 留存）；改造后仍 29 项全过，原结果/断言匹配。覆盖回应去重/补录、回执隐私与映射、迟到回执/两方向历史作用域、可见已读、RTC 跨会话/重放冲突和分页。XCTest 标识只新增两项（2,111→2,113），禁用标识不变；7 张聊天截图逐像素一致。Swift 解析、diff check 和 Debug arm64 build-for-testing 通过。多行 mergedWindow 迁移补齐完整标识后对相同基线复核通过，最终候选为当前源码字节。五个 Swift 文件为 563、620、622、295、416 行，均 ≤800。原上传重试 6% 断言旧失败仍见 phase3a/phase3ab，本批不改该断言，不将本批全过扩大为全套通过。逐条迁移见 phase3ac-write-moves.json。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase3ac-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 3 · 3b 内存版本与整会话提交首批

- `WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110`。承接 `4d0b91a6adae159453f8851fc20c217a12736e94`，`BASED_ON_CANONICAL_HEAD=9ccea1e2b1932c03f111a73356dcf67e6576bbcc`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 以单一 CurrentValueSubject<MemorySnapshot> 持有会话数组、其中的消息窗口/摘要/覆盖水位、未读总数及单调内存 revision；全部值准备后一起发布，替代 conversations 与 alertingUnreadTotal 两次独立 @Published 写入。24 处订阅引用改接稳定复用的 conversationUpdates / alertingUnreadUpdates，保留完整值快照及消息改后又改回的分页保护。编辑、本地回显、上传失败/重试/重发、消息失败/删除/撤回、发送确认与跨会话群审批改为一次整会话或整数组提交。memoryCommits 临时传递前后快照，聊天页以旧窗口判断追加、以旧消息数处理补页锚点，既有几何、8pt 补偿和已读围栏不变；Store 不永久保存上一窗口。3b 尚未完成：回应/历史等剩余多次修改、系统会话批次和真实分页完成/消息并发/重启边界仍须推进；未切独立消息存储，未做增量未读或后台合并。内存 revision 不替代 SQLite 版本、作用域及授权围栏。
- `BlueStoneIM/ChatViews.swift` 471。
- `BlueStoneIM/ContactsViews.swift` 316。
- `BlueStoneIM/ConversationStore.swift` 241–287, 517, 525–528。
- `BlueStoneIM/ConversationViews.swift` 225。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+PrimarySnapshotSync.swift` 232。
- `BlueStoneIM/Features/Chat/ChatViewLayout.swift` 494。
- `BlueStoneIM/Features/Chat/ChatViewTimeline.swift` 72–88。
- `BlueStoneIM/Features/Contacts/ContactGroupList.swift` 135。
- `BlueStoneIM/MainShellView.swift` 35。
- `BlueStoneIMTests/AvatarRealtimeSurfaceProjectionTests.swift` 268。
- `BlueStoneIMTests/DomainAttachmentAndQueuedReadTests.swift` 498。
- `BlueStoneIMTests/DomainBatchForwardAndUnreadProjectionTests.swift` 657。
- `BlueStoneIMTests/DomainGroupProjectionAndScopeTests.swift` 89, 169。
- `BlueStoneIMTests/DomainStoreTests.swift` 101, 751。
- `BlueStoneIMTests/DomainUnreadListAndFileStoreTests.swift` 341。
- `BlueStoneIMTests/HTTPAuthenticationFixtureTests.swift` 641。
- `BlueStoneIMTests/RealtimeReceiptRecoveryTests.swift` 182, 229, 248, 278。
- `BlueStoneIMTests/ScopedMessageCallbackTests.swift` 307, 310–315, 355, 388, 420–603。
- `BlueStoneIM/Stores/ConversationStore+LocalMessages.swift` 3–647。
- `BlueStoneIM/Stores/ConversationStore+RemoteMerge.swift` 89–94。
- `BlueStoneIMTests/HTTPMediaRecoveryAndVideoUploadTests.swift` 86, 89–92, 406, 409–412。
- `BlueStoneIM/Features/Chat/ChatViewHistory.swift` 291–293, 338–346。
- phase3ba：原基线 85 项为 84 过/1 个已知重试进度失败；最终 90 项为 89 过/同 1 失败，原失败断言明细一致，新增 5 项提交一致性、跨会话、分页改回保护和前窗口用例全过。两个附件测试原来捕获未写全 failure 的中间发布，现等待完整失败并精确断言类型/诊断文本；在原 HEAD 产品代码上先行验证这两个完整状态断言均通过（settled-baseline-*），未改变产品提示格式。computed publisher 首次引发角标重复，修复为稳定 lazy publisher 后原角标断言通过。最后版本一次整批出现 receipt durable-wait 超时，原失败保留于 receipt-timeout-*；同一构建单跑及整批复核均通过，未改该用例等待或断言，根因尚未证实。另 10 项滚动/已读用例通过（geometry-* 中还含上述回执复核 1 项）；7 张 PNG 逐像素一致，XCTest 标识 2,113→2,118（仅新增 5 项），禁用标识不变。Debug arm64 build-for-testing 通过；22 个 Swift 源/测试文件语法、≤800 行、镜像字节一致及 diff 检查通过。运行环境为 iOS 26.5 模拟器，未宣称 iOS 15 真机或整套测试通过。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase3ba-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 3 · 3b 回应事件、历史页与系统未读原子提交

- `WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110`。承接 `150863402c73ea7bb7b9a8ad2fd7002c463c289c`，`BASED_ON_CANONICAL_HEAD=9ccea1e2b1932c03f111a73356dcf67e6576bbcc`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 实时 reaction 不再分开发布计数、明细、已读与提醒：AppState 原入口在既有 tenant/dedupe 和有效已读水位判断后，调用 Store.applyReactionExtra，在局部值上依原顺序执行四步并一次发布；保留原 first-match/跨会话 eligible-read 选择、返回值、回放修补、恢复/兜底请求、乐观本地回应及回执隐私合同。重复修补及单项回应入口也改为一次提交；mapper 读取上一次完整 Store，3a 的临时中间发布断言明确更新为 3b 的一次完整发布，最终值/重复返回/保留快照不变。远端编辑/置顶跨匹配会话一次提交；历史 fallback 的追加/排序/RTC 冲突覆盖水位同版发布，包括插入数为零但必须退覆盖的情况；系统会话清未读按整个匹配批次提交。删除已由实时事件入口替代的三个 AppState 私有包装函数。新增一个独立测试源文件并以四个标准 PBX 引用加入原测试 target；没有新依赖/部署面。3b 仍未完成：Lifecycle 的预览/参与者/不可用摘要等多次修改及三个真实分页/离线边界仍待处理；3c/3d 未开始，持久化时机、SQLite revision 与作用域围栏不变。
- `BlueStoneIM/Stores/ConversationStore+MessageExtras.swift` 3–576。
- `BlueStoneIM/Stores/ConversationStore+HistoryMerge.swift` 17–62。
- `BlueStoneIM/Stores/ConversationStore+ReadState.swift` 65–74。
- `BlueStoneIM/Core/AppSupport/AppState+RealtimeMessageExtras.swift` 91–107, 244。
- `BlueStoneIMTests/ScopedMessageCallbackTests.swift` 367–372。
- `BlueStoneIM.xcodeproj/project.pbxproj` 373, 962, 1203, 2600。
- `BlueStoneIMTests/MessageSidecarCommitTests.swift` 6–225。
- phase3bb：17 项新鲜父版本基线全过，候选 24 项全过（7 项新增）；另 19 项历史/RTC/回执用例全过，与 exact parent 150863402 的既有 phase3ba-candidate 结果逐项一致，复用其基线，没有冒充重新运行父版本。合计 43 个不同目标用例全过，7 张 PNG 逐像素一致。原 runner 因新增 RTC 测试类扩大选择范围而在枚举分组比较处退出，24 项产品测试均已通过；保留原分组选取枚举，并用同一父版本两个完整 2,118 项清单交叉核对、对齐 29 个旧 RTC 选择项后验证为 2,118→2,125（精确新增 7，零删除，同类选择口径下禁用项不变），见 verified-comparison.log，未为此重复执行测试。Debug arm64 build-for-testing 通过；6 个 Swift 改动文件均 ≤800 行，语法、PBX lint、7 文件镜像字节一致、diff 检查通过。运行于 iOS 26.5 模拟器，未宣称 iOS 15 真机或整套测试全绿；前批重试进度旧失败及回执一次 durable-wait 超时记录未撤销。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase3bb-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 3 · 3b 生命周期元数据与排序批次

- `WDT_IOS1_REFACTOR_LIFECYCLE_ATOMIC_COMMIT_20261110`。承接 `f010aae36c5a6ed13c3c862b0693a9715f73c0b7`，`BASED_ON_CANONICAL_HEAD=9ccea1e2b1932c03f111a73356dcf67e6576bbcc`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 八个生命周期操作在局部值中完成后一次发布：置顶切换/恢复与最终排序；群全员禁言预览 lastMessage/time；单群移除参与者与 memberCount；全会话参与者移除；参与者变换批次；群参与者/人数更新；单聊不可用 subtitle/unread。保留原匹配、返回值、计数、空输入/空成员语义及不可用上下文/禁用提示/历史提示的既有发布次序；空批次和原 no-op 判断不变。参与者 transform 仍按原顺序调用，读取 Store 时现在看到上一完整批次，而不是前一行已更新的半批次；保留值快照验证通过。既有头像/资料整数组投影、消息/覆盖水位、持久化时机、SQLite revision 和作用域围栏不变。Store 直接可变会话入口的只读核对未再发现本批八项以外同方法内连续多次字段/排序写入；该源码核对不替代真实分页与离线边界验证，3b 未宣称完成，3c/3d 尚未开始。
- `BlueStoneIM/Stores/ConversationStore+Lifecycle.swift` 3–700。
- `BlueStoneIMTests/MessageSidecarCommitTests.swift` 227–338。
- phase3bc：在 exact parent f010aae36 的产品源码上先编译四个新原子性用例，18 项为 14 既有通过/4 新增按预期失败，明确暴露中间排序、分字段元数据和跨行 callback 半批次；最终候选相同 18 项全部通过，原 14 项结果/断言保持一致，四个声明修复用例由失败转为通过。初次测试夹具尝试修改 IMUser.name 的 let 字段导致编译失败，已改用既有 withName 值复制接口，失败构建留于 fixture-compile-*。原 HEAD 清单 2,125→新增测试后 2,129，前后产品比较阶段的 2,129 项标识及禁用标识保持不变。7 张 PNG 逐像素一致。Debug arm64 build-for-testing、两个 Swift 文件语法/≤800 行、镜像字节一致、diff 检查通过。运行在 iOS 26.5 模拟器，未证明 iOS 15 真机或整套测试通过；前批重试进度旧失败和回执单次 durable-wait 超时记录继续保留。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase3bc-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

## iOS1 架构重构阶段 3 · 3b 真实分页/离线边界与页归属预期修复

- `WDT_IOS1_REFACTOR_PAGED_SNAPSHOT_RECOVERY_CHARACTERIZATION_20261110`、`WDT_IOS1_REFACTOR_PAGED_COMMIT_EXPECTATIONS_20261110`。承接 `83132e6fe5e586ddf410a2d70790ab95809ded22`，`BASED_ON_CANONICAL_HEAD=9ccea1e2b1932c03f111a73356dcf67e6576bbcc`，iOS1 基线树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`。
- 新增真实 AppState.refreshRemoteSnapshot 入口的可暂停 HTTP 分页/410 重启及隔离 SQLite 夹具，覆盖末页合并后的 refresh-session 失效、未看过会话的消息明细变化及改后又改回、成功完成的内存/SQLite 缺失会话清理、同步版本推进，以及真实远端编辑按原异步流程落盘后由新的 AppState.applyCachedRemoteSnapshotIfAvailable 离线恢复正文/editRevision。只等原写入的 ticket/revision，不加额外补写。真实入口暴露了第一页全局清洗群资料（例如 memberCount 0→nil）被当作本地并发变化、使缺失会话无法清理的问题；didApply 现强制接收本页应用前快照，仅将该同步页面造成的非 protected 行变化更新到 expected；restarting 先保护全部未归因本地差异，再以实际恢复后的行作为 expected，保留已观测的变更/改回保护。保留每页可见、末页后独立授权校验、原清理/同步版本/SQLite 调度次序、一次重启预算和权限围栏。迁移全部调用方，包括既有 reducer 测试；未新增可选旧行为入口。业务读写作用域、数据格式、持久化时机、消息存放及算法未切换，3c/3d 仍待实施。
- `BlueStoneIM.xcodeproj/project.pbxproj` 374, 964, 1206, 2604。
- `BlueStoneIMTests/PagedSnapshotCommitTests.swift` 6–318。
- `BlueStoneIM/SyncEngineContract.swift` 28–39, 47–61。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+PrimarySnapshotSync.swift` 274。
- `BlueStoneIMTests/HTTPTransportTests.swift` 154, 156。
- `BlueStoneIMTests/SyncEngineTests.swift` 5–47。
- phase3bd：12 项原有分页/凭据/内存提交用例基线全过，最终候选 17 项全过（5 新增）；另 3 项既有 presentation 完成/重启/改回回归全过，合计 20 个不同目标用例。原产品的首次新测试运行中，末页失效保护与真实离线编辑恢复已过，两个分页消息用例因缺失会话残留失败，原失败保留于 pre-expectation-fix-*；初次测试还将改回比较点放在整次同步前，现改为第二页暂停点，保持“仅消息变化前后相等”的完整值断言，未删除缺失会话清理断言，并加强 SQLite 行集合校验。清理代码初版 Sendable teardown 访问 MainActor 字段的编译失败保留于 fixture-isolation-*，已用 MainActor.run 收敛，未弱化生产隔离。测试清单 2,129→2,134（仅 5 新增、零删除、禁用项不变），7 张 PNG 逐像素一致。Debug arm64 build-for-testing、5 个 Swift 文件语法/≤800 行、PBX lint、6 文件镜像字节一致及 diff 检查通过；运行于 iOS 26.5 模拟器，不宣称整套测试或 iOS 15 真机全过；既有重试进度旧失败和回执一次 durable-wait 超时记录保留。 Debug 构建最低系统为 iOS 15.0。证据见 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase3bd-*`。
- `NEW_DEPLOY_SURFACE=0`，`JENKINS_CHANGE=0`，`SECRET_PLACEMENT=unchanged`，`PROD_MUTATION=false`，`AUTO_ROLLBACK=false`。整合前需固定 iOS reviewer 独审。

---

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


## WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110 - phase 3c core candidate; Chat integration pending

Parent: 3fe4cb33d14e125a15d2184aa43f600347542878. No leased Chat file or either leased test file was changed. `Conversation.messages` is deleted. `Conversation` contains metadata only. The sole memory authority is `ConversationMemoryCell.current`, with separate metadata and windows keyed by the normalized complete LocalMessageScope identity and conversation ID. `ScopedMessageMemoryStore` reads/observes that authority without retaining a second message collection. `ConversationMessageSnapshot` is an explicit operation value for reducers, persistence and readers; no combined global list is stored or published under a new name. Single-message commits compare the target window; message-only changes do not publish metadata or ConversationStore.objectWillChange. Existing list input signatures still observe message fields that actually affect sender/mention output.

An incomplete scope remains empty. Data-preserving same-scope reauthentication retains its binding. Login invalidation, full-scope changes and reset retire it, so a retained observer cannot read a later login even when the scope hash returns to the same value. Original persistence timing, SQLite structure, ACK start sequence and authority fences remain. No general old-revision rejection was added. RTC cross-conversation dedupe, coverage rollback and recovery remain one explicit batch commit.

### WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110 - F1 / P2, original reviewer re-review required

Original finding identity remains F1 / P2. Report: `/Users/waisky/.codex/visualizations/2026/09/06/01a07610-bbde-71e0-a228-b4762d32b0a1/IOS1-V5-REVIEW-3fe4-20261110.md`.

Synchronous commands run against the latest pending frame and keep synchronous reads/return values inside the command. Notifications drain in frame order. A command from a notification callback queues behind all streams of the current frame; consecutive commands see earlier queued changes. Metadata, memory commits, unread and per-conversation message streams read the same published revision. Three remote apply entry points also enter this boundary. The Store metadata collection is read-only; writes use explicit commands.

Pagination observes message-side changes through the atomic commit stream. A page-only presentation UUID attributes each actual page frame before queued local changes are observed, including changes that return to their old complete value. It is not an authorization token, scope/session fence or persistence revision and never enters wire or database data. Last-page publication, completion authority validation, then absence cleanup/version/persistence keep their original order.

Validation: temporary proper-layout mirror Debug arm64 build-for-testing PASS; iOS26.5 simulator / SDK27, MinimumOSVersion15.0, CODE_SIGNING_ALLOWED=NO, bundle still app.xltest.com. 45 distinct focused tests passed: 44 in the first run; one old test seeded tenant data with an empty scope and then indexed an absent frame. That fixture now supplies its full five fields, retains every business assertion, and its targeted rerun passed. Product empty-scope behavior was not weakened. Five added regressions cover message-only output isolation, complete scope/login observer isolation, consecutive synchronous reentrancy, callback reset/scope clearing, and real page-publication reentrancy through normal completion and HTTP410 restart. Existing delayed callback, real paging/SQLite offline edit, RTC conflict and queued-read cases are included. Inventory 2134 -> 2139, exactly five additions and no removals; the same class-filter disabled set remains 720 (filtering, not a new product disable list). Seven Chat PNGs match phase3bd pixel-for-pixel. This is not a full-suite, iOS15 hardware, same-identity upgrade or performance claim. Existing retry-progress 0.06 and unexplained 3ba durable-wait records remain open historical limitations.

ACTUAL CHECKOUT IS NOT INTEGRATION-READY AND COMPLETE 3c IS NOT CLAIMED. Builds/screenshots used a temporary mirror with 13 read-only Chat/leased-test files adapted only there; those adapters are not in this commit. The mirror does not prove real-checkout integration. Unique next step: after the original UI lanes are reviewed/frozen and the coordinator releases their write leases, this source integrates explicit message snapshots/per-conversation subscriptions and MemoryCommit.messageChanges into them, builds/tests the real checkout, then returns to fixed reviewer 01a07610-bbde-71e0-a228-b4762d32b0a1. Phase3d incremental unread, background work and phases4-6 remain unfinished.

Evidence root `/private/tmp/im4-ios1-v5-phase0.CZP8fN/`: phase3c-build.log; phase3c.xcresult / phase3c-tests.log (first failure retained); phase3c-reaction-retest.xcresult / .log; phase3c-final-checks.json; phase3c-enumeration.json / phase3c-filtered-enumeration.json; phase3c-snapshots.log; phase3c-mirror-only-adapters.patch; phase3c-command-boundaries.json.

Original BASED_ON_CANONICAL_HEAD=9ccea1e2b1932c03f111a73356dcf67e6576bbcc. Read-only precommit observation: canonical HEAD=4cefd12de7b5da4860f3f4c4eba77f713e129a89, iOS1 tree=4e8818176af6b939610e04fed7cac17daedc6c71 (the frozen phase2 tree already in source history). No rebase, overwrite, integration or push. Exact local commit/parent/tree are in this source delivery. Rollback is the complete inverse commit, preserving the UI lanes and user data; no database/config/volume cleanup or automatic rollback.

NEW_DEPLOY_SURFACE=0; JENKINS_CHANGE=0; SECRET_PLACEMENT=unchanged; PROD_MUTATION=false; AUTO_ROLLBACK=false; REVIEW=REQUIRED_IOS_PENDING.

Ranges are navigation only: take complete markers and the commit diff. PBX adds only the two app files and one test file to the original Sources phase.

| Path | Marker ranges |
| --- | --- |
| `BlueStoneIM.xcodeproj/project.pbxproj` | memory 2-3007 |
| `BlueStoneIM/AppState.swift` | memory 1-788 |
| `BlueStoneIM/CachedRemoteSnapshot.swift` | memory 1-508 |
| `BlueStoneIM/ContactStore.swift` | memory 1-781 |
| `BlueStoneIM/ContactsViews.swift` | memory 1-799 |
| `BlueStoneIM/ConversationStore.swift` | memory 1-772; F1 274-725 |
| `BlueStoneIM/ConversationViews.swift` | memory 1-657 |
| `BlueStoneIM/Core/AppSupport/AccountSession/AppState+WorkbenchAndSplash.swift` | memory 1-736 |
| `BlueStoneIM/Core/AppSupport/AppState+ActiveConversationLifecycle.swift` | memory 1-91 |
| `BlueStoneIM/Core/AppSupport/AppState+AttachmentCacheResources.swift` | memory 1-323 |
| `BlueStoneIM/Core/AppSupport/AppState+AttachmentDownload.swift` | memory 1-550 |
| `BlueStoneIM/Core/AppSupport/AppState+AttachmentURLsAndProgress.swift` | memory 1-448 |
| `BlueStoneIM/Core/AppSupport/AppState+AttachmentUpload.swift` | memory 1-662 |
| `BlueStoneIM/Core/AppSupport/AppState+AvatarRouting.swift` | memory 1-140 |
| `BlueStoneIM/Core/AppSupport/AppState+BatchForwarding.swift` | memory 1-722 |
| `BlueStoneIM/Core/AppSupport/AppState+ContactCardMessagePresentation.swift` | memory 1-106 |
| `BlueStoneIM/Core/AppSupport/AppState+ContactRelationships.swift` | memory 1-490 |
| `BlueStoneIM/Core/AppSupport/AppState+ConversationReadState.swift` | memory 1-322 |
| `BlueStoneIM/Core/AppSupport/AppState+ConversationsHistory.swift` | memory 1-556 |
| `BlueStoneIM/Core/AppSupport/AppState+DurableReadAck.swift` | memory 1-358 |
| `BlueStoneIM/Core/AppSupport/AppState+FileOpenAndSnapshots.swift` | memory 1-327 |
| `BlueStoneIM/Core/AppSupport/AppState+FilesAttachments.swift` | memory 1-438 |
| `BlueStoneIM/Core/AppSupport/AppState+GroupCreationAndSettings.swift` | memory 1-548 |
| `BlueStoneIM/Core/AppSupport/AppState+GroupHistoryBoundary.swift` | memory 1-219 |
| `BlueStoneIM/Core/AppSupport/AppState+GroupMembershipLifecycle.swift` | memory 1-274 |
| `BlueStoneIM/Core/AppSupport/AppState+GroupsAnnouncements.swift` | memory 1-141 |
| `BlueStoneIM/Core/AppSupport/AppState+HistoryPaging.swift` | memory 1-390 |
| `BlueStoneIM/Core/AppSupport/AppState+MediaSending.swift` | memory 1-362 |
| `BlueStoneIM/Core/AppSupport/AppState+MessageActions.swift` | memory 1-297 |
| `BlueStoneIM/Core/AppSupport/AppState+MessageEditing.swift` | memory 1-332 |
| `BlueStoneIM/Core/AppSupport/AppState+MessageForwardAndReaction.swift` | memory 1-152 |
| `BlueStoneIM/Core/AppSupport/AppState+MessageModerationAndReports.swift` | memory 1-336 |
| `BlueStoneIM/Core/AppSupport/AppState+MessageSendingAttachments.swift` | memory 1-232 |
| `BlueStoneIM/Core/AppSupport/AppState+OutgoingAttachmentRecovery.swift` | memory 1-322 |
| `BlueStoneIM/Core/AppSupport/AppState+ReadReceiptPresentation.swift` | memory 1-313 |
| `BlueStoneIM/Core/AppSupport/AppState+RealtimeEventDispatch.swift` | memory 1-495 |
| `BlueStoneIM/Core/AppSupport/AppState+RealtimeGroupAndReadEvents.swift` | memory 1-457 |
| `BlueStoneIM/Core/AppSupport/AppState+RealtimeMessageExtras.swift` | memory 1-296; F1 76-155 |
| `BlueStoneIM/Core/AppSupport/AppState+RealtimeSequenceRecovery.swift` | memory 1-329 |
| `BlueStoneIM/Core/AppSupport/AppState+RemoteErrorHandling.swift` | memory 1-469 |
| `BlueStoneIM/Core/AppSupport/AppState+SearchConversationSettings.swift` | memory 1-749 |
| `BlueStoneIM/Core/AppSupport/AppState+StickerLibraryActions.swift` | memory 1-371 |
| `BlueStoneIM/Core/AppSupport/AppState+StickerUploadAndHydration.swift` | memory 1-524 |
| `BlueStoneIM/Core/AppSupport/AppState+TextSending.swift` | memory 1-272 |
| `BlueStoneIM/Core/AppSupport/AppStatePolicySupport.swift` | memory 1-690 |
| `BlueStoneIM/Core/AppSupport/Calls/AppState+ActiveCallActions.swift` | memory 1-612 |
| `BlueStoneIM/Core/AppSupport/Calls/AppState+CallSystemEvents.swift` | memory 1-716 |
| `BlueStoneIM/Core/AppSupport/Calls/AppState+RTCPeerPresentation.swift` | memory 1-415 |
| `BlueStoneIM/Core/AppSupport/ConversationSequenceAndNotificationSupport.swift` | memory 1-278 |
| `BlueStoneIM/Core/AppSupport/ConversationTimelineSupport.swift` | memory 1-338 |
| `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugAvatarFixtures.swift` | memory 1-505 |
| `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugGroupFixtures.swift` | memory 1-521 |
| `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift` | memory 1-416 |
| `BlueStoneIM/Core/AppSupport/FriendAndWorkspaceDiagnostics.swift` | memory 1-514 |
| `BlueStoneIM/Core/AppSupport/GroupFileMapping/AppState+GroupAuthorityProjection.swift` | memory 1-479 |
| `BlueStoneIM/Core/AppSupport/GroupFileMapping/AppState+GroupDetailProjection.swift` | memory 1-398 |
| `BlueStoneIM/Core/AppSupport/GroupFileMapping/AppState+RemoteConversationProjection.swift` | memory 1-476; F1 176-436 |
| `BlueStoneIM/Core/AppSupport/GroupFileMapping/AppState+RemoteFileMapping.swift` | memory 1-626 |
| `BlueStoneIM/Core/AppSupport/GroupFileMapping/AppState+RemoteGroupFileMapping.swift` | memory 1-448 |
| `BlueStoneIM/Core/AppSupport/InteractionPolicy/AppInteractionPolicy.swift` | memory 1-314 |
| `BlueStoneIM/Core/AppSupport/LocalMessageAndContactProjectionSupport.swift` | memory 1-394 |
| `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+DeliveryAcknowledgements.swift` | memory 1-148 |
| `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+IdentityPresentation.swift` | memory 1-428 |
| `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+MessageSidecarSync.swift` | memory 1-535 |
| `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift` | memory 1-637; F1 29-298 |
| `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+RemoteMessageStateMapping.swift` | memory 1-214 |
| `BlueStoneIM/Core/AppSupport/RemotePayloadAndFileProjectionSupport.swift` | memory 1-426 |
| `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+AvatarRealtimeAuthority.swift` | memory 1-666 |
| `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+CachedRemoteSnapshot.swift` | memory 1-283 |
| `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+LocalMessageScope.swift` | memory 1-327 |
| `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+PrimarySnapshotSync.swift` | memory 1-367; F1 232-248 |
| `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+ProfileAndTenantAuthority.swift` | memory 1-568 |
| `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteAuthState.swift` | memory 1-593 |
| `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+RemoteRegistrationSnapshotSync.swift` | memory 1-698 |
| `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+SnapshotPersistence.swift` | memory 1-647 |
| `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+WorkspaceAccessErrors.swift` | memory 1-618 |
| `BlueStoneIM/Core/AppSupport/TenantSession/AppState+TenantInboxMapping.swift` | memory 1-430 |
| `BlueStoneIM/Core/AppSupport/TenantSession/AppState+TenantProfileAndRelations.swift` | memory 1-472 |
| `BlueStoneIM/Core/Networking/IMAPIClient+Files.swift` | memory 1-648 |
| `BlueStoneIM/Core/Networking/IMAPIClient+Messages.swift` | memory 1-587 |
| `BlueStoneIM/Domain/ConversationMessageSnapshot.swift` | memory 3-104 |
| `BlueStoneIM/Domain/ConversationModels.swift` | memory 1-312 |
| `BlueStoneIM/Features/Contacts/ContactGroupDetail.swift` | memory 1-582 |
| `BlueStoneIM/Features/Contacts/ContactGroupList.swift` | memory 1-311 |
| `BlueStoneIM/Features/Contacts/ContactUserProfile.swift` | memory 1-707 |
| `BlueStoneIM/Features/Contacts/GroupHistoryScreenshots.swift` | memory 1-277 |
| `BlueStoneIM/Features/Contacts/GroupSharingViews.swift` | memory 1-344 |
| `BlueStoneIM/Features/Conversations/ConversationListMentions.swift` | memory 1-495 |
| `BlueStoneIM/Features/Conversations/ConversationListProjection.swift` | memory 1-294 |
| `BlueStoneIM/Features/Conversations/ConversationListRenderCache.swift` | memory 1-577 |
| `BlueStoneIM/Features/Conversations/ConversationListRows.swift` | memory 1-506 |
| `BlueStoneIM/Features/Conversations/ConversationListTime.swift` | memory 1-176 |
| `BlueStoneIM/Features/Conversations/QuickAddViews.swift` | memory 1-604 |
| `BlueStoneIM/GroupMuteMode.swift` | memory 1-451 |
| `BlueStoneIM/IMAPIProtocol.swift` | memory 1-582 |
| `BlueStoneIM/LegacySnapshotImporter.swift` | memory 1-23 |
| `BlueStoneIM/LocalMessageRepository.swift` | memory 1-223 |
| `BlueStoneIM/MockData.swift` | memory 1-266 |
| `BlueStoneIM/SnapshotCache.swift` | memory 1-217 |
| `BlueStoneIM/Stores/ConversationStore+History.swift` | memory 1-626; F1 101-304 |
| `BlueStoneIM/Stores/ConversationStore+HistoryMerge.swift` | memory 1-306; F1 6-133 |
| `BlueStoneIM/Stores/ConversationStore+Lifecycle.swift` | memory 1-739; F1 7-715 |
| `BlueStoneIM/Stores/ConversationStore+LocalMessages.swift` | memory 1-697; F1 8-651 |
| `BlueStoneIM/Stores/ConversationStore+MessageExtras.swift` | memory 1-602; F1 21-590 |
| `BlueStoneIM/Stores/ConversationStore+ReadState.swift` | memory 1-644; F1 34-628 |
| `BlueStoneIM/Stores/ConversationStore+RemoteMerge.swift` | memory 1-723; F1 40-626 |
| `BlueStoneIM/Stores/ConversationStore+Sync.swift` | memory 1-462 |
| `BlueStoneIM/Stores/ConversationStore+Types.swift` | memory 1-518 |
| `BlueStoneIM/Stores/ScopedMessageMemoryStore.swift` | memory 4-129 |
| `BlueStoneIMTests/AttachmentDownloadTests.swift` | memory 1-582 |
| `BlueStoneIMTests/AvatarRealtimeSurfaceProjectionTests.swift` | memory 1-371 |
| `BlueStoneIMTests/DomainAttachmentAndQueuedReadTests.swift` | memory 1-710 |
| `BlueStoneIMTests/DomainBatchForwardAndUnreadProjectionTests.swift` | memory 1-785 |
| `BlueStoneIMTests/DomainGroupProjectionAndScopeTests.swift` | memory 1-800 |
| `BlueStoneIMTests/DomainHistoryAndReadReceiptTests.swift` | memory 1-693 |
| `BlueStoneIMTests/DomainHistoryBoundaryAndDirectoryTests.swift` | memory 1-789 |
| `BlueStoneIMTests/DomainInboxAndConversationReadStateTests.swift` | memory 1-798 |
| `BlueStoneIMTests/DomainMessageActionsAndInitialSyncTests.swift` | memory 1-732 |
| `BlueStoneIMTests/DomainMessageMergeAndForwardTests.swift` | memory 1-706 |
| `BlueStoneIMTests/DomainMessageMutationAndActionMenuTests.swift` | memory 1-716 |
| `BlueStoneIMTests/DomainOlderHistoryAndConversationListTests.swift` | memory 1-786 |
| `BlueStoneIMTests/DomainQueuedReadAndGroupProjectionTests.swift` | memory 1-792 |
| `BlueStoneIMTests/DomainRTCHeartbeatTests.swift` | memory 1-708 |
| `BlueStoneIMTests/DomainRTCJoinAndPeerResolutionTests.swift` | memory 1-658 |
| `BlueStoneIMTests/DomainRTCPreviewAndMediaStateTests.swift` | memory 1-752 |
| `BlueStoneIMTests/DomainRTCTerminalAndMainShellTests.swift` | memory 1-784 |
| `BlueStoneIMTests/DomainStoreTestFixtures.swift` | memory 1-519 |
| `BlueStoneIMTests/DomainStoreTests.swift` | memory 1-798 |
| `BlueStoneIMTests/DomainUnreadListAndFileStoreTests.swift` | memory 1-789 |
| `BlueStoneIMTests/DomainUserAuthorityAndSearchJumpTests.swift` | memory 1-690 |
| `BlueStoneIMTests/GroupMuteModeTests.swift` | memory 1-795 |
| `BlueStoneIMTests/HTTPAccountPolicyAndGroupLifecycleTests.swift` | memory 1-781 |
| `BlueStoneIMTests/HTTPAuthenticationFixtureTests.swift` | memory 1-712 |
| `BlueStoneIMTests/HTTPGroupAvatarAndAttachmentContractTests.swift` | memory 1-681 |
| `BlueStoneIMTests/HTTPGroupProfileAuthorityTests.swift` | memory 1-737 |
| `BlueStoneIMTests/HTTPMediaRecoveryAndVideoUploadTests.swift` | memory 1-726 |
| `BlueStoneIMTests/HTTPMessageSendAndMediaRecoveryTests.swift` | memory 1-762 |
| `BlueStoneIMTests/HTTPPhonePolicyAndProfileProjectionTests.swift` | memory 1-800 |
| `BlueStoneIMTests/HTTPProductionRoutingAndEnterpriseContextTests.swift` | memory 1-773 |
| `BlueStoneIMTests/HTTPTransportTests.swift` | memory 1-732 |
| `BlueStoneIMTests/HTTPVerificationContactAndRemarkTests.swift` | memory 1-743 |
| `BlueStoneIMTests/HTTPWorkspaceAndMessageSendTests.swift` | memory 1-760 |
| `BlueStoneIMTests/IdentityAuthRoutingTests.swift` | memory 1-704 |
| `BlueStoneIMTests/IdentityChatPresentationTests.swift` | memory 1-776 |
| `BlueStoneIMTests/IdentityContactPresentationTests.swift` | memory 1-772 |
| `BlueStoneIMTests/IdentityPresentationTests.swift` | memory 1-743 |
| `BlueStoneIMTests/LocalMessageTestFixture.swift` | memory 1-214 |
| `BlueStoneIMTests/MessageDatabaseOutboxTests.swift` | memory 1-503 |
| `BlueStoneIMTests/MessageSidecarCommitTests.swift` | memory 1-343 |
| `BlueStoneIMTests/PagedSnapshotCommitTests.swift` | memory 1-339; F1 76-82 |
| `BlueStoneIMTests/RTCCallRecordMessageTests.swift` | memory 1-579 |
| `BlueStoneIMTests/RTCCallRecordProjectionTests.swift` | memory 1-374 |
| `BlueStoneIMTests/RealtimeReceiptRecoveryTests.swift` | memory 1-456 |
| `BlueStoneIMTests/RealtimeTransportWireTests.swift` | memory 1-498 |
| `BlueStoneIMTests/ScopedMessageCallbackTests.swift` | memory 1-606 |
| `BlueStoneIMTests/ScopedMessageMemoryTests.swift` | memory 5-72; F1 74-160 |
| `BlueStoneIMTests/ScopedResponseFenceTests.swift` | memory 1-694 |
| `BlueStoneIMTests/SnapshotCacheTests.swift` | memory 1-667 |


## Wuffs fallback 独立静态 C target（2026-11-10）

标识：`WDT_IOS1_REFACTOR_WUFFS_STATIC_TARGET_20261110`。仅为阶段 5 前置编译边界，不表示 Core→DesignSystem→Domain→Data→Stores→Features 模块化已完成。用户本轮已授权本地实现；实际 PBX 唯一 writer 在存储 source 冻结 `abe8b7cc9e798195109f30d49127988c9ec29f25` 注册后由 root 转交。本分支 `codex/ios1-wuffs-static-target-20261110` 的 parent / `BASED_ON_CANONICAL_HEAD` 是已整合 `4cefd12de7b5da4860f3f4c4eba77f713e129a89`，基线 IOS1 tree `4e8818176af6b939610e04fed7cac17daedc6c71`。原布局分支/ref `codex/ios1-chat-layout-split-20261110` / `2061de3d1137697b69d029caac5c44e64257b071` 保留不重写。

真实候选只修改 `BlueStoneIM.xcodeproj/project.pbxproj` 和本功能追加段。PBX 的 15 个完整标识块包住 5 个被改既有对象及 10 个必要新对象，以标识及对象 ID 为准，不按整文件覆盖合并：

- 新建 native target `WXTGIFFallback`（`41352719D32DE077C3519B8F`），product 为 `libWXTGIFFallback.a` / `com.apple.product-type.library.static`。新 Sources phase 仅复用原 `GIFFallbackDecoder.c in Sources` build-file 对象 `A04700000000000000000001`；该项从 App 原 Sources phase 移出，不重复编译。原 C/H 文件引用不动。
- App Frameworks 增加静态库 product 链接；App dependencies 增加指向新 C target 的依赖／proxy；Products group 和 project.targets 注册新 product/target。未增加动态库嵌入或资源 phase。
- C target 只有 Debug / Release 两配置，均 `IPHONEOS_DEPLOYMENT_TARGET=15.0`、`PRODUCT_NAME=$(TARGET_NAME)`、`SKIP_INSTALL=YES`、`SUPPORTED_PLATFORMS=iphoneos iphonesimulator`、`TARGETED_DEVICE_FAMILY=1`。其它 C 编译规则继续继承原 project 设置，不改 App/Test 既有配置、身份或签名。
- `SWIFT_OBJC_BRIDGING_HEADER=BlueStoneIM/GIFFallbackDecoder.h` 在 App 两配置保持原值；WXTGIFInspect/Decode/Free 的接口、所有 C/H/Swift 字节均不变。`wuffs-v0.3.c` 仍只由 wrapper 的相对 include 消费，不作为单独源编译。Wuffs LICENSE、图片资产及其它资源归属不动，未加 Package／Swift wrapper／缓存／限流器。

代码输入 SHA-256：

| 输入 | SHA-256 |
| --- | --- |
| BlueStoneIM/GIFFallbackDecoder.c | `e6a17d8a5362a578d9321e781dab5bc848419c96d74e97c4639a5d42cad2e1c0` |
| BlueStoneIM/GIFFallbackDecoder.h | `4b140ff2f513d7ef13ecbfd4899961e2b980dbb64fafddea1dde85cd7d0fee8a` |
| BlueStoneIM/ThirdParty/Wuffs/wuffs-v0.3.c | `82c6741dd751eb962a287882991836498526eb02dbe0c7f19adc01810b8bac96` |
| BlueStoneIM/ThirdParty/Wuffs/LICENSE | `0d542e0c8804e39aa7f37eb00da5a762149dc682d7829451287e11b938e94594` |
| BlueStoneIM/StickerGIFRenderer.swift | `f04302aa8a3ef0f743252a3a832c38c4ff32249f5f260c6075fb11e1cec954e1` |
| BlueStoneIM.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved | `c8fb6bca8f80692df7742e2184ee5a63437d373ce4579a4ec31929003997c87d` |

验证证据在 `/private/tmp/im4-ios1-wuffs-static-prototype.WcnAJw/candidate-summary.json`。明确来源：完整构建与测试都运行于自有保留相对目录的私有副本 `source/code/apps/ios-chat-1`，并非实际 Git 工作区。副本最初 641 个 tracked IOS1 文件逐字节匹配上述 canonical exact 树；实际分支应用工程语义差分及标识后，641 个输入又与私有副本逐字节核对相同（本索引最后追加，不属于编译输入）。未对 source3c 现场或 canonical 运行构建。

私有验证：原 BlueStoneIM scheme、锁定依赖、jobs≤4、CODE_SIGNING_ALLOWED=NO，自有 DerivedData/SourcePackages 和 iPhone 17 / iOS 26.5 模拟器 `A43C9AAC-48D1-44E2-BE73-D3AEB3BD4463`。Debug App/C/XCTest build-for-testing、Release App/C build 均通过；原 `MediaGIFPlaybackTests.swift` 中 19 项 fallback/帧/预算/播放器/URL恢复/取消 focused 用例全过，测试源码未改。临时 C ABI 程序直接链接新 Debug 静态库，在同一模拟器验证 Inspect、Decode、Free、精确像素、非法输入、取消及后续解码恢复通过。首次临时程序链接缺覆盖率 runtime 的失败保留；给临时程序添加与 build-for-testing 库匹配的 `-fprofile-instr-generate` 后通过，没有关闭覆盖率或改产品代码。

带完整标识的实际候选 PBX 与已构建原型仅源注释不同，解析后的全部工程对象完全相同；将候选 PBX 原样同步私有副本，再执行 Debug/XCTest 和 Release 增量构建均通过。已执行 19 项用例对应的 App/测试 Mach-O、Debug/Release App 与静态库哈希均保持不变，因此复用原测试结果，不重复宽套。两配置静态库均仅含一个 `GIFFallbackDecoder.o`，App 的三个 WXT API 各定义一次、无 WXT 动态依赖；C 对象与 App Mach-O 的 minos、App/测试 Info.plist 的最低版本均为 15.0。真实运行系统是 iOS 26.5，SDK 为 iPhoneSimulator 27.0；未验证 iOS 15 真机、device build、签名归档、完整测试套或覆盖升级。

整合依赖：本分支故意不包含 `abe8b7cc9e798195109f30d49127988c9ec29f25` 的 3c 新文件注册。后续由唯一 Gate／原 source 将两个已审逻辑差分按实际项目语义承接，保留那些注册，再验证组合工程；禁止拿本候选整个 PBX 覆盖 source3c 工程。DesignSystem／Contacts↔Chat 冲突边界仍冻结，不由此恢复写入。实际 PBX 自此冻结供同一 R2（`01a07610-bbde-71e0-a228-b4762d32b0a1`）独审，写权后续释放由 root 协调；main 只由 R7 整合。

回退：针对本功能移除 App→C target 依赖及静态库链接，把原 C build-file 项放回 App Sources，再移除本功能新 target/product/config/proxy/phase 对象；保留其它注册、C/H/Wuffs/资源/桥接头及同事成果，不整文件覆盖，不自动执行回退。实际候选仅本地提交；未 push、发布、签名或安装真实设备。

`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=unchanged`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`、`REVIEW=REQUIRED_IOS_PENDING`。


## 聊天布局构建体提取（2026-11-10）

标识：`WDT_IOS1_REFACTOR_CHAT_LAYOUT_SPLIT_20261110`。

目的：阶段 4 第一轮的结构拆分。将 `ChatView.unlockedBody` 按顶部上下文、时间线容器、输入区、消息/用户覆盖层和连续页面修饰器链提取为同一 `ChatView` 的小构建体；复用现有四个已注册文件，不新增 View 状态、观察层、缓存或第三方依赖。原 `conversationHeader`、`messageTimeline` 和 `ChatComposer` 的外部接口不变，原 AnyView/Group/ZStack/VStack、观察包装、修饰器相对顺序、条件、参数、事件回调内容保留。`GroupAnnouncementSheet` 的原长构建体另提取原样的头部卡片。

实际代码基线/parent 为委派指定 `3fe4cb33d14e125a15d2184aa43f600347542878`，IOS1 tree `218069533c47be86693f775e5e849b085d5b44de`；隔离目录 `/Users/waisky/.codex/worktrees/ios1-layout-parallel-20261110/IM4`，分支 `codex/ios1-chat-layout-split-20261110`。`BASED_ON_CANONICAL_HEAD=NO`：这是供原 source owner 收口的并行子候选，不能直接整合 main；只读观察到 main 为 `e3f4bb974a2c6a055f50bf82d84a1fdb0aaa20db`、其 IOS1 仍为旧树 `74c2ad98898203ce3b44fd5c2db5b8412b3e12f0`，未切换或覆盖该工作区。

| 文件（均位于 BlueStoneIM/Features/Chat） | 本功能行范围 | 内容及依赖 |
| --- | --- | --- |
| ChatViewLayout.swift | 4–412 | unlockedBody 仅计算原值快照并依次组合布局、会话生命周期、媒体 sheet、消息 sheet、删除提示和进入/轮询链；保留原时间线接口、返回底部、键盘和输入区参数连线。425 行。 |
| ChatHistorySupportViews.swift | 240–483 | 顶部公告/置顶/搜索、群禁言状态、消息动作和用户快捷动作覆盖层；原观察边界、权限读取和动作顺序保留。483 行。 |
| ChatComposerInputViews.swift | 216–303 | 原发送闭包内容迁至 sendComposerDraft，原提及/回复快照、失败草稿回填、发送后收键盘/未读处理与状态批次顺序保留。303 行。 |
| ChatConversationSheets.swift | 197–366、571–691 | 群公告头部卡片、原媒体与消息 sheet 连续修饰器链；原焦点、返回、dismiss、回执观察与编辑成功校验保留。691 行。 |

14 处提取/展开后的源码段在忽略行首缩进后与基线一致；四文件内全部 `some View` 构建体 ≤150 行，最长为 116 行。源码补丁 `/private/tmp/im4-ios1-layout-parallel.LMrcqA/source-candidate.patch`，SHA-256 `0d46e13e31c1a6a53152de6cc3f3fceda60d247f2033f274f1cd5386238ecf76`；最终提交可按本唯一标识及本分支定位，完整提取映射见同目录 `extraction-manifest.json`，构建体范围见 `structural-check.json`。

验证证据：`/private/tmp/im4-ios1-layout-parallel.LMrcqA/candidate-summary.json`。本任务私有镜像/DerivedData、私有 iPhone 17 模拟器 `2830E6D9-B89A-4BF1-92A2-E511BF29B380`，原 BlueStoneIM scheme/target、锁定依赖、Debug arm64、`-jobs 4`、`CODE_SIGNING_ALLOWED=NO` 的 build-for-testing 通过。基线和候选相同 50 项用例均为 49 过/1 个既有失败，逐项结果及该失败的 3 条断言一致；其中 40 项滚动/键盘/已读/手势回归全部通过。既有失败为 `testReturnToBottomControlIsAdaptiveAccessibleAndDoesNotResizeTimeline` 的原样式源码断言（原测试 56、62、64 行），测试未改。未新增、删除或修改测试，两个时间线测试文件均保持只读。

七张既有聊天 PNG 逐像素一致（`snapshot-comparison.log`），覆盖私聊/群聊、长标题、RTL、大字、深浅色及群禁言状态；基线/候选截图分别保存在 `baseline-snapshots` / `candidate-snapshots`。群公告卡片及消息动作覆盖层未另增交互快照，凭原样片段核对不能替代真实交互验收。制品 Bundle ID 保持 `app.xltest.com`、MinimumOSVersion=15.0；实测 iOS 26.5 模拟器，未验证 iOS 15 真机、Release、全套测试或同签名覆盖安装。

依赖与合并注意：无需 PBX 注册，未改工程、Domain、Stores、Core、ChatViews.swift 或其它聊天文件。后续真实消息存储迁移须由原 source owner 覆盖本次迁出读取点：ChatComposerInputViews.sendComposerDraft 的消息计数；ChatConversationSheets.chatMediaPresentation 的回执/附件消息快照和 chatMessagePresentation 的编辑成功当前消息校验；ChatViewLayout.chatEntryLifecycle 的缓存消息判定。本轮未更改这些值快照读取或引入只读代理。后续 ScrollIntent/行模型、UICollectionView/几何替换及存储切换均不在本候选范围。

回退：以本功能完整提交/补丁为单位由原 owner 审核后恢复，不整文件覆盖、不回退他人标识；本任务不执行自动回退、merge、push、真实设备安装、签名或发布。代码候选本地冻结，供固定 reviewer“iOS 客户端独立审查 接替 R2”（`01a07610-bbde-71e0-a228-b4762d32b0a1`）独审及原 source owner 组合验证；实施者不自行 APPROVE。

`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=unchanged`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`、`REVIEW=REQUIRED_IOS_PENDING`。

## 阶段 4 首轮：共享 Composer、增量行模型与 ScrollIntent（2026-11-10）

标识：`WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110`、`WDT_IOS1_REFACTOR_SCROLL_INTENT_20261110`、`WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110`。本节仅追加，不替换既有标识。

基线为指定 parent `3fe4cb33d14e125a15d2184aa43f600347542878`，IOS1 tree `218069533c47be86693f775e5e849b085d5b44de`。实现工作区 `/Users/waisky/.codex/worktrees/ios1-timeline-parallel-20261110/IM4`，分支 `codex/ios1-timeline-incremental-20261110`，`BASED_ON_CANONICAL_HEAD=NO`。本候选仅供原固定 R2 独审和原 source owner 组合，不进入 canonical/main，不推送、安装真实设备、签名或发布。

组合输入：协调器扩展四文件排他写权后，按 Git 对象取入 exact `2061de3d1137697b69d029caac5c44e64257b071` 的 ChatViewLayout.swift、ChatConversationSheets.swift、ChatHistorySupportViews.swift、ChatComposerInputViews.swift，并只追加该提交的完整 CHANGE_MARKERS 功能段。原布局标识保留；ChatConversationSheets.swift、ChatHistorySupportViews.swift 仍逐字节等于 2061。其余两个布局文件在已审结构上新增本节 Composer 接线/调试计数。R2 的 APPROVE 仅属于 3fe4→2061 布局 delta，不是本组合或累计改造的批准，也不关闭阶段 3 F1。

实际接线：ChatView 以 `@State` 持有 ComposerState 引用，草稿、选区、回复、提及及工具/表情开关由同一 Draft 管理；旧名字仅为该对象的命令访问入口，不再有第二份 @State 草稿。ChatComposer 接收同一引用和按完整五字段 scope/会话 ID 绑定的 Binding，由子视图观察该对象，父页不订阅输入发布。UIKit 编辑器的 text/selection、选区插入与 sendComposerDraft 读取同一所有者。会话切换保存/恢复对应草稿，完整 scope 变更清空旧作用域并推进 epoch；旧 Binding 和旧失败恢复不能回写重进的作用域。scope/会话变化重建编辑器身份，避免旧 marked text 进入另一会话。发送策略拒绝按原回调时机恢复发起草稿：空草稿回填；已有且不包含原文时加原文与换行；已有新回复保留；提及按原次序去重并过滤正文。普通网络失败仍遵循原失败气泡/重试合同，未扩大草稿恢复回调条件。

UIKit 原 markedTextRange、清空文本、UTF-16 选区裁剪及编辑生命周期条件保留。实际挂载测试发现，共享对象 Binding 会立即读取 UIKit 程序化 text 替换期间的临时光标；现由 Coordinator 的 isUpdatingView 在同步期间抑制 text/selection 反馈，随后应用原请求选区，用户输入和 marked-text 回调保持原入口。没有修改几何或已读算法。

| 真实替代项 | 替代物与保留边界 |
| --- | --- |
| ChatView 的 cachedMessageRows/source/signatures/renderToken/fingerprint/version 多组 @State、首尾签名快速判断与全量 aggregate token | 唯一 ChatTimelineViewModel 持有消息值快照、行值、版本；稳定 COW 输入 O(1) 复用，新快照检查全部消息值，消除仅看首尾遗漏中间变化的前提。 |
| prepend 专用临时行数组、重复签名数组、body 内 fallback 行重建 | 同一增量更新路径；变化/插入/删除/移动影响新旧顺序的前后相邻行；未读边界新旧位置及相邻行失效；完整五字段 scope、会话、登录代际、权限、人数/回执策略变化重建整表。未变行保留 generation/renderVersion，仅修正索引。 |
| 独立 ChatMessageTimelineItemCache 及其 reset/key | 同一模型按不可变 rows snapshot/version 与未读边界展开原 time/divider/8pt-anchor/message 节点，不加第二套行缓存。read target 和 item 使用同一传入快照，不能偷读更新后的 rows。 |
| 气泡的整条消息深比较入口 | MessageBubble 的时间线入口为 MessageRowModel + 原动作闭包，并实际调用 .equatable()；比较行 generation/version 与选择状态。预览的原值入口保留兼容。 |
| 三处 reader.scrollTo 执行 | ScrollIntent 和同步执行状态统一为一处，仍在既有 ConversationScrollArbiter 接受后执行；原 spring/easeOut/无动画、底部 nil anchor、延时和 generation 取消条件不变。 |
| 子 Composer 的 selection/selectedMentionUsers @State | 共享 Draft.selection/mentions；兼容旧构造调用的局部所有者只在未提供共享所有者时使用，实际 ChatView 路径明确传入共享对象。 |

保留的延后一拍 task 只合并既有消息发布后的刷新/滚动副作用，不另存行数据或 render token。立即删除/撤回刷新仍保持原时机。ChatTranscriptProjectionCache/ChatReplySourceLookup 保留各自的过滤和引用查询职责；附件与语音视图沿既有 observeChatAttachment 和按消息播放订阅独立更新，未增加父页转发。没有 UICollectionView、布局节点合并、8pt 锚点公式、可见性 token/epoch、scene/前后台已读条件或 queued-read 顺序的改动。

| 文件（BlueStoneIM/，行号仅导航） | 本轮主要位置 |
| --- | --- |
| ChatViews.swift | 110–468：共享所有者、旧字段命令访问、模型所有权、scope 生命周期；608 行。 |
| Features/Chat/ChatViewRenderCache.swift、ChatTimelineProjection.swift | 4–198、174–245：唯一增量模型、行值、同快照 item、气泡行入口；198/245 行。 |
| Features/Chat/ChatViewTimeline.swift、MessageBubble.swift | 84–633、63–193：权限失效、行入口/.equatable、真实 DEBUG 计数；693/790 行。 |
| Features/Chat/ChatComposer.swift、ChatComposerActions.swift | 106–387、596–682：子观察、共享编辑器绑定、Draft/token/作用域恢复；703/682 行。 |
| Features/Chat/ChatViewLayout.swift、ChatComposerInputViews.swift | 9–208、81–259：共享绑定/身份、UIKit 同步、发送回调；434/307 行。 |
| Features/Chat/ChatScrollPolicies.swift、ChatScrollMeasurements.swift、ChatViewScrollPosition.swift | 476–506、191–265、362–639：ScrollIntent、执行状态与统一执行；506/436/691 行。 |
| Features/Chat/ChatViewDiagnostics.swift | 70–88：仅 DEBUG、默认关闭的 body/行解析计数和测试捕获；不记录正文。 |
| BlueStoneIMTests/DomainChatTimelineAndHistorySyncTests.swift、DomainChatViewportAndGestureTests.swift | 只在原文件末尾追加本任务用例，原测试字节/断言保留；798/794 行。 |

验证目录 `/private/tmp/im4-ios1-timeline.YLUD1I/`，全部来自本任务私有镜像、DerivedData、依赖副本和私有 iPhone 17 模拟器 `58A8A3FA-36D4-4204-8A87-6ABB85487A1A`。原 BlueStoneIM scheme/target、锁定依赖、Debug arm64、jobs 4、CODE_SIGNING_ALLOWED=NO；MinimumOSVersion=15.0、Bundle ID=app.xltest.com，实际运行 iOS 26.5。

- exact parent 的新鲜基线 `baseline.xcresult`：68 项全过。组合前本分支 `candidate.xcresult`：75 项全过（历史记录，不冒充最终组合）。最终 `combined-final.xcresult`：76 项全过，68 项原结果完全一致，8 项新增全过。
- 新增覆盖中间编辑及时间分隔相邻失效、prepend/删除接缝和未变尾行身份、未读边界两侧、完整五字段 scope 与权限、稳定快照零行解析、作用域/会话草稿恢复及旧 Binding epoch、ScrollIntent 原锚点/动画状态；实际挂载 ChatView/UITextView 验证 marked text、UTF-16 选区替换 @、真实 HTTP 403 策略拒绝后继续输入的旧草稿合并、回复恢复和 A→B→A 编辑器草稿隔离。
- 实际挂载时 DEBUG 计数确认输入操作不增加 ChatView 时间线构建、行解析或 MessageBubble body；并确认同会话编辑器身份保留。这是该固定场景的运行证据，不把模型相等或截图当作全页面/全部输入方式的证明。
- `combined-ui.xcresult` 保留首次挂载失败：发现程序化 text 更新的选区反馈问题；最初抛传输错误的夹具进入原 uncertain 分支，未触发策略拒绝回调。产品集中修正同步适配，夹具改为实际 HTTP 403 后，`combined-ui2.xcresult` 和最终组合均通过，且无 publishing-during-view-update 警告。旧失败未删除或弱化断言。
- `final-snapshot-comparison.log`：本任务基线和最终组合的同名 7 张聊天 PNG 逐像素相等；`final-snapshots/` 保留输出。
- `structural-check.json`：17 个改动 Swift 均 ≤800，最长 798；四布局文件 28 个 some View 构建体全部 ≤150，逐声明计数最长 127（原布局历史段的 116 不作为当前统计）；原测试前缀逐字节保留。`mirror-source-hashes.json` 记录工作区与编译镜像 17 文件字节一致。build/语法、diff、写区及暂存检查通过；未新增源码/测试文件，无 PBX 注册需求。

提交/补丁定位：本隔离分支最终本地 commit 见交付 final；完整本候选补丁 `/private/tmp/im4-ios1-timeline.YLUD1I/timeline-source-candidate.patch`。手工合并按完整功能标识消费，不截取单个 BEGIN/END，不覆盖原 source 的存储 WIP。回退仅由原 owner 在独审后按本组完整差分处理，不自动执行。

未完成/依赖：固定 R2 对最终组合的独立审查仍必需；阶段 3 F1 不在本任务关闭范围。Conversation.messages 仍是本轮值快照输入，没有代理或存储迁移；交付后冻结整个 Chat 写区，由原 source owner 统一对接 3c 显式消息快照（含本次纳入的四布局读取点）后复审。未验证 iOS 15 真机中文键盘、同签名升级、Release、全套 suite 或滚动性能目标，不宣称阶段 4 总体或累计架构改造完成。

`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=unchanged`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`、`REVIEW=REQUIRED_IOS_PENDING`。

## F2 / P2：程序性文本与 UTF-16 权威选区配对（2026-11-10）

标识：`WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110`。这是固定 R2 对 aa97689b 的唯一新增 F2/P2 的后继修正候选，仍须同 R2 定向复审；实施完成不表示 finding 已获 reviewer 关闭。parent `aa97689b21375c4ef708398fe9f458a17a176e52`、parent IOS1 tree `2ba38c843dacf22ed6b4c8bc85002cfc646f41d1`。原 aa 对象保留，未 rebase、amend 或改历史。复用 `/Users/waisky/.codex/worktrees/ios1-timeline-parallel-20261110/IM4`、`codex/ios1-timeline-incremental-20261110`，`BASED_ON_CANONICAL_HEAD=NO`。

- `ComposerState.Draft.prependInputPreservingSelection` 在真正增加恢复前缀时，先裁剪旧输入内的合法范围，再以新增前缀的 UTF-16 长度平移 location；有效 length 与相对编辑位置不变。空当前草稿恢复旧文时落在恢复文本末尾；已有文本/重复恢复未改变正文时不重复平移。inactive 原会话的存稿使用同一值路径，随后切回仍携带配对选区。原 restore 条件、回复/提及合并顺序以及 scope/token/epoch guard 保留。
- 数值越界先裁剪；显式检查选区两端是否位于 UTF-16 低代理码元中间，只对非法边界使用 NSString 组合字符范围修复。Foundation 的 Range(NSRange, in:) 会接受代理对中间的位置，不能单独作为该合法性判断。有效选区不扩大或折叠。
- ChatView 的程序性 input setter 统一调用 `replaceInputMovingCaretToEnd`。因此 ChatViewReply.mention 的原空白赋值、原尾部追加（含空格规则）及发送后清空都同步给出正确落点；重复 @ 未赋值时保持原选区。该 mention 函数逐字节未改，没有改成在选区插入的新业务。UIKit 输入 Binding 与原表情/提及的显式选区替换仍走原入口，不经过这个程序性 setter。
- `ChatComposerInputViews.swift` 与 aa 逐字节一致：isUpdatingView、markedTextRange、选区回写保护及编辑生命周期均未撤销或改写。未修改几何、滚动/已读、Core、Domain、Store、PBX、Package、签名、账号或同 scope 发送授权合同。

修改位置：ChatViews.swift:129/390 的程序性 setter 与仅 DEBUG 的真实 ChatView 捕获；ChatComposerActions.swift:610–643/687–697 的 Draft 配对写入及失败恢复；ChatViewDiagnostics.swift:79/85 的默认 nil 测试捕获/释放。四份既有注册测试文件为 DomainChatTimelineAndHistorySyncTests.swift、DomainChatViewportAndGestureTests.swift、IdentityPresentationTests.swift、IdentityChatPresentationTests.swift。只有本任务新增的模型错误坐标 {3,0} 修正为前置后的 {7,0}，原 68 项对应的测试源码前缀与断言逐字节保留；两份 Identity 原文件也是 aa 字节前缀，仅追加相关用例。全部 7 个改动 Swift ≤800 行，最长 800；没有新增源码或测试文件，无 PBX 注册依赖。

真实验证目录 `/private/tmp/im4-ios1-timeline.YLUD1I/f2/`。继续使用本任务私有镜像/DerivedData/SourcePackages 和私有 iPhone 17 模拟器 `58A8A3FA-36D4-4204-8A87-6ABB85487A1A`，BlueStoneIM 原 scheme/target、锁定依赖、Debug arm64、jobs 4、CODE_SIGNING_ALLOWED=NO；实际 iOS 26.5，最低版本仍 15.0、Bundle ID app.xltest.com。私有镜像 568 个 Swift/工程/依赖锁构建输入在加入回归前核为 aa；未引入 Core3c 或 Wuffs/其他 source WIP，未改私有 Core。

验证增量：

1. `characterization.xcresult`：aa 产品逻辑加本轮回归/DEBUG 挂载入口，4 个目标用例全部复现 F2（40 条断言错误）。包括真实 HTTP 403 失败后光标 {3,0} vs {7,0}、继续输入落错位置、真实外部 @ 光标 {0,0} vs 文本末尾，以及中文/emoji 和非空选区。
2. `candidate.xcresult`：首版修正 8 项中 7 过，非法代理对中间坐标一项失败；完整记录保留。据此改为显式 UTF-16 码元检查，未放宽预期。
3. `candidate-final.xcresult`：同一组 8 项全部通过，0 跳过。含两份既有 Composer 回归、3 项直接相关键盘用例、3 个新 Identity 用例。实际挂载覆盖英文/中文 emoji、0 长度和非空选择、实际 UITextView.selectedRange、插入 X 后的新正文、重复恢复、inactive A 存稿切回、空白/普通/尾空格/已含 @ 的原外部入口，以及非法数值/代理对边界。真实发送→HTTP 403→合并→继续输入通过，原 marked text、程序性选区保护、跨会话/scope 与输入不重建时间线/行/气泡的断言保留且通过；最终无 publishing-during-view-update 警告。

`candidate-final-build.log`、`candidate-source-hashes.json` 记录最终 Debug build 和工作区/编译镜像逐字节绑定；失败构建输入摘要/补丁另留 candidate-boundary-failure-*。本轮只跑上述直接受影响组，没有重跑原 76 项或整套。样式实现未改，七张截图仅复用 aa 的 `/private/tmp/im4-ios1-timeline.YLUD1I/final-snapshot-comparison.log` 与 final-snapshots 既有证据，不宣称 F2 重新截图或像素实测。

完整后继补丁 `/private/tmp/im4-ios1-timeline.YLUD1I/f2/source-candidate.patch`，exact 后继 commit/tree 见本分支交付 final 与 f2/candidate-summary.json。手工消费须同时合并 Draft 恢复、ChatView 程序性入口、测试及标识；只取一个 BEGIN/END 块不能覆盖完整 F2 链。交付后重新冻结整个 Chat 写区，由 root 送同一 R2 对 aa→后继定向复审；不自行 merge、push 或进入 source/main。F1/Core3c、阶段 6 实施与总体性能复核保持其它车道和原状态，不在本项关闭。

限制：没有 iOS 15 真机/真实中文键盘、同签名升级、Release、完整 suite 或性能验收。本次只验证冻结 aa 的独立 Chat 后继，不冒充与 Core3c/Wuffs 的组合验证。回退仍由原 owner 在独审与组合边界按完整差分执行，本任务不自动回退。

`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=unchanged`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`、`REVIEW=REQUIRED_IOS_PENDING`。


## Core 3c/3d + approved Chat/F2 + Wuffs 实际组合候选（2026-11-10）

标识：`WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN/END`、`WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN/END`。本节仅追加；上述布局、Timeline/Composer、F2 和 Wuffs 原完整功能段作为来源记录保留，历史验证不冒充本次组合结果。固定 reviewer 仍为 R2 `01a07610-bbde-71e0-a228-b4762d32b0a1`，F1 正式状态保持 OPEN / REVIEW_REQUIRED。

输入与边界：本地 parent `abe8b7cc9e798195109f30d49127988c9ec29f25`（Core3c），按协调器释放写区组装累计 Chat-only `3fe4cb33d14e125a15d2184aa43f600347542878 → 15c4fd1be9183db7e84bcc95f4dd9b48684f9022`；R2 对 exact15c 的 APPROVE/F2 CLOSED 仅为该 Chat delta。继承已审 `1e6689b006259c58aab0aadff3d9ea5e03bb8c4f` 的 WXTGIFFallback 静态 target/PBX 差分，保留 Core 两个 App 和一个 Test 注册；Wuffs 的 canonical/main 整合已由原 Gate 完成，不在此重做。`BASED_ON_CANONICAL_HEAD=NO`，冻结时本地 canonical/main 为 1e668。候选 exact commit/tree 记录在 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/phase3d/candidate-summary.json`，不得以这些上游 APPROVE 代替本次整体独审。

3d 未读维护：唯一 `ConversationMemoryFrame.alertingUnreadTotal` 保持在原权威 Frame 内。贡献仍完全等于原规则：未静音、按需排除当前会话、`max(0, unread)`；System、不可用会话和重复物理 ID 不新增排除。点改/已知少量行以物理索引收集旧/新贡献，先减全部旧值再加新值；频繁远端合并、插入/删除、已读、反应/详情/提醒/编辑/置顶与跨会话审批使用相应 delta。纯消息/排序/详情保持总值；全量载入、恢复、去重和范围重建继续用原总和算法。此处只减少未读标量维护工作，不宣称整次批处理或 UI 全链均为 O(k)。

回调期间准备的 structural hint 若不再对应当前 revision，仅回退到原完整未读计算；绝不按 revision 丢弃 mutation、ACK 或 message-only 提交。小批仍保留原完整窗口/顺序/重复 ID 行为；未加按 ID 的第二份未读缓存。DEBUG 在实际发布前用原总和算法断言同值。完整 scope/reset 清空随 Frame 发布，同 scope 凭据轮换保留窗口和总值；F1 串行命令/通知队列保持原边界。

实际 Chat 接线：所有消息消费者显式读取 `ConversationMessageSnapshot`；`Conversation` 列表保持纯 metadata。每会话消息对象按完整 scope + binding UUID + 会话 ID 隔离，无独立消息副本/写入口；metadata 与该窗口消息订阅从同一已安装 Frame 读取，结果去重。Chat Timeline 仅接收本会话 `messageChanges`，使用同一 commit 的 previous/current 决定原 viewport 副作用。绑定改变只淘汰旧 observer，保留 metadata 回调已创建的新 observer。完整保留 15c 的 Draft UTF-16 选区、programmatic setter、所有 F2 原断言和三个新 Identity 测试；DEBUG `chatBody` 与按会话 bubble 捕获均默认关闭并在 reset 释放。保留原 8pt、scope/epoch、queued read、滚动和权限规则。

主要文件：`Domain/ConversationModels.swift`、`Stores/ScopedMessageMemoryStore.swift`、`ConversationStore.swift` 及 Lifecycle/ReadState/LocalMessages/MessageExtras/RemoteMerge；ChatViews、ChatViewTimeline、显式消息快照消费者和原四测试；`MessageSidecarCommitTests.swift` 新增八项 3d 用例、`ScopedMessageMemoryTests.swift` 新增三项按窗口订阅用例。未新增 Swift 文件或注册。批准的 Chat15c 替代旧 render-cache 状态/签名/版本路径；旧 `WDT_CHAT_DELETE_REFRESH_20261021` 的删除刷新职责仍由原立即 refresh 调用进入唯一 Timeline 模型，本次不恢复已被批准替代的缓存状态。

本次实际组合验证：私有镜像 `/private/tmp/im4-ios1-v5-phase0.CZP8fN/proper-layout/code/apps/ios-chat-1`；独立模拟器 `2928E261-09B5-434A-AFC4-405E4B351DC8`，iOS26.5/arm64、SDK27、原 scheme/target、锁定依赖、Debug、jobs4、CODE_SIGNING_ALLOWED=NO，Bundle ID `app.xltest.com` / MinOS15.0。`phase3d/actual-mirror-build-inputs.json` 将实际源码与本次编译输入逐文件绑定，Swift 文件集合 569 对 569，无额外私有源码；未消费其它 owner 原型。

- `phase3d/build.log` build-for-testing 成功；语法与 diff 检查通过，全部改动 Swift ≤800 行（最长 800）。
- `phase3d/combined.xcresult`、`combined-results.json`：51/51 定向用例通过、0 跳过；实际枚举 2139 → 2161，新增 Core 后的八项 Chat、三项 F2、三项窗口订阅及八项未读用例，无删除。覆盖真实 F1 重入/reset、scope/凭据轮换、点改/小批与重复物理行/负值/System/静音、旧 hint 回退、Tab/系统 badge、410/restart/末页与 reentrant message-only 保护、离线重启、实际 ChatView/UITextView 的其他窗口隔离/当前反应气泡、marked text/F2 下一字符、原窗口与已读副作用，以及两项真实 GIF 解码/取消恢复。
- `phase3d/snapshots.json`：本次实际组合输出的同名七张聊天 PNG 与 aa 原冻结 combined-final 逐像素相等；本次没有重跑 aa/F2 基线，未扩大为全部 UI 等价证明。
- `phase3d/debug-static-link-check.json`：WXT 归档仅一个 GIFFallbackDecoder.o；App 的三个 wrapper 定义各一次，无新增 GIF 动态库；C/H/Swift wrapper/vendor/license 保持 approved Wuffs 原字节。独立 Release device 制品检查另行记录，不用模拟器替代。

八项新 3d 回归包括 240 次混合实际 mutation 与旧总和逐步核对、重入发布顺序、scope/reset/凭据轮换、两行同步反应、小批先减后加避免合法最终值的中间溢出、结构回调旧 hint 和每个 System 物理重复行。扩展原 mounted Composer 回归在原计数基线前验证其他窗口零 timeline/row/bubble 工作、当前反应到真实气泡、editor 实例保持；原 F2 数值/正文断言未弱化。

独审/回退：完整累计 Core3c/F1、3d 与本次 UI 适配交同一 R2；此处不自行 APPROVE 或关闭 F1。回退由原 owner 按完整候选差分经独审处理，不整文件覆盖、不自动回滚。未执行 main merge/push、签名、真实设备安装或发布；没有 iOS15 真机加载/真实输入法、同签名升级或性能验收。阶段4–6总体与后台专项没有因此完成。

`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=unchanged`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`、`REVIEW=REQUIRED_IOS_PENDING`、`F1=OPEN_PENDING_R2`。


## F3 / P2：批量转发活动来源使用真实作用域消息流（2026-11-10）

标识：`WDT_IOS1_BATCH_FORWARD_LIVE_SOURCE_20261110`。以 exact `2162ea5c6a788cad60fdf69df62d05c68a1a864d` 为 parent；原 Git 对象、phase3d/proper-layout/Release-device 及 R2 审查输入保留只读。R2 对2162正式结论为 NEEDS_FIX，仅 F3/P2；F1 与 F2 完整链已在2162关闭。本节为原 source 最小后继，F3 待同 R2 定向复审，不自行批准，不混入阶段5 Core/DesignSystem 私有分包。

修复：ChatViewLayout 的列表 metadata 订阅只调用 `refreshBatchForwardTargets`，按原排序/候选规则更新目标，不再把伪造空消息当来源页。新增当前 conversation ID 的既有 `conversationMessageUpdates` 订阅，在活动选择期间调用 `refreshBatchForwardSource`；完整五字段 scope/hash、登录 binding UUID 和 switchToLatest 隔离沿已审原消息流。来源 helper 校验来源 ID/当前 draft scope，只 ingest 实际窗口并更新已改变的草稿；保留旧页选中来源，不因窗口未含旧页而删选中项。目标 helper 的空消息 operation values 仅用于既有目标 metadata 投影。未恢复 Conversation.messages、全局融合 Published 或订阅所有会话消息。

原 onAppear/onForward 的真实完整快照刷新、选择入口、BatchForwardState 资格/排序/选中保留/幂等、提交方法与 HTTP 合同均不改。新路径在目标 sheet 打开后仍持续刷新来源缓存，实际 submit 的原资格检查据此读取新状态。AppState+BatchForwarding.swift、ChatViewLayout.swift 为产品修复；MessageBubble.swift/ChatForwardViews.swift/ChatViewDiagnostics.swift 只增加 DEBUG 默认 nil 的真实气泡选择回调与实际 onForward bar 捕获，reset 全部释放。原四个 F2 文件未改；既有 XCTest 断言保留，仅在 ScopedMessageMemoryTests.swift 追加两个挂载用例及相关夹具/SwiftUI import，无新文件/注册/PBX/依赖/资源/锁/签名/版本变更。

新验证目录 `/private/tmp/im4-ios1-f3.18r_yfk4`，与旧2162目录完全分离。`source/` 是2162产品字节加 DEBUG 设施/新回归；`candidate/` 是实际后继编译镜像。各自独立 DerivedData、SourcePackages 副本和自有模拟器；原 scheme/target、Debug arm64、jobs4、CODE_SIGNING_ALLOWED=NO、MinOS15.0。characterization/candidate 输入 hash、命令、log、xcresult、enumeration/results 分开记录。

- `characterization.xcresult`：2162 原产品上两个实际挂载回归均失败，四条核心断言复现 B 已显示但选择找不到、sheet 中撤回非末条消息且 metadata 零发布后缓存仍 sent，并实际发出不应发出的 forward-batch 请求。首次记录 `characterization-first*` 另保留；其中另一窗口隔离夹具误用会更新摘要的编辑，后改为纯消息进度更新，不弱化断言；最终 characterization 保持两项同一 F3 复现。
- `candidate.xcresult`、`candidate-results.json`：19/19 直接相关用例通过、0跳过；2161→2163，仅新增两项，无删除。新用例通过实际 mounted MessageBubble.onSelectionTap 和 BatchForwardSelectionBar.onForward；确认 sheet 真实呈现后仅消息撤回更新缓存、保留选中、原 submit 阻止 HTTP，恢复来源资格后原 submit 恰好发出一次请求且 body/idempotency key 正确；同时验证另一窗口 message-only 更新不刷新本来源。其余17项仅批量转发资格/排序/幂等/目标候选/退出/作用域取消及实际租户策略 bar。
- `candidate-build.log`：必要 Debug build-for-testing 通过，实际源码与编译输入逐文件绑定。六个改动 Swift 均≤800，最长791。原测试源码前缀及断言保留；全 App 当前已有测试编译成功，未运行整套。

复用范围：2162 已审 F1/F2/未读/Wuffs、原51项/七张PNG与原Release-device证据仅按其既有范围复用，没有在此后继全量重跑或重新截图/device build；device 制品身份仍严格归2162，不称本后继完整 Release/device 制品。未增加 availability/工程依赖，不借修复加入分包。iOS15 真机/真实输入法、同签名升级和性能仍未验收。

exact 后继 commit/parent/tree、完整最小补丁、源码 hash、报告和回退记录在 `/private/tmp/im4-ios1-f3.18r_yfk4/candidate-summary.json`。仅供 root 转同 R2 针对 F3/受影响链复审，原 F1/F2 不重复开审。回退仅由原 owner 按这组完整后继差分经独审处理，保留2162对象、当前 main 的 Wuffs 和无关任务/数据；不自动回滚、整文件覆盖或清空缓存/数据库。

`BASED_ON_CANONICAL_HEAD=NO`、`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=unchanged`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`、`REVIEW=REQUIRED_R2_F3_REVIEW`。


## 阶段5：IM4Core 基础模块实际源码候选（2026-11-10）

标识：`WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_BEGIN/END`。本节属于实际源码，不是仅私有原型。root于本轮释放Core/必要App桥接/Package.swift/PBX/既有测试唯一写权；从已审canonical main `9ae341374c75f4dc206ba697ef063522ef918a3e` 正常创建 `codex/ios1-core-module-20261110`，基线IOS1 tree `b54a7038bdab2184e819b3b0eebeabf634699d3e`。原 `codex/ios1-v5-refactor` / beaade及所有phase3d/F3/prototype/R2证据保留；未merge旧整仓分支、reset/rebase/force、覆盖用户/非IOS材料。基线F1/F2/F3均已由原R2关闭，作为前置复用；本Core实际候选待同R2独审，不自批、不进入main。

从冻结原型 `/private/tmp/im4-ios1-core-module.zv1rmx_w` 按语义迁移；原补丁SHA256 `de983e6fa423857885b21db6aa2cf49a6864e23d0d0e33eda3fb0880ba7de79b`，其输入/制品继续只读。Core两个实现、Package和App桥接与原型逐字节一致；PBX先核基线再check/apply仅3个对象及3处挂接，不整文件覆盖。实际新base保留F3真实消息订阅及全部其它canonical内容；未带QmCzRd DesignSystem/私有Chat、媒体、导航或phase6。

`Package.swift` 为应用模块化源码：Swift tools6.1/语言6/iOS15，标准Sources/IM4Core target、静态IM4Core library，仅Apple Foundation依赖。新增Core实现HTTPTransport.swift（约5–96行）和JSONWireCodec.swift（约4–45行）：HTTPTransportResult、header大小写/空白规范化及responseURL fallback、原Sendable HTTPTransport/默认实现与别名、WireCodec/JSONWireCodec/原错误集合。App同名文件以明确类型别名真实消费，原实现只在Core编译；IMAPIClient请求/响应、URLSessionHTTPTransport及App field mapping/encryption实现真实调用Core。public仅供跨模块构造/读取/协议需求，JSONWireCodec增加必要public初始化器。

AppState/Core AppSupport glue、Store/业务Domain/路由装配、认证/租户/登录围栏、SQLite/GRDB/持久化、缓存/队列、UI及URLSession/重定向执行均留App。未增加service locator、权限层、nonisolated/uncheckedSendable/unsafeFlags。原HTTPOriginRedirectDelegate的既有标记仍在原App实现，未改。数据编码/哈希/key/完整scope/同scope换票/ACK/顺序/失败恢复合同保持。Wuffs一次Sources/静态link/targetdep、3c/3d/15c/F3及所有原Source/Test注册、资源、remote lock、Bundle/entitlements/Release/Debug增量默认均保留。

NSError完整边界：Core WireCodecError通过Foundation CustomNSError保留旧 `BlueStoneIM.WireCodecError`、0/1/2 code与空userInfo，仍不新增LocalizedError conformance。实际测试检查Error/NSError两侧localizedDescription与原Foundation桥接等价；真实Core非法JSON抛错进入原AppState.handleRemoteError、BackendUserMessageSanitizer及IMAPIClient日志脱敏链，与旧错误呈现一致。未改错误正文/业务逻辑或只替名字掩盖桥接变化。另以未移动LocalizedError控制检验errorDescription/桥接描述、原脱敏与toast不泄露测试敏感占位值。

新证据目录 `/private/tmp/im4-ios1-core-actual.7c3kaxn2`；实际worktree→新私有source逐文件绑定，独立SourcePackages副本、Debug/Release DerivedData与自有模拟器；原scheme/target、jobs≤4、CODE_SIGNING_ALLOWED=NO。Debug build-for-testing/全部现有XCTest与Core实际编译通过，Release generic iOS arm64无签名build通过。Xcode将静态SwiftPM product输出为IM4Core.o：Core两源各一次，App一次对象链接，XCTest无重复Core nominal定义；实际Debug simulator及Release device App/Core Mach-O平台/arm64/minOS15均核对，WXT三个C入口各一次。结果在artifact-evidence.json，不以plist/旧原型制品替代实际新候选。

定向验证：首次32项中30过、两项失败；一项为新增LocalizedError夹具错误地假设描述必填入NSError.userInfo（该运行环境采用惰性描述）。保持生产代码/原断言不变，修正为公开errorDescription与bridged localizedDescription等价后，必要Debug重编译及该新case单独复测1/1通过。最终32个distinct case中31个通过、1个原失败，不冒称一次32全绿；原32结果及修正/单项复测均保留。唯一既有失败仍为HTTPTransportUploadFailureUsesInjectedTransportStatusAndBody第453行要求storage down原文，冻结2162对照已复现；旧断言/原输出不改、不顺手修隐私逻辑。方法枚举2163→2165，仅新增两个Core合同方法，无删除；旧WireCodecTests断言前缀原字节保留。

Release只编译App/Core而不消费上述XCTest夹具；其原输入另存release-original-inputs.json，生产源码/工程/资源/锁与最终候选逐字节相同。夹具修正后Debug重新编译并绑定最终XCTest。first-focused-source/first-focused.xcresult和contract-retest分别保存，不混版本。旧F1/F2/F3及51/19/7PNG/device各按原版本复用，没有重复全套、重截图、增量计时或冒称旧device为新候选；本次新Release device事实仅归本次实际App/Core编译，不等于签名archive/设备执行、iOS15真机输入法、同签名升级或性能。

完整actual commit/parent/tree、精确8路径、源码/制品hash/命令/最小补丁、既有失败及复用边界见本目录candidate-summary.json。后续由root送同R2，再原R7唯一整合；共享manifest/PBX后继须保其它目标，不能全树覆盖。回退按本组完整Core差分恢复App原实现/撤别名及Core独占target/product/link/source，保Wuffs/F3/其它package目标及用户数据；不自动回滚、清缓存/数据库、main/push/签名/真机安装/CI/发布/云/生产。

`BASED_ON_CANONICAL_HEAD=YES_AT_BASE_9ae3413`、`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=unchanged`、`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`、`REVIEW=REQUIRED_SAME_R2`。

<!-- WDT_IOS1_DESIGNSYSTEM_ACTUAL_ASSEMBLY_20261110_BEGIN -->
### WDT_IOS1_DESIGNSYSTEM_ACTUAL_ASSEMBLY_20261110

Actual source branch: codex/ios1-designsystem-module-20261110. At creation main was 9ae341374c75f4dc206ba697ef063522ef918a3e / IOS tree b54a7038bdab2184e819b3b0eebeabf634699d3e; approved Core was pending integration. Root explicitly released this source lease, based on approved bdb701753173899638c7a8789dab1c951ecd98a2 / IOS tree 349739946fce625c072f9cb1cfe862c9b34d6b78. BASED_ON_APPROVED_CORE=bdb701753173899638c7a8789dab1c951ecd98a2; BASED_ON_CANONICAL_HEAD=NO at creation. No main write.

Reuse fixed R2 APPROVE_FOR_SOURCE_ASSEMBLY reports IOS1-DESIGNSYSTEM-PROTOTYPE-REVIEW-SPYXgS-20261110.md and IOS1-DESIGNSYSTEM-COMPONENTS-REVIEW-QmCzRd-20261110.md. All 14 Swift files match Qm source hashes. Existing consumers in bdb match their reviewed 1e input; semantic hunks applied, with no whole old Package/PBX/consumer overwrite. Original base/components WDT blocks retained.

- Package.swift preserves the approved static IM4Core product, target and two Foundation sources. Adds static IM4DesignSystem with nine explicit sources; tools6.1/language6/min15 and resource/dependency/unsafe boundaries retained.
- PBX reuses the existing Core local package, adds DS product/link, App bridge and component test in existing targets: six new objects and six changed existing objects. All configurations, Core/Wuffs/external dependencies, resources/copy/scripts remain unchanged. Five base memberships removed from App only; original file objects retained. Nine DS implementations belong to the package only, with three App wrappers retained once.
- App retains Domain/certification observation/avatar authorization/cache/thumbnail budget, original Coordinator, ordered GIF/data/file/provider staging and cleanup. Package owns pure UI/value/system picker configuration and synchronous delegate binding only.
- Approved Core HTTPTransport/WireCodec/App aliases, Sources/IM4Core, WireCodecTests, Core3c/F1-F3/Chat/Wuffs remain unchanged. No Nav/Bubble/F4/Domain live WIP or phase6 is included.

Actual reviewed file ranges:
- `BlueStoneIM/DesignSystem.swift:1-74`
- `BlueStoneIM/DesignSystem/ApprovalPresentationViews.swift:1-197`
- `BlueStoneIM/DesignSystem/AuthBackgroundViews.swift:1-174`
- `BlueStoneIM/DesignSystem/AvatarPresentationViews.swift:1-343`
- `BlueStoneIM/DesignSystem/AvatarViews.swift:1-540`
- `BlueStoneIM/DesignSystem/CommonControlViews.swift:1-547`
- `BlueStoneIM/DesignSystem/DesignSystemModuleExports.swift:1-120`
- `BlueStoneIM/DesignSystem/GroupInviteApprovalCard.swift:1-71`
- `BlueStoneIM/DesignSystem/NavigationGestureInstallers.swift:1-339`
- `BlueStoneIM/DesignSystem/PhotoLibraryPickerCompat.swift:1-222`
- `BlueStoneIM/DesignSystem/PhotoLibraryPresentation.swift:1-49`
- `BlueStoneIM/DesignSystem/SwiftUICompatibility.swift:1-343`
- `BlueStoneIM/DesignSystemModuleBridge.swift:1-133`
- `BlueStoneIMTests/DesignSystemComponentBoundaryTests.swift:1-89`
- Package.swift and project.pbxproj: shared manifest and six-object DS wiring; this index appends this block only.

Exact commit/parent/tree/patch hash, input manifests, actual compiler lists/linkage/min15 and focused results are in /private/tmp/im4-ios1-designsystem-actual.4ah3ndkq/candidate-summary.json. Prior 24 cases/7 PNGs keep their original frozen provenance. Original photo protection nil assertion, independent Foundation-control skip and native root onAppear timeout remain recorded; no all-green/hardware-protection claim.

Adoption: fixed R2 reviews actual new connections, reusing approved DS content and Core; original R7 integrates Core then DS serially. Rollback reverses only this complete DS delta while preserving Core/Wuffs/other targets/resources/locks/data and unrelated code. No automatic reset/rebase/tree overwrite/cache/database removal. Old 1e/Wuffs/2061 refs and all private artifacts remain.

NEW_DEPLOY_SURFACE=0; JENKINS_CHANGE=0; SECRET_PLACEMENT=unchanged; PROD_MUTATION=false; AUTO_ROLLBACK=false; REVIEW=REQUIRED_ACTUAL_DS_CONNECTION_REVIEW. No push/sign/install/CI/deploy/cloud/production action or claim of full DesignSystem/Domain/phase5/phase6 completion.

Actual validation result:
- Debug Core+DS+App and all existing/new XCTest compile PASS; Release Core+DS+App generic iOS arm64 unsigned build PASS. Original Debug incremental/Onone and Release O/WMO are retained. SDK27; Debug runtime only private iOS26.5 simulator; minimum15 in both App/Core/DS Mach-O products. Release XCTest is not claimed.
- Final focused xcresult: 9 total, 6 pass / 2 fail / 1 skip. Failures remain the original photo protectionKey nil assertion at line60 and native returned-to-root onAppear timeout at line83; only independent Foundation capability control skips. The two Core error contracts pass. No assertion or business behavior changed.
- Initial run executed eight cases because one Core selector class was wrong. Its cases completed but result collection did not finalize for over five minutes; only that own xcodebuild was stopped and partial evidence retained. Final run corrected the class and used official collect-test-diagnostics=never for verbose system diagnostics only; structured failures remain. No clean9/9 or physical data-protection claim.
- Debug/Release source lists: Core2 and DS9 only in their modules; original three App wrappers and bridge once. Representative Core/DS nominal descriptors each1, corresponding old App descriptors0; Wuffs Inspect/Decode/Free each1, no Core/DS dylib, App default.metallib retained.
- Compiled Swift/manifest/PBX/resource bytes match final source; only this documentation is finalized after builds. All old tests and unrelated source/config/resource/lock files remain bdb-identical. Exact Git and source manifests are in the actual evidence directory.

<!-- WDT_IOS1_DESIGNSYSTEM_ACTUAL_ASSEMBLY_20261110_END -->

<!-- WDT_IOS1_DOMAIN_ACTUAL_ASSEMBLY_20261110_BEGIN -->
### WDT_IOS1_DOMAIN_ACTUAL_ASSEMBLY_20261110

Actual Domain source candidate on canonical8f67510a981b4a6be7706b97da7701f79ab16ebb / IOS tree45e67440197d4117bde1b7782c6a284f1022c202. BASED_ON_CANONICAL_HEAD=YES at creation. Normal branch codex/ios1-domain-module-20261110 preserves original7387/bdb/1e/2061 refs and user material. Root explicitly released actual Domain source/shared-engineering write scope; fixed R2 will review ALL Domain content plus current Core/DS connections once after this candidate. The old private packet suggestion to review private content first is superseded by that instruction; no self-approval/main write.

Content comes from frozen resumed9ae-based Domain packet df368037b95d08129869927a4a841de5ef89929f01b3b0053af0d110d7a539e6. Original affected inputs match current canonical bytes before semantic hunks. Ten Foundation files/40 values and App aliases/adapters/tests retain frozen content exactly; Core/DS aliases, code/resources/pins/configuration and all other original tests are preserved. Original WDT prototype markers remain complete; this actual marker covers shared manifest/PBX/index wiring.

- Shared Package.swift preserves Core2/DS9 and original static products/tools6.1/Swift6/min15. Adds static IM4Domain with10 explicit sources and no dependency/resource/unsafe flag. DS exclude list adds only the two App bridge/adapter files; all nine DS sources remain unchanged.
- PBX reuses one local package ref. Adds Domain product/link and two App/one existing-target test source registrations (eight objects); removes only four physically deleted moved-source file refs/memberships (eight objects). Original Core/DS/Wuffs/native targets, dependencies, resources/metal/copy/scripts/configurations/build flags/signing and lock remain intact.
- Pure messages/metadata/detached snapshot/contact/group/support values move once. App owns cache getters, preview, Remote DTO/wire/RTC parsing, authentication/full-scope/ACK/permissions and runtime services. No AppState/Store/GRDB/UI/CoreUI dependency in Domain, no service locator/AppState alias or unsafe transfer.
- AttachmentUploadFailure is Codable/Hashable/Sendable value metadata, not Error. Its sanitizing keys/filters remain Domain; original operational Error classification/HTTP/OSS/diagnostic locking remains App. GroupDescriptionInputError/GroupMuteModeValidationError remain App, approved Core NSError compatibility stays unchanged. Static reflection/archive scan and exact call chains are recorded in data-and-error-compatibility.json.
- Both Domain-only search helpers stay private; public initializer/field/raw/Codable/body/default/ID/value semantics retain the frozen content. Checked Sendable on FriendRequest/GroupInfo has no unsafe/unchecked wrapper.

Affected actual Swift ranges:
- `BlueStoneIM/BatchForwardModels.swift:1-446`
- `BlueStoneIM/Domain/ChatMessageModels.swift`: deleted original moved implementation; new module mapping retained.
- `BlueStoneIM/Domain/ContactModels.swift`: deleted original moved implementation; new module mapping retained.
- `BlueStoneIM/Domain/ConversationMessageSnapshot.swift`: deleted original moved implementation; new module mapping retained.
- `BlueStoneIM/Domain/ConversationModels.swift:1-22`
- `BlueStoneIM/Domain/FileModels.swift:1-304`
- `BlueStoneIM/Domain/GroupModels.swift:1-62`
- `BlueStoneIM/Domain/StickerMessageModels.swift`: deleted original moved implementation; new module mapping retained.
- `BlueStoneIM/DomainAppAdapters.swift:1-28`
- `BlueStoneIM/DomainModuleBridge.swift:1-62`
- `BlueStoneIM/GroupMuteMode.swift:1-448`
- `BlueStoneIM/RTCCallRecordMessage.swift:1-525`
- `BlueStoneIMTests/DomainModuleContractTests.swift:1-172`
- `Sources/IM4Domain/AttachmentUploadFailure.swift:1-80`
- `Sources/IM4Domain/BatchForwardSenderProvenance.swift:1-10`
- `Sources/IM4Domain/ChatMessageModels.swift:1-597`
- `Sources/IM4Domain/ContactModels.swift:1-496`
- `Sources/IM4Domain/ConversationMessageSnapshot.swift:1-106`
- `Sources/IM4Domain/ConversationModels.swift:1-389`
- `Sources/IM4Domain/GroupModels.swift:1-617`
- `Sources/IM4Domain/GroupMuteModeValue.swift:1-9`
- `Sources/IM4Domain/RTCCallRecordValues.swift:1-73`
- `Sources/IM4Domain/StickerMessageModels.swift:1-287`
- Package.swift/project.pbxproj: only the actual shared wiring described above; this index adds this section.

Validation and immutable commit/parent/repo/IOS tree/patch/source+mode/input/artifact/public API/consumer maps are in /private/tmp/im4-ios1-domain-actual.5ubtuiv8/candidate-summary.json. Initial focused23:22pass/1fail/0skip, including all seven boundaries/search passing. Cancelled-user toast line449 nil failure reproduced in a new exact8f single-case baseline run; retain assertion/source and both results, not a DS observation or all-green claim. No UI/performance/old suite repetitions or testability configuration workaround.

Adoption: original fixed R2 complete Domain content+Core/DS connection review, then root/original R7 local serial incremental integration. Rollback only this whole Domain delta, preserving Core/DS/Chat/Wuffs/other targets/resources/locks/data; no automatic reset/rebase/tree overwrite/data migration/cache removal. Remaining mixed Domain/Data/Stores/Features and full phase4/5/6 are not complete.

NEW_DEPLOY_SURFACE=0; JENKINS_CHANGE=0; SECRET_PLACEMENT=unchanged; PROD_MUTATION=false; AUTO_ROLLBACK=false; REVIEW=REQUIRED_IOS_PENDING. No main/push/sign/physical install/CI/cloud/production action.

Actual final validation:
- Debug Core+DS+Domain+App/all original/new XCTest compile PASS. Normal unsigned generic iOS arm64 Release App/Core/DS/Domain compile/link PASS, original Release O/WMO and Debug Onone/incremental retained; no product testability/optimization/signing change. SDK27; App and all three static objects min15 in Debug simulator and Release IOS Mach-O. Release is build-only, no real device action.
- Actual focused23 cases:22pass/1fail/0skip. All seven value/serialization/scope/search boundary cases pass; directly affected cache/upload redaction/RTC/remote mapping/unread/peer/GroupInfo cases pass. The original cancelled-user toast assertion at DomainRTCTerminalAndMainShellTests:449 remains nil vs expected text; a new exact canonical8f baseline single-case run reproduces the identical failure. Test/call/Toast source bodies are byte-identical; no assertion, permission gate or behavior changed, no all-green/root-cause claim.
- Debug/Release compiler lists are Core2/DS9/Domain10 exclusively plus App aliases/adapters; each static object links once.40 Domain nominal descriptors each1, corresponding old App descriptors0; App Error descriptors retained. Core/DS representative definitions single, WXT Inspect/Decode/Free each1, no added dylib and App default.metallib retained.
- Actual compiler public API654 symbols equals the frozen Domain content; both internal search helpers absent. All other source/config/pin/resource/original tests equal canonical input. Existing file executable modes preserved. Gitarchive group-write permission defaults are not tracked mode changes.
- Build/test compiled bytes bind to final actual source; only this index metadata is finalized afterward. Full actual source/mode/patch/artifact/public API/consumer/compatibility/remaining scope and both failure xcresults are in the actual candidate evidence directory. No old full suite/51/76/F1-F3/24/7PNG/hardware/protection/performance rerun or acceptance claim. Original private sim Release/testability failure/interruption remain separate frozen provenance.

<!-- WDT_IOS1_DOMAIN_ACTUAL_ASSEMBLY_20261110_END -->


## WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110（私有下一批，未提交/未整合）

- 基线 exact 15c4fd1be9183db7e84bcc95f4dd9b48684f9022。本批只在 /private/tmp/im4-ios1-chat-decoupling.5bvtfb87/source；冻结工作区、ref、Core 组合现场、实际 PBX/测试不写。
- Features/Chat/MessageBubble.swift：MessageBubbleContent + MessageBubblePresentation 值输入、类型化内容槽及明确动作，保持原 UI/手势/回执文案/布局值。群角色纯匹配留在 Feature。DesignSystem 的认证 source 局部观察保持。
- App/ChatMessageBubbleAssembly.swift：保留原 MessageBubble/row 初始器消费入口，App 负责 AppState/Store 查询、Group/Receipt 订阅、快照及动作组装。Equatable 位于组装之后，包含 scope/session/epoch/authority session/policy 与展示字段。
- App/ChatBubbleMetadataAssembly.swift 与 Features/Chat/ChatBubbleMetadataViews.swift：名片解析与 RTC 对端查询留 App，名片/徽标保留纯展示。
- App 局部 ChatBubbleSessionBinding 订阅现有 interaction activeScope，独立动作代际覆盖 logout-login/tenant/A-B-A；epoch/authority session 覆盖同 scope 重新认证。旧保留闭包不借新 scope 派发。无新运行队列，不改 Core 消息代际/ACK/网络/持久化。
- ChatTimelineProjection.swift 的兼容 row 初始器迁 App；ChatViewTimeline.swift 将旧行外层 equatable 下移到纯展示。
- 私有 PBX 仅注册两个 App 源与两个新增测试；工程身份/target/scheme/依赖/floor 不改。不能直接覆盖 Core 的实际 PBX。
- 新测试 ChatBubbleBoundaryTests.swift：真实挂载后的四作用域转移保留动作与回执策略快照；ChatBubbleVisualBoundaryTests.swift：六类消息的明暗模式矩阵。
- 私有 IdentityChatPresentationTests.swift 原 sender metadata 测试仅更新新 App 查询位置与认证注入引用匹配；原 XCTest 断言与顺序保留。实际冻结测试不写，其余140原测试文件字节不变。
- 验证：自有 iOS26.5 iPhone17 simulator，Debug build-for-testing、11/11 focused；exact15c 产品源码对照独立构建，2/2新增消息截图逐像素相同。原 F2/IME/选区/失败继续输入/时间线隔离及群昵称/目录/回复刷新定向通过；不重跑旧76全量。所有 Swift ≤800。
- 残余：回复引用、媒体/GIF/语音/thumbnail 子链及其余 Chat 入口仍含 AppState；局部观察/缓存预算原字节保留。本批非全阶段4、非物理模块就绪，ChatViewTimeline 到 App 组装的注入/路由边界仍需后批完成。
- iOS15 只读审计独立归档 /private/tmp/im4-ios1-timeline.YLUD1I/ios15-compatibility-audit-20261110.md；本批仅声明最低版本15.0。device完整App/GRDB/WXT、真实iOS15/IME、同签名升级、真实推送和性能未验证。
- 补丁/证据：/private/tmp/im4-ios1-chat-decoupling.5bvtfb87/private-source-candidate.patch、candidate-summary.json、dependency-classification.md、candidate-ready.xcresult、baseline.xcresult、snapshot-comparison.log。
- 回退：丢弃本私有候选即可，不触动冻结15c。Core完成3c+3d+15c之后由原owner迁移并复核，固定R2独审后才可整合；不自行提交/main/push/签名/安装真机/发布。
- NEW_DEPLOY_SURFACE=0；JENKINS_CHANGE=0；SECRET_PLACEMENT=unchanged；PROD_MUTATION=false；AUTO_ROLLBACK=false；REVIEW=REQUIRED_IOS_PENDING。


## WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110（第二批私有候选，待独审）

- 仅新副本 /private/tmp/im4-ios1-reply-media.vm6tfc3_/source；输入首批5bvtfb87补丁 SHA256 22d7097d42f4d9e5b07bf8cabe3d8a0c64089137ca3b8a6f23683db77f248352，原首批所有源码/补丁/证据及实际15c保持冻结。
- ReplyQuoteContent/ReplyQuotePresentation：引用渲染纯值输入。原source查询、sender备注、贴纸URL、fallback/不可见/策略在App/ChatReplyQuoteAssembly.swift，保留TranscriptReplyQuote/ReplyQuoteBlock真实入口和原lookup首次匹配、会话级source输入，未加全局消息观察。
- StickerMessageContent/AttachmentGIFContent/VoiceMessageContent：纯展示值与明确动作；App/ChatMediaBubbleAssembly.swift承担原Store投影、局部订阅、解析/缓存/原URL刷新、播放/下载/取消/重试/清理调用。保留原task ID、尺寸/可见性/player、消息ID观察与网络参数。
- 语音复用首批ChatBubbleSessionBinding，不另建代际权威；父组装只注入已有binding，独立挂载复用同类型。只拦退休scope/login，不追加authority fence；正常换票/同scope重认证沿原runtime合同。
- FileBubbleContent完整类型、thumbnail/load gate/预算、preview/文件保护/资源服务、Composer/F2/IME、scroll/8pt/ACK与Core运行源码字节保持，未混修F3。只读2162ea5c6a788cad60fdf69df62d05c68a1a864d的模型接口。
- 私有PBX仅新增两App源/两新测试；两个原源码契约测试只扩展App源码读取路径，XCTAssert行保持。首批两新测试/一契约迁移与F2四测试字节继续可追踪不改。
- Debug/锁定依赖/原scheme/target/jobs4/签名NO构建通过；新增5项均通过，相关focused共13/14，通过真实会话/source/目录/角色/策略/message-only、语音播放/下载观察/取消/清理、正常换票/重认证与退休scope、GIF原图选择及贴纸HTTP/本地解析入口。
- focused唯一失败为原thumbnail顺序源码断言。另行对照两条既有源码smoke：首批与候选同样2项失败/7断言，精确失败谓词相同（含6条原AppState源码定位），未删/改断言；非本批新增失败，记录完整日志。
- 首批源码独立对照，仅加同一新视觉fixture/私有测试注册；新明暗2/2PNG逐像素一致。原首批11项/2PNG仅复用，不冒称本次重跑；旧51/device/真机/升级/推送/性能/Release/全suite未验证。
- 差分：本目录incremental-from-first.patch（相对首批）与cumulative-from-15c.patch；精确hash/路径见candidate-summary.json，SHA写外部证据避免自引用。新570+4=574 Swift全部≤800。
- 下一步FileBubble+thumbnail闭环、其余Chat入口和App根注入/路由仍待办；非全阶段4/Features物理完成。Core冻结F3后继后由唯一writer迁移并适配ConversationMessageSnapshot的autoclosure等输入，再固定R2独审，不自行整合。
- 回退仅丢弃本新私有批，原首批与15c不动。NEW_DEPLOY_SURFACE=0 JENKINS_CHANGE=0 SECRET_PLACEMENT=unchanged PROD_MUTATION=false AUTO_ROLLBACK=false REVIEW=REQUIRED_IOS_PENDING。


## WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110（附件展示叶子私有候选，待固定R2独审）

- 输入冻结第二批 vm6tfc3_，increment SHA256 2263f219b55194ab3d27c0c2203c23146f9fef0e248943c0a9b988a0460b93b1、cumulative SHA256 f3426d552dcd3b233edb71f2943e2e1579ff8043c1937df59bd33e6c24bb0024。仅新副本 /private/tmp/im4-ios1-attachment-leaves.lompz89u/source；原15c/首批/第二批/F4输入均冻结，未前移F4修复。
- FileMessagePresentation/FileMessageLayout/FileMessageContent与ServerVideoPosterContent/AttachmentOriginalContent接纯展示值、明确动作和惰性类型化插槽。原FileBubbleContent/ServerVideoPosterThumbnail/AttachmentOriginalThumbnail名称、构造入口保留在App真实组装，观察逐消息FileStore及原networkRecovery/scope binding，原服务继续负责缓存、下载、恢复、权限和提交；未加context/service locator/队列/缓存/代际权威。
- 旧Reply/Voice/GIF纯展示前279行、AppMessage/AppMedia/AppReply、AppState、thumbnail共享loader/gates前497行、poster task闭包、preview/Wuffs/cache/保护运行时保持字节相同。原任务ID、取消、占位/百分比/错误、尺寸与lazy资源分支保留。仅scope退休guard，正常换票和合法同scope重认证保持原runtime合同；不声称解决已知F4同scope身份刷新。
- Debug build-for-testing成功，原target/scheme/bundle、锁定依赖、jobs4、签名NO，最低15.0；仅自有iOS26.5模拟器。按各用例最后执行汇总14项13通过/1失败（非重跑整组）：原缓存权限断言失败，模式0644/0755而要求0600/0700；独立第二批原产品同样两断言失败。保留断言及原始失败，底层源码仍completeUntilFirstUserAuthentication、模拟器protection metadata=nil，不能证明.complete或真实iOS15保护。迁移须保留实际DS已硬化服务，不能以旧副本覆盖运行时；本批不修共享runtime。
- 新增5项4通过/1上述基线权限失败；实际缓存命中等待共享localDecodes入场、同host退休scope取消/迟到poster、正常token/同scope重认证、原预览/GIF/恢复/缓存writer fence等相关断言通过。poster初始会话及JPEG夹具修正只改测试，产品binary不变。初次Busy启动0执行及旧错选类漏跑的原记录保留，后者已单独补跑。
- 原源码控制与候选明暗2/2PNG逐像素一致；两个旧源码smoke仍双方同2case/7失败谓词，未删旧断言。144旧测试文件字节相同，仅AttachmentDownloadTests的实际App源码读取路径扩展，XCTAssert行保持。
- Features/Chat raw state依赖同口径449→417、29→27文件（分类外部证据），不是缺陷数；其余Chat入口/App根row factory/route注入及阶段5/6仍待办。本批不是全阶段4或物理Features模块完成。未重跑旧76/51/首批11、Release/全suite/真机/升级/推送/性能。
- 增量相对第二批及累计相对15c补丁、完整源码哈希、精确路径见本批candidate-summary.json；私有PBX只注册两App源两测试，实际manifest/PBX由DS唯一writer适配。F4另支固定R2结论未就绪，不合并；后继若采用其sessionSource/initialIdentity构造参数，须同步适配本批ChatAttachmentSessionView独立挂载分支，保scope generation合同。
- 回退仅丢弃本新私有批，不更改冻结输入和实际现场。NEW_DEPLOY_SURFACE=0 JENKINS_CHANGE=0 SECRET_PLACEMENT=unchanged PROD_MUTATION=false AUTO_ROLLBACK=false REVIEW=REQUIRED_IOS_PENDING。


## WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110（F4-only私有后继，待固定R2复审）

- 输入严格为冻结首批5bvtfb87，patch SHA256 22d7097d42f4d9e5b07bf8cabe3d8a0c64089137ca3b8a6f23683db77f248352；新副本/private证据 /private/tmp/im4-ios1-chat-f4.nkp2sxfn。未混第二批vm6媒体/引用代码或新测试，未改实际15c/ref/Core/PBX/四测试。
- F4/P2：原局部binding仅观察activeScope，guard却检查消息代际/epoch/authoritySessionID，合法same-scope renewal后当前挂载回调变旧且没有组装通知。
- App/ChatBubbleSessionIdentity.swift：专用派生UI值/CurrentValueSubject，只含原guard读取的五元组、localMessageSessionGeneration、epoch、authoritySessionID；无凭据/新generation/权限/网络/持久化权威。AppState.apiContext didSet在原reconcile前后比较派生值，localMessageSessionGeneration didSet保原失效顺序后通知UI，捕获提交await前及失败后的代际变化。
- ChatBubbleSessionBinding增加独立的sessionIdentity UI观察，刷新同一StateObject内的组装；原scope/login generation只在原activeScope流变化时更新，未因same-scope身份通知退休。dispatch guard逐字节保持，仍读取实时AppState派生值，不以缓存UI投影授权；普通token不改guard身份时去重。
- ChatMessageBubbleAssembly仅接线窄源、统一原identity取值、Debug捕获真实resend闭包；旧展示/metadata/消费链复用R2已核内容。未加id/remount/timer/global消息转发/AppState Published或global send。
- 原产品源码464文件逐字节的未修独立制品，加新测试与私有注册后负向3项：合法成功renewal、代际先推进但本地存储重绑失败均复现F4（2失败/8断言）；普通token控制通过。保存negative-source/products/hash/log/xcresult，未改原产物。
- 同一份新测试在修正制品中全部通过：当前read/sender/menu/attachment有效，保留的旧回调拒绝，host/view/row/message和scope退休generation保持。新增真实resend入口证实旧0/当前1请求。
- 直接focused首次8/9通过，resend新夹具把failed消息可读详情错置true，与原重认证失效逻辑冲突；保留整条消息相等断言，只将新夹具初始值改为false，单项重跑1/1通过。最新9/9用例通过，同一App二进制hash；原四转换/回执/F2-IME与两重认证持久化用例已过。无新截图/旧76/设备/CI/全套。
- 所有首批测试逐字节保留，两个F4新文件；Swift≤800（AppState797）。私有PBX仅注册一App UI源与两新测试，配置/target/scheme/bundle/依赖/floor保持。
- f4-only-from-first.patch为修正最小增量，cumulative-from-15c.patch为首批+F4（不含媒体批）；hash/准确路径/制品绑定见candidate-summary.json。实际writer仅在R2复审后按当前真实基线迁移，不覆盖完整AppState/PBX。
- 第二批共享binding前移尚未释放：其独立Voice fallback需补sessionSource/initialIdentity参数及既有可见性接线；generation语义未变，但跨批兼容须另核。本批不携第二批13/14、旧2 smoke/7断言、5新增/2PNG结论，仍原样冻结。
- R2 F4原结论NEEDS_FIX；本后继仅FIX_IMPLEMENTED_REVIEW_REQUIRED，不自批CLOSED/APPROVE。阶段4剩余/FileBubble/thumbnail/App根注入仍未完，当前无实际整合。回退只丢弃本新批，首批/第二批/实际main不动。
- NEW_DEPLOY_SURFACE=0 JENKINS_CHANGE=0 SECRET_PLACEMENT=unchanged PROD_MUTATION=false AUTO_ROLLBACK=false REVIEW=REQUIRED_IOS_PENDING。


## WDT_IOS1_MANAGED_CACHE_POSIX_AND_F4_ASSEMBLY_20261110（真实受管缓存权限修复＋已批F4语义组合，私有待独审）

- 新副本 /private/tmp/im4-ios1-cache-f4.elb6gu37/source，唯一基底第三附件批 lompz89u：increment 977f47817a96afbcfdfa6c95dd21ae3fdde4e4ab78371d344c65ae012d7064d4、cumulative 3fa10a2d3759557eafb2e990c448ac70599b0502653fcdeb7bdc90329c35d02b；首/第二/第三/F4原输入、失败、hash和binary均冻结，实际15c只读。
- 纠正第三批历史假设：只读Main 8f67510a981b4a6be7706b97da7701f79ab16ebb的MediaLayeredCache.swift与第三输入同SHA256 a1ab51d00be5ffefcd736d5fb8ce330ff6d0fa5613bbf8bebe715e1126796d3b，并非actual DS已替该链硬化。photo staging.complete属于另一条路径，不能等待迁移自动消除此真实POSIX缺口；原基线2失败原样保留。
- MediaLayeredCacheStore仅修自己构造/验证的root、类别目录和目标/part文件：新目录0700、文件0600；legacy命中返回前修复，核字节/hash/namespace/index保持。目录创建前lstat验证；descriptor/openat+O_NOFOLLOW/fstat拒绝symlink及借用hardlink，只fchmod受管inode，不递归、不chmod外部source或system/app-group/tmp父目录。替换使用受保护part的新metadata，避免继承旧0644。
- 原thumbnail UUID stager只把自己刚创建的文件设0600，失败清理并抛错；不改共享tmp目录或借用来源。verified copy不改外部source属性，unverified仅在移入受管part后改mode。保原cleanup、session fence、checksum及两gate/预算/admission/Wuffs/task取消。
- 原indexed cache completeUntilFirstUserAuthentication两处策略不变；unverified继承策略/backup行为不变；photo原.complete代码不动。模拟器保护metadata=nil，不宣称硬件保护/iOS15通过。权限失败返回failed/nil或throw，保持健康文件和verifiedCached索引以供重试，不冒成功、不删最后健康数据或重置DB/cache。
- 前移root已通告APPROVE_FOR_SOURCE_ASSEMBLY且F4/P2=CLOSED的nkp2批准语义：Identity/AppState/两新测试与批准输入字节同；AppMessage仅保留第二批父binding注入/internal观察器后合并。三个SessionObservation真实调用（父MessageBubble、Voice独立、ChatAttachmentSessionView独立）均补source/initialIdentity，File/poster/original透传；资源退休仍只scope/login binding.generation，不用UI identity/epoch/localgeneration代替，不增业务generation/全局Published/relay/timer/消息流。
- 最终Debug/App/XCTest编译通过，原target/scheme/bundle/锁定依赖/jobs4/签名NO、最低15。最终21/21 focused实际一次执行通过、0skip：真实三类别新写/legacy命中/替换0700/0600与索引、真实immutable属性EPERM失败/恢复、外部symlink无chmod、原localDecode gate/cache admission、F4同host成功reauth/gen-only失败/token/旧callback/真实resend、实际父binding下Voice/File/thumbnail当前/退休scope、checksum/writer fence等。实际路径/mode/API/索引证据在managed-permission-evidence.json及xcresult文本附件。
- 首轮21执行16通过/5失败保留：新fixture共享persistence及删除活跃DB导致fence/InvalidTransition，已改仅新fixture为隔离coordinator；新父fixture固定scope的空MessageStore已换真实SnapshotCache；Foundation包裹POSIX错误精确核根因EPERM/EACCES。集中修复后最终21全通过，不改任何第三批旧测试/断言。verification-history.json和两轮xcresult均保留。
- 两个旧源码smoke仍2case/7完全相同失败谓词；旧13-of14聚合、基线2mode失败、旧2PNG保留原版本identity。无布局变化：全部Features/Chat源码字节同第三，仅复用其2PNG不重跑/不冒新图。未重跑旧76/51/全suite/Release/真机/性能，未声称iOS15/升级/推送完成。
- 差分相对第三与累计15c、完整660源hash/mode在candidate-summary.json；AppState797行、583 Swift全≤800，417raw-state/27files与其余Chat factory/route、phase4/5/6/物理模块待办不缩减。实际Domain/Package/PBX仍原module唯一writer，Core/DS/Domain当前模型接入未做。
- 这是新权限源码与新组合接线候选，需原固定R2审查，实施者不自批；旧F4批准不替本批APPROVE。回退仅丢弃本新private批，原输入/actual/ref/main/生产不动。NEW_DEPLOY_SURFACE=0 JENKINS_CHANGE=0 SECRET_PLACEMENT=unchanged PROD_MUTATION=false AUTO_ROLLBACK=false REVIEW=REQUIRED_IOS_PENDING。


## WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110（当前Core/DesignSystem/Domain真实接入候选，待固定R2完整独审）

- 实际source唯一授权来自2026-11-10原root，复用ios1-timeline工作区，新分支codex/ios1-chat-presentation-assembly-20261110从已整合Domain的Main 50b8d137a104a9926cff272f315d6da8b6d57b0e起，IOS树71e89da18abb6579cb46641f09c7de976c5a96fe。旧15c分支/ref及所有private源/hash/产品/失败/截图冻结，不合旧15c整个仓历史，不改Main。
- 语义输入冻结elb6gu37，private cumulative SHA256 3f1ce00afe28f98eb8589176a0729fa56966aba69ebe8c75797c9ab82753122f；逐路径三方语义迁移，非旧PBX/AppState/markers整文件覆盖。Domain已批APPROVE只作为实际基线；此前批准的内容可复用，未审第三leaf/POSIX/新组合及当前接口需同R2一次完整审查，不加private批准关，不自批。
- App7新组装/纯Feature呈现与Reply/Voice/GIF/File/poster/original值+明确动作接真实当前API。Reply autoclosure适配ConversationMessageSnapshot，chatTranscriptConversation与当前scoped窗口来源保留，未恢复Conversation.messages/只读代理/全会话窗口。原3c bindingUUID/fullscope/memoryCommit、F3 live source/选择/目标、3d unread/F1原子重入、IME/F2/UTF16失败草稿/viewport/8pt/scroll/ACK代码保留。rowModel generation/renderVersion仍参与纯内容Equatable，目录/群/策略/actionIdentity观察在App先组装再等值阻断。
- AppState只加入批准F4 UI source及原reconcile/失效之后通知，0Published/0新增global relay，800行；父binding与三处观察器完整接线，资源退休仍scope/login generation，不用新UI identity退休资源。保原实时全身份guard，不靠重挂root/row/message补F4。
- POSIX仅冻结3运行时文件语义（与elb6gu37逐字节同）：受管root/目录0700、文件0600新写/legacy读回，descriptor nofollow/单link类型验证、受保护part推广，错误nil/throw且healthy bytes/index保留；不chmod外部来源/父目录、不清运行数据、不加authority/queue/fence。原cache UF-auth、unverified继承/backup与photo.complete策略分别保留；sim metadata=nil不当硬件保护证明。
- 原Core2/DS9/Domain10和Store源字节不变。PBX只新7App/10测试34对象，原对象/targets/config/framework/resource/package引用全留；Package只增加App exclusion。两配置App429（含1 generated asset source）、Core2/DS9/Domain10各静态1、Domain40各descriptor1/旧App0、WXT3各1、App Metal保留，min15。
- 必要Debug App/全部XCTest编译与普通unsigned genericIOS arm64 Release通过，原Onone/incremental与O/WMO、不启用Release testability。实际focused首轮28执行27通过/1 poster fixture失败：当前Store切scope退休旧消息，原夹具遗漏B源窗口。用真实Store API补B初始窗口，不重挂UI、不弱断言；scope叶子不观察该消息更新，因此不能靠它伪造UI rebind。随后2个相关叶子fixture改隔离coordinator/real SnapshotCache，避免清理活跃shared SQLite；目标2/2通过、0 vnode-unlinked警告，App二进制与首轮同，末次28distinct通过（不冒第二轮整28）。初次缺scope诊断参数的编译失败/各次fixture失败警告日志完整保留。
- 两个旧源码smoke仍2case/7相同失败谓词；141原Main测试文件字节同，3个source locator扩展全部XCTAssert行/顺序同。无视觉变化，仅复用原版本2PNG；没有重跑老76/51/24/全suite/真机/性能，不宣称iOS15硬件/IME/升级/推送完成。
- source/interface/PBX/产品/结果/完整tracked hash+mode及candidate/parent/repo/IOS tree在/private/tmp/im4-ios1-chat-actual.9mnnyfmh的外部packet。实际Features/Chat剩余419raw-state/27文件（private417差2来自当前Main原ChatViewLayout；非缺陷数），原剩余factory/route/phase4/5/6/物理模块目标不缩减。
- 回退为拒收/撤销本功能候选的限定delta，保Core/DS/Domain/currentMain/其他WIP；未审不Main。仅正常本地功能分支commit，无push/签名/真机/CI/部署/云/生产。NEW_DEPLOY_SURFACE=0 JENKINS_CHANGE=0 SECRET_PLACEMENT=unchanged PROD_MUTATION=false AUTO_ROLLBACK=false REVIEW=REQUIRED_IOS_PENDING。

<!-- WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN -->

## Data private complete disk-boundary prototype - 2026-11-10

`PRIVATE_UNREVIEWED / BASED_ON_REVIEW_CANDIDATE=50b8d137a104a9926cff272f315d6da8b6d57b0e`; not canonical. Only the new private copy is changed. Actual and all prior frozen evidence remain read-only.

The original App consumes static IM4Data. It owns SQLiteMessageRepository, its four SQL extensions, unchanged schema/migrations, durable attachment staging, disk DTOs, legacy snapshot disk engine and pure media-index records/keys. The original App MessageStore protocol keeps its IMAPIContext contract; SnapshotCache conforms through the original thin App adapter. ScopedMessageMemoryStore and observable Stores are separate.

Session generations, retirement/recovery/cleanup coordinator, media runtime, networking and Store ownership remain App. An immutable synchronous codec calls the original App cache/RTC-time/peerUID/redaction bodies without new await, queue, fence or retry timing. Storage and media identity errors preserve original NSError domain, code, empty userInfo and App upload classification.

Change index (origin ranges and SQL body checks are in extraction-map.json and sql-contract-comparison.json):

- `Sources/IM4Data/AttachmentTransferRepository.swift:1-190`
- `Sources/IM4Data/CachedRemoteSnapshotRecords.swift:1-367`
- `Sources/IM4Data/LocalMessageRepository.swift:1-320`
- `Sources/IM4Data/MediaCacheIndexRecords.swift:1-399`
- `Sources/IM4Data/MessageAttachmentChecksum.swift:1-13`
- `Sources/IM4Data/MessageDatabaseMigrations.swift:1-46`
- `Sources/IM4Data/MessageDatabasePaths.swift:1-292`
- `Sources/IM4Data/MessageDatabaseSchema.swift:1-397`
- `Sources/IM4Data/MessagePersistenceModelCodec.swift:1-11`
- `Sources/IM4Data/PendingAttachmentFileStore.swift:1-111`
- `Sources/IM4Data/ProfileContactProjectionRecords.swift:1-128`
- `Sources/IM4Data/SQLiteMessageRepository+Acknowledgements.swift:1-496`
- `Sources/IM4Data/SQLiteMessageRepository+MediaCache.swift:1-721`
- `Sources/IM4Data/SQLiteMessageRepository+Outbox.swift:1-659`
- `Sources/IM4Data/SQLiteMessageRepository+Projection.swift:1-736`
- `Sources/IM4Data/SQLiteMessageRepository.swift:1-172`
- `Sources/IM4Data/SnapshotDiskCache.swift:1-187`
- `BlueStoneIM/DataModuleBridge.swift:1-57`: only DTO extraction, aliases, original protocol or codec adapters.
- `BlueStoneIM/DataAppAdapters.swift:1-47`: only DTO extraction, aliases, original protocol or codec adapters.
- `BlueStoneIM/CachedRemoteSnapshot.swift:1-170`: only DTO extraction, aliases, original protocol or codec adapters.
- `BlueStoneIM/ContactStore.swift:1-660`: only DTO extraction, aliases, original protocol or codec adapters.
- `BlueStoneIM/Domain/FileModels.swift:1-205`: only DTO extraction, aliases, original protocol or codec adapters.
- `BlueStoneIM/MediaResourceModels.swift:1-245`: only DTO extraction, aliases, original protocol or codec adapters.
- `BlueStoneIM/SnapshotCache.swift:1-44`: only DTO extraction, aliases, original protocol or codec adapters.
- Package.swift/project.pbxproj: static product/target and original App link; same GRDB identity/exact 7.11.1 pin. Existing eight configurations, resources, Wuffs/metal and other module sources remain unchanged.
- `BlueStoneIMTests/MessageDatabaseMediaCacheTests.swift`: necessary @testable import only; MessageDatabaseTests additionally pins Data ownership, legacy NSError identity and original App upload error classification. Original assertions are retained. ACK/DB test hooks remain internal.
- `BlueStoneIMTests/MessageDatabaseSemanticsTests.swift`: necessary @testable import only; MessageDatabaseTests additionally pins Data ownership, legacy NSError identity and original App upload error classification. Original assertions are retained. ACK/DB test hooks remain internal.
- `BlueStoneIMTests/MessageDatabaseTests.swift`: necessary @testable import only; MessageDatabaseTests additionally pins Data ownership, legacy NSError identity and original App upload error classification. Original assertions are retained. ACK/DB test hooks remain internal.

Evidence: `/private/tmp/im4-ios1-data-prototype.i4k8nosy/candidate-summary.json`, source/hash/modes/50b8 patch, build inputs/linkage/min-iOS, selected real-database results and all failed build attempts. Remaining Data/networking/Stores/Features are listed in remaining-scope.json; no whole-layer or phase 4/5/6 completion claim.

Rollback: discard this private prototype; after any future independent acceptance, revert only the whole Data delta. Preserve other candidates, owners, user files and real DB/cache. No data migration, cleanup, rebuild or deletion is authorized by this prototype.

NEW_DEPLOY_SURFACE=0; JENKINS_CHANGE=0; SECRET_PLACEMENT=unchanged; PROD_MUTATION=false; AUTO_ROLLBACK=false. No commit/push/main, signing, physical install, CI, cloud or production action. Original R2 independent review remains required before adoption.

<!-- WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END -->

<!-- WDT_IOS1_DATA_ACTUAL_ASSEMBLY_20261110_BEGIN -->

## Actual Data storage assembly on independent Chat dependency - 2026-11-10

BASED_ON_CANONICAL_HEAD=NO. PARENT_DEPENDENCY=f282a1a6d12d3abf726269ba7963fe7ae2d02ea7_UNREVIEWED; observed main0218c8317663f606b62753c78b0d1140220fda3c. Separate phase5 Data candidate stacked on phase4 Chat, not main or Chat approval. Original fixed R2 must approve complete content and actual Chat connection; only root/original R7 may integrate Chat first and Data afterward.

Frozen storage prefix i4k8nosy patch896da0a13086539ead0fbf840398ff3ced9081d3513865852d436b64d5feb4b3 is assembled semantically.37 non-glue paths equal prefix except one import trailing-space cleanup. Package changes are contextual hunks retaining Chat App exclusions. PBX assembled from f282 preserves all34 new Chat objects and existing8 configurations; original10 App storage memberships removed,2 App alias/codec files and static Data product added. Entire Chat index and App7/F4/managedcache/noFollow/attribute recovery/metadata/IME/scroll paths retained. No old50b8 AppState/PBX/Package/AttachmentRuntimeSupport whole-file projection.

Prior private Data WDT source/range index immediately above identifies all17 Data sources and aliases/adapters. This actual marker covers shared PBX assembly and this record; Package retains precise Data prefix markers. CachedRemoteSnapshotRecords import cleanup changes no code or public API. New DTO networking successor remains separately preserved, unfinished, and excluded from this actual candidate.

Actual evidence: /private/tmp/im4-ios1-data-actual.yzgopf66/candidate-summary.json (commit/parent/fresh main/source hashes/modes/patch/build inputs/artifacts/public API/Chat preservation/focused results/remaining scope/rollback). All actual validations use this worktree and own DD/cache/simulator, never private results. Original31 distinct storage targets and necessary directly affected indexed-cache/attachment boundaries only; original assertions and both known exact50b8 baseline failures retained, no full suite/screenshot/performance repeat or all-green claim.

SQL/schema/migrations/path/identity/codec/protection/backup/NSError, original App error classification and coordinator ACK/retry/fence policies retain prefix content. No Conversation.messages restoration or memory MessageStore. Static Core2/DS9/Domain10/Data17, same GRDB7.11.1 pin/WXT/metal/config/resources. Remaining Data networking/Stores/Features work is open.

Rollback only whole Data delta from f282, preserving Chat/Core/DS/Domain and real DB/cache; no automatic production rollback/reset/cleanup. Local single-parent source commit only; no main/push/codesign/physical-device install/CI/cloud/production. NEW_DEPLOY_SURFACE=0;JENKINS_CHANGE=0;SECRET_PLACEMENT=unchanged;PROD_MUTATION=false;AUTO_ROLLBACK=false.

<!-- WDT_IOS1_DATA_ACTUAL_ASSEMBLY_20261110_END -->

<!-- WDT_IOS1_DATA_NETWORK_DTO_20261110_BEGIN -->

## Private Data networking DTO successor - 2026-11-10

PRIVATE_UNREVIEWED_SUCCESSOR. Base immutable50b8 + frozen i4k8nosy storage prefix (patch896da0a13086539ead0fbf840398ff3ced9081d3513865852d436b64d5feb4b3); prefix remains pending original R2 content review, not canonical or approved. Only this new private source is writable. Actual Chat/PBX writer and actual50b8, i4k8nosy and prior evidence remain read-only.

Complete upload-response and sticker-manifest DTO boundary:12 original full value types with fields/defaults/Decodable keys/Equatable, alias priority and merge behavior retained. Checked Sendable retains original internal implicit inference. Original App files become aliases to the same static IM4Data;15 existing actual App consumer files retain their request/authority behavior. Numeric container helpers are internal exact copies; the original App/global helpers, JSONValue and all forbidden Core phase6/page/wire/mapper/realtime execution paths are unchanged. No service/container/router/queue/cache/fence, URL/header normalization or authority/runtime policy is added.

Changed source index:

- `Sources/IM4Data/NetworkingDTO/RemoteAvatarUploadModels.swift:1-354`
- `Sources/IM4Data/NetworkingDTO/RemoteStickerModels.swift:1-273`
- `Sources/IM4Data/NetworkingDTO/NetworkDTOScalarDecoding.swift:1-53`
- `BlueStoneIM/Core/Networking/DTO/RemoteAvatarUploadModels.swift:1-10`
- `BlueStoneIM/Core/Networking/DTO/RemoteStickerModels.swift:1-10`
- `BlueStoneIMTests/DataNetworkDTOBoundaryTests.swift:1-55`
- Package.swift:3 explicit DTO/helper inputs added to existing static IM4Data (17 to20).
- project.pbxproj:only the new XCTest file membership; existing App DTO memberships remain aliases.
- This index section; all storage-prefix sources, SQL/schema, original pins/configurations/resources/modes, stores, managed-media/runtime and original tests remain unchanged.

Focused evidence uses native host Foundation to compare the original exact DTO sources with the actual new source slice (not a whole Data/App runtime claim). Normal Debug App/all XCTest and unsigned generic iOS arm64 Release are compile-only; no App/simulator/physical installation. No rerun or reclassification of i4k8nosy original31 cases/29pass/2 exact50b8 failures, screenshots or full suite. New XCTest DTO regressions are compiled, not reported executed.

Evidence and incremental/cumulative patches: /private/tmp/im4-ios1-data-networking.87prdbvd/candidate-summary.json. Remaining Data/networking/Stores/Features and policy/runtime extraction remain incomplete. Root/original R7 alone may integrate after fixed R2 independent review. Rollback only this full successor increment or discard private source; do not reset/overwrite prior candidates, other owners or real data.

PROD_MUTATION=false;AUTO_ROLLBACK=false;NEW_DEPLOY_SURFACE=0;JENKINS_CHANGE=0;SECRET_PLACEMENT=unchanged. No commit/main/push/sign/install/CI/cloud/production, new agents/tasks/worktrees, or cross-task messaging.

<!-- WDT_IOS1_DATA_NETWORK_DTO_20261110_END -->

<!-- WDT_IOS1_DATA_DTO_ACTUAL_ASSEMBLY_20261110_BEGIN -->

## Actual Data12 DTO assembly on frozen Storage dependency - 2026-11-10

BASED_ON_CANONICAL_HEAD=NO;PARENT_DEPENDENCY=2da_STORAGE_UNREVIEWED_NOT_MAIN. Parent2da58e9ed0ff4fdefeb3514333dee9fec17883b9; observed main0218c8317663f606b62753c78b0d1140220fda3c. Separate normal single-parent DTO candidate, exactly9-path increment, not Storage40 or Chat acceptance. Chat ac846 C1 correction remains separate; inherited2da old C1 test constant is untouched. Gate must integrate Chat/C1 then Storage then DTO and project only this9-path delta onto corrected Main; never old whole IOS tree.

6 non-glue DTO/alias/test files equal frozen87prdbvd. Package contextual hunk appends3 files to exact Data target, verifiedDS9/Data20 and existing App exclusions unchanged. PBX assembled on actual2da adds only2 test objects and group/source registration; all Chat34/Storage6 objects/products/configurations retained. Storage17/bridge/codec/SQL, AppState, requests/envelopes/auth/scope/retry/errors/page/wire/mapper/realtime, UI/runtime/media policy and all other parent sources remain byte-identical.

Original private NetworkDTO WDT file/range index above remains content provenance. Actual evidence: /private/tmp/im4-ios1-data-dto-actual.kzsbgn3i/candidate-summary.json. Actual validation uses own DD/cache and existing owned arm64 simulator:4 new DTO methods plus minimal original FakeHTTPTransport App upload/avatar/sticker endpoints; no old31/34 storage/full Chat suites or screenshots. Historical39 Host Foundation vectors are not iOS/App runtime evidence and are reused only because DTO bytes match exactly. StrictInt size_bytes string/Bool rejection and original37 plus2 corrected Int fixtures remain immutable.4 originally compile-only tests are counted executed only after actual results.

All12 value fields/defaults/CodingKeys/custom decode/alias order/headers/merge/Equatable/checked Sendable retained; scalar helpers/CodingKeys/DB test hooks internal. Static Core2/DS9/Domain10/Data20, GRDB7.11.1 exactpin/WXT/Metal/config/resources/Bundle/min15 preserved. Not complete Data networking/Stores/Features. Original fixed R2 must review full12 DTO content and actual App connection; no separate private approval gate or self approval.

Rollback only whole9-path DTO delta to2da; preserve Storage/Chat/C1/Core and real data. No main/push/codesign/physical-device install/CI/cloud/production. NEW_DEPLOY_SURFACE=0;JENKINS_CHANGE=0;SECRET_PLACEMENT=unchanged;PROD_MUTATION=false;AUTO_ROLLBACK=false.

<!-- WDT_IOS1_DATA_DTO_ACTUAL_ASSEMBLY_20261110_END -->


<!-- WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN -->
### WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110

Private prerequisite 5.1b prototype based on `2162ea5c6a788cad60fdf69df62d05c68a1a864d`; no actual-worktree integration or package extraction.

- `BlueStoneIM/Navigation/FeatureRouting.swift`: SwiftUI factory contracts carrying Domain inputs and existing callbacks; no navigation state or concrete Feature constructors.
- `BlueStoneIM/App/FeatureRoutingComposition.swift`: stateless real Chat/Profile/GroupDetail factories and original App environment composition (moved out of CertificationRefresh).
- `BlueStoneIM/ContactsViews.swift`, `Features/Contacts/{ContactGroupList,OrganizationDirectoryViews,ContactGroupDetail,GroupMemberManagementViews,GroupHistoryScreenshots}.swift`: original local routes and callbacks use injected factories.
- `BlueStoneIM/ChatViews.swift`, `Features/Chat/{ChatViewLayout,ChatConversationSheets}.swift`: original local sheet/destination bindings and pending-ID callbacks use injected factories.
- `Core/AppSupport/RemoteSync/AppState+CertificationRefresh.swift`: only removes the moved View/App composition helper.
- `BlueStoneIM.xcodeproj/project.pbxproj`: registers two App sources and the focused test source in existing targets; original scheme, deployment target and build mode retained.
- `BlueStoneIMTests/FeatureRoutingNavigationTests.swift`: real-view navigation, original callback/onDismiss/async behavior, native back/reentry and account environment checks; no placeholder destinations. Starts Chat sheet state through its existing initializer and drives page callbacks directly, so these are not automated screen-tap acceptance.

Rollback: discard this private candidate or reverse its exact patch. No runtime/data rollback is required. Independent R2 review and current owner/gate collision checks remain prerequisites to actual adoption.
<!-- WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END -->


## WDT_IOS1_CURRENT_FEATURE_ROUTING_ASSEMBLY_20261110（f282 proper-layout私有路由组装，待原链后续接入）

- 仅新private /private/tmp/im4-ios1-routing-current.hcipexs0/source，输入immutable f282a1a6d12d3abf726269ba7963fe7ae2d02ea7、IOS46113b83cb9fed9d27718f2c9eb1ca49691c1943，actual共享source/Package/PBX租约已转原module owner，本轮全只读，无actual commit/Main/push。前批actual f282的BASED_ON_CANONICAL_HEAD=50b8保留历史，Main0218单Web推进不改写它。
- 语义采用R2已APPROVE_FOR_SOURCE_ASSEMBLY的7PiSBP路由前置，base2162/patch dc9b3e497f786d8f1c1d83632e86bcdb551d6a45e2adb1e483c9fe2d6f725e06；不复制旧整树/旧.messages/AppState/PBX。两个contract/composition文件与批准版字节同，15入口9Chat/5Profile/1Group转窄值/闭包factory；Features不留相互concrete constructor/fallback，App三真实构造，factory无全局状态/无AppState捕获。原UUID/同ID/crossID/pendingID/onDismiss/惰性时点及0.16延迟、env/owner保持。
- appStateEnvironment的当前原body仅移到App并加两factory环境；Certification业务prefix字节同，未混Data/DTO/Core page/wire/signpost/mapper。私有PBX仅2App/test1的6对象注册，原targets/config/resources/package/framework对象同；Package仅新Navigation exclusion保DS9 ownership。当前Core2/DS9/Domain10、AppState/F1-F4/scoped窗口/8pt/读token/epoch/IME/F2/UTF16失败草稿/metadata/source/缓存权限/gates/预算源码保f282字节，未加新scope hook/authority/relay。
- 先盘点后实施：Features/Chat 419refs/27files/415lines，其中显示123、局部窄Store观察81、动作192、scope/lifecycle23，数字非缺陷数；routing后同数。已断指定15构造循环，不等于整个阶段4/5或物理Features模块完成；其余direct reads/根row factory/Composer与各阶段目标保留。剩余8concrete为App3、App截图/policy4及ConversationList1，均另列。
- 当前proper-layout Debug App/全部XCTest编译PASS；normal unsigned generic IOS arm64 Release PASS，原优化/签名NO/jobs4/min15。两配置App431（含1自有generated asset）、Core2/DS9/Domain10各static1、Domain40各descriptor1/oldApp0、WXT3各1、App metallib保留。
- 当前新接口实际挂载focused6/6/0skip，一次执行：旧批准5 case及新增退休Contacts owner旧callback不污染另一mounted scope、当前callback仍进入真Chat并继承B state。真实UITable delegate/native pop/reentry及sheet/pending/onDismiss驱动；不是在线UAT/物理点击/同host换账号安全证明，未改authority。Profile按钮命令及Group search/pinned动作仍原字节，未把未点击路径写成端到端。
- 旧routing16/17和onAppear3秒超时只复用原版本未解决观察，没重跑或称修复；f282原28仍末次聚合，不冒一轮28。旧2case7源码失败/原private失败/2PNG均保版本identity不重跑。全部154个f282旧测试字节同，原批准导航36条XCTAssert行顺序同；无新截图/老76/51/24/fullsuite/真机/性能/iOS15硬件验收。
- delta相对f282、完整684源hash/mode、编译输入/制品/6case绑定/15入口图及唯一后续动作见外部candidate-summary/HANDOFF。当前factory/newproper-layout接线需原Root后续当前base装配与适用R2审查，旧内容批准不替新接入；不新建owner/reviewer或私有审批关。下一代码批唯一目标为App根row factory窄接口+注入，Composer/direct reads按原scope后续分批，不一批重写27文件。
- 回退仅丢弃本新private增量，原f282 actual及全部packet/旧私有prototype只读保全，不清DB/cache/数据，不自动rollback。NEW_DEPLOY_SURFACE=0 JENKINS_CHANGE=0 SECRET_PLACEMENT=unchanged PROD_MUTATION=false AUTO_ROLLBACK=false REVIEW=REQUIRED_IOS_PENDING。


<!-- WDT_IOS1_CHAT_ROW_FACTORY_ACTUAL_20261110_BEGIN -->
App root row factory: Feature passes row values and named actions, App injects the existing observed MessageBubble; ConversationList forwards its original UUID/search route. C1 is already in Main and remains unchanged. Actual source preserves current Data20/GRDB and existing runtime/session/resource guards. Independent R2 review is required before integration; no phase4/5/6 completion claim.
<!-- WDT_IOS1_CHAT_ROW_FACTORY_ACTUAL_20261110_END -->

<!-- WDT_IOS1_DATA_HTTP_ACTUAL_ASSEMBLY_20261110_BEGIN -->

## Actual basic HTTP mechanism extraction on approved Main - 2026-11-10

Fixed parent Main d0f42481ad838ab2216aa91615a38526374ca675; IOS base212bc1557424cec6f1b13619fbae80addb72e54f. Only this HTTP source/Package/PBX/marker lease; no B343 routing, compute/SP1/page/wire/Stores or old whole-tree projection. Old c008/2da/Chat refs and packets remain immutable. Later unrelated Main changes are not chased/rebuilt.

Core already owns HTTPTransport/HTTPTransporting/HTTPTransportResult; reused, not duplicated. Data22=previous20+MainActor claim/store+defaultURLSession implementation and its existing private immutable origin redirect delegate. Original App aliases/default construction consume Data; opaque key and Task.detached factory/await/finish and all request/auth/scope/cancel/reset/response/page policies remain original App bytes. No owner-count/cancelAPI/newfence/queue/authority or newunchecked; old delegate unchecked is moved exactly. Internal registered-count/key and existing DB/scalar/CodingKeys hooks remain unexported.

Private input45eb2cee58ca3c300a82b39b818a6e7dc7fe959e5cc620e3356ac64f48ca6f79/697 sources retained. Actual differs by fresh Main glue, this marker, existing findings-doc append, and explicit diagnostic scope correction: new actual test file has only the4 real migration methods, while private strict future-invariant expected1 method/xcresult remain unchanged. No Main old test is deleted/weak/skip/expectFailure. Actual count is its own count, never private11-all-green.

Source/range index:

- `Sources/IM4Data/Networking/HTTPInFlightRequestStore.swift:1-40`
- `Sources/IM4Data/Networking/URLSessionHTTPTransport.swift:1-65`
- `BlueStoneIM/HTTPTransport.swift:1-16`
- `BlueStoneIMTests/DataHTTPMechanismBoundaryTests.swift:1-87`
- HTTPHeadersRemarksAndRTCContractTests.swift: necessary @testable Data import only, all Main method/assertion bodies preserved.
- Package.swift: preciseData target20 to22, Core2/DS9/Domain10/exclusions/products/pins unchanged.
- project.pbxproj: only2 new HTTP test objects and testgroup/source refs.
- docs/REFACTOR_FINDINGS.md: append IOS1-HTTP-RESET-LATE-CLAIM-BASELINE / OPEN_BASELINE, original observations/impact/recovery/unfixed status.
- This actual marker.

Actual own DD/SPM/arm64 simulator Debug App/all XCTest, originalnormal unsigned generic iOS arm64 Release/min15/staticlinkage, and focused real consumers recorded at /private/tmp/im4-ios1-data-http-actual.9hc4zxx6/candidate-summary.json. No oldData31/34/DTO8/39Host/Chat/fullsuite/PNG replay. No hardware/iOS15/UAT/performance claim. Required new products/generated inputs/results kept until review consumption; no premature cleanup or missing old-product freshhash claim.

Rollback only this complete HTTP9-path delta to fixed Main, including findings append, preserving all other source/user materials/real data. First full HTTP content+actual connection review by fixed R2 via root, no private prerequisite or self approval. No Main write/push/sign/physical-device install/CI/Jenkins/cloud/SQL/production. NEW_DEPLOY_SURFACE=0;JENKINS_CHANGE=0;SECRET_PLACEMENT=unchanged;PROD_MUTATION=false;AUTO_ROLLBACK=false.

<!-- WDT_IOS1_DATA_HTTP_ACTUAL_ASSEMBLY_20261110_END -->


<!-- WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_BEGIN -->
## WDT_IOS1_STORES_CONTACT_ACTUAL_20261110 — phase5 first actual Stores closure (ContactStore)

- Private validation complete, REVIEW_REQUIRED; not Main integration approval. Exact approved input `d0f42481ad838ab2216aa91615a38526374ca675`, IOS1 tree `212bc1557424cec6f1b13619fbae80addb72e54f`. Whole original ContactStore660 unit (revision fence + ContactStore + GroupSelfProfileStore) is physically in IM4Stores1. Complete InboxItem/DeviceSession plus private original category helper are in a single added Domain file; Domain11, old Domain10 and Data20 original bytes unchanged. Other Domain/Data/Stores/Features work remains incomplete.
- IM4Stores is a real static product/target, depends only on the Domain types it actually uses. Original App Data persistence/composition continues unchanged; no artificial unused Data dependency, copied Domain/Data, shadow Store, service container, new actor/Task/queue/timer/authority/fence/schema/notification or global relay. App aliases resolve to the single moved Store and Domain value types; original 66 function bodies, Published property order/defaults and pure model fields/defaults/constructors remain equivalent. Explicit checked Sendable is required only for the two exported pure values and directory snapshot after internal inference stops at the module boundary.
- Only true cross-module methods/types/state access are public. Read stamp is opaque; mutation ticket exports revision only. Private fence maps/keys and internal status/test queries remain hidden (public symbol graph114, internal queries0 exported). GroupSelector init/matches are real App entries, backing fields internal. Eight old test files add testable Store imports only, without changing assertions/bodies. Five actual generic/@State consumers add imports only; no Chat/group/Contact/Conversation business-body edits.
- Debug App/all154 XCTest source files and normal unsigned generic iOS arm64 Release succeeded, jobs4/CODE_SIGNING_ALLOWED=NO, normal optimization/testability settings unchanged. Actual compiler members Core2/DS9/Domain11/Data20/Stores1; every static package object links1; ContactStore/GroupSelfProfileStore/InboxItem/DeviceSession final nominal definitions1 each and old App0; min iOS15, WXT GIF3 each1, Metal retained, no new Stores dylib. All8 project configurations/pins/resources/entitlements retained. All620 Swift files <=800, AppState original bytes/Published0.
- Focused initial21 =20pass/1fail in a new Combine reentry expectation; baseline original-unit native macOS probe reproduces2 instead of assumed3, final property/fresh-subscriber write preserved. Corrected new case1/1pass; final actual-connection subset5/5pass after explicit imports. 21 distinct cases (19 old +2 new) have passing records; no final full21 rerun. Inventory2204, +2/-0. All old assertions byte-identical. No old31/34/DTO8/Chat19/full suite/PNG/performance/iOS15 hardware acceptance. The host reference is not original iOS App baseline.
- Scope protects MessageStore/ConversationStore/scoped memory/compute/RTC/transport/message mapping/buffer/ACK/outbox/schema/Chat business code/HTTP DTO business code. Original scope/read/mutation/late/reentrant/remark/avatar/GroupSelf/notification behavior retained. Initial compilation failures, boundary clarification interruption, helper alias-path error/interruption, original first successful Release with import diagnostics, macro-import interruption, initial test failure and corrected results remain recorded; one partial helper CLI stdout was overwritten, with exact reason/pids and DD activity logs retained, no success claimed.
- Full private source, base, hashes/Git exec modes, compiler lists/products/public API/xcresults/failures in `/private/tmp/im4-ios1-contact-stores.w953rt2v/`. Root explicitly authorizes, AFTER this private freeze, an ordinary actual single-parent candidate from approved d0f in original worktree/new codex branch, preserving bdb/HTTP refs and all old private packets. Actual source must equal this compiled cut; only this index is postbuild metadata. Existing private executions may then be reused with exact source binding and different cwd disclosed. No Main/push/CI/signing/physical device/cloud/production action. Actual manifest/commit identity is in the linked owner report, never inferred here.
- Same original R2 first complete new Stores/actual-connection review, then original R7/root semantic assembly only. Frozen compute/page/wire/SP1 do not ride this patch. Root supplied SP1 corrected4iii APPROVE_FOR_SOURCE_ASSEMBLY/CLOSED; old frozen waiting-review language is historical, unchanged. NEW_DEPLOY_SURFACE=0, JENKINS_CHANGE=0, SECRET_PLACEMENT=unchanged, PROD_MUTATION=false, AUTO_ROLLBACK=false.

| File | Current marker span |
|---|---|
| `BlueStoneIM.xcodeproj/project.pbxproj` | 11–3234 |
| `BlueStoneIM/App/ChatBubbleMetadataAssembly.swift` | 2–2 |
| `BlueStoneIM/App/ChatReplyQuoteAssembly.swift` | 3–3 |
| `BlueStoneIM/ContactStore.swift` | 1–9 |
| `BlueStoneIM/ContactsViews.swift` | 2–2 |
| `BlueStoneIM/ConversationViews.swift` | 2–2 |
| `BlueStoneIM/DomainModuleBridge.swift` | 64–67 |
| `BlueStoneIM/GroupDetails/GroupDetailMembers.swift` | 2–2 |
| `BlueStoneIM/Models.swift` | 252–271 |
| `BlueStoneIMTests/DomainChatTranscriptAndContactStoreTests.swift` | 10–10 |
| `BlueStoneIMTests/DomainGroupProjectionAndScopeTests.swift` | 9–9 |
| `BlueStoneIMTests/DomainHistoryBoundaryAndDirectoryTests.swift` | 10–10 |
| `BlueStoneIMTests/DomainInboxAndConversationReadStateTests.swift` | 10–10 |
| `BlueStoneIMTests/DomainPresenceAndSplashTests.swift` | 10–10 |
| `BlueStoneIMTests/DomainQueuedReadAndGroupProjectionTests.swift` | 10–10 |
| `BlueStoneIMTests/HTTPGroupAnnouncementAndLegalDocumentTests.swift` | 6–6 |
| `BlueStoneIMTests/ScopedResponseFenceTests.swift` | 3–3 |
| `BlueStoneIMTests/StoresContactBoundaryTests.swift` | 8–70 |
| `Package.swift` | 17–241 |
| `Sources/IM4Domain/InboxDeviceProjectionValues.swift` | 3–98 |
| `Sources/IM4Stores/ContactStore.swift` | 1–669 |

<!-- WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_END -->

## WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110

- Private only, fixed input `f80f46c9aa9d53bc269ad707a58a37ad0389306b` / IOS tree `ce6e053d33f8d88c8ad907dab25dd8f63477ffc2`; HTTP input is unreviewed and not Main.
- Move the complete organization directory four-DTO family and six pure contact DTOs to IM4Data; original App files keep aliases, tenant/group policy and certification/profile error projection remain in App. Existing IMAPIClient/RemoteAPI orchestration and all business mapping stay byte-identical.
- Files: original DTO/RemoteDirectoryModels.swift and DTO/RemoteContactModels.swift, new Data NetworkingDTO counterparts, existing internal NetworkDTOScalarDecoding.swift (original Bool decoder body only), Package.swift Data source members 22→24, PBX new focused test membership, DataDirectoryContactDTOBoundaryTests.swift. Whole marked blocks are the merge unit.
- No fields/defaults/CodingKeys/strict-or-lossy strategy/error/mapping/cancellation/storage/schema/resources/pins/target configuration changed. Public access is limited to moved DTOs and their existing consumed fields, accessors and initializers; helper/CodingKeys stay internal.
- New focused coverage checks native fields, alias precedence, >2^53 integer precision, strict error behavior, real directory/contact IMAPIClient routes/query/body/bearer/tenant outputs and unchanged App friend outcome mapping. Separate owner evidence records exact results, complete source hashes/modes, source-level body equality, compiler inputs/API, normal Debug/Release products and rollback patch. No integration or review approval implied.
- Fixed source packet and own delta: see candidate summary in the private stage; never merge a partial marked block.


<!-- WDT_IOS1_WIRE_PAGE_CURRENT_ASSEMBLY_20261110_BEGIN -->
## WDT_IOS1_WIRE_PAGE_CURRENT_ASSEMBLY_20261110 — current approved Main wire/page decode assembly

- Fixed approved Main `069f4523c4709e3f052fb6f2b949698b8de3b99b`, IOS1 `f7dd4cc104272ba37bca91b2405471a98f0550a2` (HTTP Data22 integrated over Row24); one fresh Main read then fixed input, no later chase. Only wire11 prefix f6f5934f04db1f603f94becc09b6f0e4caa26cc8ec1ac7e187af9ffba9f1b5c9 and page7 03949590f51f4108db0e1b7ed8351a446a2a233096c0a6f2f659bad84b10e8b6 approved contents. Do not apply compute33/cumulative38 or old whole snapshots. All16 code/test files equal their original approved whole-file bytes. Only current PBX parent is different: preserve every parent object/config and add exact four approved objects/four memberships. Old page index not copied.
- Actual WS/QUIC per-loop actor decode, wire limits1MiB/depth16/frame256/elements512, order/control/handshake/dedupe/generation/leg/admission/session fences retained. Manual injection remains synchronous, prepared carrier distinguishes prepared nil and avoids Main JSON repeat; pure checked Sendable values, no shared mutable decoder/AppState/Store crosses worker. Existing accepted same-scope credential ACK/durable completion and genuine retired admission rejection tested. No second business queue/timer/session authority. Approved invalid nested scalar/null guard changes old ObjC-exception boundary to failure fallback; do not claim all malformed behavior unchanged.
- Exact POST /api/im/conversations/page plus exact RemoteConversationPage only uses typed background carrier; original codec triple order/error/login-security/APIEnvelope<Page>, default decoder/date/key/number semantics and Core NSError identity/empty userInfo/error classification retained. Other endpoint/type paths unchanged. Original current Data22 raw factory/claim-await-finish, URL/auth/scope/body/header/cache/timeout/redirect and Loader ticket/page publication/last completion remain untouched. Cancellation suppresses Loader commit, not promised immediate CPU parse preemption. Generic legacy unchecked wrapper unchanged; new task carries page-only checked value.
- Necessary new-cut Debug App/allXCTest and normal unsigned genericIOSarm64 Release pass with own DD/SPM/iOS26.5 simulator/jobs4/CODE_SIGNING_ALLOWED=NO, no optimization/testability override. Core2/DS9/Domain10/Data22, four static objects+GRDB each1, frame helper member/definition1 (Release internal/local), WXT GIF3 each1, Metal retained, min15 metadata. Package/Sources modules/pins/resources/all8 configs unchanged. All Swift<=800; AppState Published0. No hardware/iOS15-runtime/performance/whole-stage6 claim.
- One focused union48 all passed/0failed/0skipped confirmed by xcresult; inventory2226, +11/-0. Wire23+page23 had no duplicate case IDs; add direct Core NSError/error-presentation2. No old Store21/DataHTTP10/Directory11/Chat19/fullsuite/51or76/PNG run. No current code/test assertion failure or fixture correction. A stdout parser concatenation and global-only nm inspection assumption corrected from authoritative records without rerun/source changes. Existing approved scoped-binding fixture emitted14 SQLite own-temp teardown diagnostics; retained, not repaired/hidden. Original exact-connect-ACK failure remains under old evidence, unselected/unfixed.
- This private current source connection is validated; original approved wire/page contents are not reopened for private preapproval. Root later releases actual same-cut ordinary commit; same R2 reuses unchanged content approval and reviews current actual connection/differences. No actual source/index/ref/Main/push/sign/physical-device/CI/cloud/SQL/production mutation here. Stores3c55, compute/page/wire/SP1 old packets unchanged; no DirectoryDTO/Composer/compute33/trace additions. Map/merge/sort and whole phase6 remain separate.
- Evidence `/private/tmp/im4-ios1-wire-page-current.4239hmw0/` retains complete source/base, exact mode/blob/hash/delta, approved-current comparison, compiler inputs/products/xcresults/logs/tool-correction/fixture-diagnostic history. Only this index is postbuild metadata. NEW_DEPLOY_SURFACE=0; JENKINS_CHANGE=0; SECRET_PLACEMENT=unchanged; PROD_MUTATION=false; AUTO_ROLLBACK=false.

| File | Current function-marker/PBX exact-ID span |
|---|---|
| `BlueStoneIM.xcodeproj/project.pbxproj` | 11–2751 |
| `BlueStoneIM/Core/AppSupport/AppState+RealtimeMessageExtras.swift` | 17–20 |
| `BlueStoneIM/Core/AppSupport/AppState+RealtimeSequenceRecovery.swift` | 256–268 |
| `BlueStoneIM/Core/AppSupport/AppState+RuntimeBindings.swift` | 166–170 |
| `BlueStoneIM/Core/Networking/DTO/RemoteAuthChallengeModels.swift` | 3–3 |
| `BlueStoneIM/Core/Networking/DTO/RemoteMessageEventModels.swift` | 225–257 |
| `BlueStoneIM/Core/Networking/IMAPIClient+RequestExecution.swift` | 394–403 |
| `BlueStoneIM/Core/Networking/IMAPIClient+ResponseAndLogging.swift` | 6–112 |
| `BlueStoneIM/RealtimeClient+ConnectionLifecycle.swift` | 48–191 |
| `BlueStoneIM/RealtimeClient.swift` | 20–652 |
| `BlueStoneIM/RealtimeFrameDecoder.swift` | 3–94 |
| `BlueStoneIM/RealtimeTransportContracts.swift` | 111–123 |
| `BlueStoneIM/RemoteAPIModels.swift` | 78–271 |
| `BlueStoneIMTests/HTTPGroupAndRTCTransportTestFixtures.swift` | 143–356 |
| `BlueStoneIMTests/PagedSnapshotCommitTests.swift` | 318–428 |
| `BlueStoneIMTests/RealtimeBackgroundDecodeTests.swift` | 6–367 |
| `BlueStoneIMTests/RealtimeTransportTestFixtures.swift` | 711–733 |

<!-- WDT_IOS1_WIRE_PAGE_CURRENT_ASSEMBLY_20261110_END -->

## WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110

- Private only, fixed parent `92439be481f0937d87ffd5e6fba11cd41238a9a3` / IOS tree `238ace04ef6cb04579234261878e1b1c9971b04a`; PARENT_DIRECTORY_DTO_UNREVIEWED_NOT_MAIN at input. No current Main or other candidates mixed in.
- Complete profile/membership pure DTO families (4+6) move to Data, with the sole minimal lifecycle dependency RemoteGroupSettings. App files keep thin aliases; all other lifecycle/mutation DTOs and business policies, permissions/scopes/session/self-store/cache/persistence/mappers/errors/orchestration remain original.
- Paths: original and new NetworkingDTO/RemoteGroupProfileModels.swift, RemoteGroupMembershipModels.swift, RemoteGroupLifecycleModels.swift (only settings); existing NetworkDTOScalarDecoding.swift strict Bool body; exact Data Package members24→27; PBX focused test membership and DataGroupProfileMembershipDTOBoundaryTests.swift. All old marker blocks retained.
- Fields/keys/defaults/alias priority/strict-lossy/Int64/null/unknown/constructors/merge are exact after public-access normalization. All11 immutable DTOs have compiler-checked Sendable to retain the original internal Swift6 inferred safety across existing App async-let/Task consumers and static empty values; no unsafe or actor added. Private helpers/CodingKeys remain internal/private.
- New focused cases cover all11-family boundary values, constructor/omission behavior, >2^53/Int64 precision, strict Bool and count policies, typed actual group/profile/member/announcement/owner APIs and unchanged App projection/error behavior. Original selected consumers remain byte-identical.
- Exact private validation commands/results, complete source/hash/blob/exec, API/compiler inputs/products and reverse patch are retained in the owner private evidence stage. This index is frozen before builds; no postbuild source marker changes. No reviewer approval or integration implied.


<!-- WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110_BEGIN -->
Private stage4 Composer text input boundary, based on unreviewed343 route/row candidate. Replaces Feature AppState reads/commands with App-owned original composition and a consumed pure text/selection/input-actions leaf; current session observation refreshes callbacks and existing scope/login/localgen rejects retired actions. The existing ComposerState owner, UIKit/markedText/UTF16/failed draft merge, original voice/media/sticker behavior and modifiers remain. The four Feature files retain pure tools/owner/editor/panels; remaining Chat dependencies are reported separately, not phase4/5/6 completion. No physical target/dependency/runtime/SQL/network/authority changes.
<!-- WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110_END -->


<!-- WDT_IOS1_REALTIME_COMPUTE_CURRENT_ACTUAL_20261110_BEGIN -->
## WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110 — current actual source adoption

- Actual candidate is an ordinary local single-parent child of fixed Main `5fd06a717382f50c5dbd1596248e08e437a25c26` / IOS tree `ce3afe0a5189bd59b66bce4f810c808a787fc508`. Main's complete existing marker prefix, including `WDT_IOS1_WIRE_PAGE_CURRENT_ASSEMBLY_20261110`, is retained byte-for-byte (prefix SHA256 `223a06fc899a627e765be5e49dc67c0aca7d083cc0e116e93fed03a9d33873dc`). No private wire index is appended or substituted.
- Adopt only frozen current compute36, input patch SHA256 `348a508608b5dcf5e7f462b67b585745035fb030e28567fc52990b22fd00ff5b` from `/private/tmp/im4-ios1-compute-current.5jokwoxv`. The original functional source block markers `WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110` and current structural marker `WDT_IOS1_REALTIME_COMPUTE_CURRENT_ADAPT_20261110` remain unchanged and are the complete merge unit. All727 non-marker source files, including all35 own code/test/PBX paths, equal the private728 candidate byte-for-byte/blob/executable mode; only this append-only noncompiled index differs. Actual IOS tree must be read from actual commit and is not private `af9c38a37fd8927a6ded18c678a73f8ffd630922`.
- The current cut retains original100 approved final methods and16 helper files, checked Sendable worker, original admitted raw groups/one80ms500 buffer and flush task/ACK boundaries, per-window ABA and relevant RTC/identity/calendar tokens, at-most2 worker attempts then original synchronous fallback, no-await Store/F1 atomic frame and original Main side-effect positions. No private Store map hook or new message authority.
- Retain exact whole-block moves of original DEBUG `licenseQuotaRegistrationPrefill` into existing StoreFacades and original `ContactsConversationRoute` into established ContactCommonRows, including DEBUG condition/UUID/fields/init. No View body or stored observer change; all Swift≤800 and AppState793/Published0. Existing Core2/DS9/Domain11/Data24/Stores1/Package/pins/config8/HTTP/Directory/Stores/wire/Row/C1 remain in current parent and unchanged by adoption.
- Reuse private current normal Debug App/allXCTest and unsigned generic iOS arm64 Release/min15/static5+GRDB/WXT/Metal evidence. First focused19 was18pass/1fail at original disk ACK assertion; after adding only projectionRevisionFloor completion barrier, affected original method1/1passed. All original assertions and first failure source/App/XCTest/xcresult remain. No final19/19 execution is claimed. Mounted fixture uses actual current App routing/factory/environment, with no fallback UI.
- Actual build/test/Host/PNG/sign/device/CI/Jenkins/cloud/SQL/prod actions are0. Compiler CWD/#filePath/DWARF and products/results remain from the unchanged private source root; no actual new run is implied. Corrected private App binary equals first failed-execution App; XCTest changed with fixture barrier. Release preceded that test-only barrier and did not compile XCTest.
- Original R2 content approval is reused only for reviewed compute content; this actual current connection is **REVIEW=REQUIRED_IOS_PENDING** and awaits original R2. No self-approval/Main integration/push or phase6/performance closure. Existing readonly private evidence is not rewritten. Source-input/products/results binding and exact commit/trees/full728 manifest/own36 forward and inverse scope are in the owner's ordinary actual handoff.
- No SP1/trace/Group DTO/Composer or other module delta. Rollback scope is only candidate own36 paths relative to fixed Main; no rollback executed. `NEW_DEPLOY_SURFACE=0; JENKINS_CHANGE=0; SECRET_PLACEMENT=unchanged; PROD_MUTATION=false; AUTO_ROLLBACK=false`.

| File | WDT marker lines |
| --- | --- |
| `BlueStoneIM.xcodeproj/project.pbxproj` | 11–2846 |
| `BlueStoneIM/AppState.swift` | 41–383 |
| `BlueStoneIM/ContactsViews.swift` | 7–7 |
| `BlueStoneIM/ConversationStore.swift` | 265–614 |
| `BlueStoneIM/Core/AppSupport/AppState+RealtimeEventDispatch.swift` | 143–423 |
| `BlueStoneIM/Core/AppSupport/AppState+RealtimeSequenceRecovery.swift` | 275–406 |
| `BlueStoneIM/Core/AppSupport/AppState+RuntimeBindings.swift` | 174–178 |
| `BlueStoneIM/Core/AppSupport/AppState+StoreFacades.swift` | 445–458 |
| `BlueStoneIM/Core/AppSupport/AppStateLocalSupport.swift` | 42–130 |
| `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift` | 21–189 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/AppState+RealtimeCompute.swift` | 3–119 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/AppState+RealtimeComputeCapture.swift` | 3–73 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/ConversationDerivationClock.swift` | 3–65 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/ConversationStore+PreparedRealtime.swift` | 3–34 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeComputeRuntime.swift` | 3–61 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeComputeTypes.swift` | 3–84 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeComputeWorker.swift` | 3–122 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeConversationReducer+GlobalRTC.swift` | 3–49 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeConversationReducer+Merge1.swift` | 3–246 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeConversationReducer+Metadata1.swift` | 3–147 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeConversationReducer+State1.swift` | 3–431 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeConversationReducer.swift` | 3–15 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeMessageMapper+Values1.swift` | 3–703 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeMessageMapper+Values2.swift` | 3–671 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeMessageMapper+Values3.swift` | 3–86 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeMessageMapper.swift` | 3–94 |
| `BlueStoneIM/Features/Contacts/ContactCommonRows.swift` | 287–297 |
| `BlueStoneIM/RTCCallRecordMessage.swift` | 471–471 |
| `BlueStoneIM/RealtimeClient+ConnectionLifecycle.swift` | 61–185 |
| `BlueStoneIM/RealtimeClient.swift` | 19–709 |
| `BlueStoneIM/Stores/ConversationStore+RemoteMerge.swift` | 499–505 |
| `BlueStoneIM/Stores/ConversationStore+Types.swift` | 14–506 |
| `BlueStoneIM/Stores/ScopedMessageMemoryStore.swift` | 22–22 |
| `BlueStoneIMTests/RealtimeBackgroundComputeTests.swift` | 7–410 |
| `BlueStoneIMTests/RealtimeBackgroundDecodeTests.swift` | 301–354 |

<!-- WDT_IOS1_REALTIME_COMPUTE_CURRENT_ACTUAL_20261110_END -->

## WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110

- PRIVATE ONLY; fixed parent6a0409378616c4e17cd78634a16dea2010d22919 / IOS38e3f31029fb58d3df91562be9db6d0dc8a7ebf9, PARENT_GROUP11_DTO_UNREVIEWED_NOT_MAIN at input. No actual/Main/ref writes.
- Complete active pure group lifecycle/mutation unit: leave/dissolve preview/result/mute-list, join-request/DND/raw-group/profile-update/group/member values, plus the minimal raw SearchInvalidationEvent and mutation invalidation response. Data27→29; original Data lifecycle file extended, new mutation/search-sync Data files.
- Original App DTO sites become aliases. Search invalidation normalization/removal/dedupe/tenant-reset/payload/removed-conversation projections and private helpers remain original App extension bodies. Mixed create/join/invite responses remain App because they include message-wire/inbox and UI approval/invitation projection. Unused historical settings request stays App; no uncalled public memberwise initializer.
- Existing scalar helpers reused unchanged, CodingKeys/private helpers hidden, only existing cross-module consumed constructors/accessors public. Original inferred immutable Sendable is preserved with compiler checking; no unsafe/actor/queue/fence/refcount/authority/cache change. All field types/order/defaults/aliases/strict-lossy/Int64/errors/opaque HTTP/body/query/scope/permissions/store side effects preserved.
- Files: App DTO lifecycle/mutation/search-sync sites; corresponding Data files; exact Package source members; new DataGroupLifecycleMutationDTOBoundaryTests.swift and PBX test membership. Existing Core/DS/Domain/Data27/Group11/1219 API/GRDB7.11.1/pins/resources/Metal/WXT/schema/Keychain/8configs preserved.
- Exact complete source/hash/blob/execute cut, focused results/normal build products, before/after Foundation family comparison, failures/limits and own reverse delta are retained in the owner private packet. This source index is frozen before validation; no private review approval or Main integration implied.


<!-- WDT_IOS1_SIGNPOST_CURRENT_CONNECTION_20261110_BEGIN -->
## WDT_IOS1_SIGNPOST_CURRENT_CONNECTION_20261110

- Private current SP1 connection on fixed actual `5fceac898f39069ec71d613be518c2c1ab3c4e75`, fulltree `c12578222ba5e2a2b3a38889ebcc901190454cbf`, IOS tree `13aeffffb84d78f0fa74e79a518cd4568eb57cd0`. Input status remains **COMPUTE_CURRENT_UNREVIEWED_NOT_MAIN_AT_INPUT**. No Main chasing or actual/ref/commit/push/build lane mutation.
- Reuse corrected approved complete13 SP1 content SHA256 `a1c48ce7187b8f5b6a9c24b033996cb5ff5a20eeba0bdfdc968559064cf98bfa` and SP1-only4 `5d0469c281be7df1de7cefa22c09df61f66a34c2027424b765eae4935a30f210`; R2 source-content approval SHA256 `202b27cb3d85878dd0ca6b51fd37f41497113efb8c81d8782464c75944a532a6`. Old roxc NEEDS_FIX/negative and corrected positive11 stay untouched under their original identities. No new private preapproval or self-approval.
- Original helper and take-and-clear observation are exact approved bytes. Sync and serial App ingress take-clear before begin/callback/await; Main buffer/work groups carry diagnostics beside existing messages, never into worker inputs or business IDs/authority. Current atomic Store stages diagnostics only when its final frame enters original FIFO and finishes them after outer command/publication. Original mapping100 functions and47 module source files unchanged. Existing admitted raw retention/ACK/credential/scope/retry/max2+sync fallback/side effects keep their original order and branches.
- New normal Debug App/allXCTest and ordinary unsigned generic iOS arm64 Release succeeded; Core2/DS9/Domain11/Data24/Stores1, static5+GRDB/WXT/Metal, Package/pins/config8/resources/min15 retained. Current focused10/10 passed from inventory2247. SP1 original assertions execute both real native worker route and explicit legacy onEnvelope replacement with active original SDK observation; Store callback B gets independent fresh flow. Current mounted route uses real App factory; original disk assertions preserved with public projection-completion fixture wait.
- Current worker flow20/21 and legacy24/25 each emit arrival/install/projection/terminal once, revisions3/4. Both current business attachments SHA256 `563c2642e6f4db9c445c03ff6e5dfbbc4c933c454747dd9e02697897159a8716`: sequences1/2/3, sent, unread0, covered3, no pending outbox/extra send traffic. Projection endpoint is not a drawn/visible/read proof. Disabled allocation/time, startup/hitch/performance and broader phase6 are unmeasured/incomplete.
- Exact current adaptations vs original13, source/blob/mode manifest, full own14 delta, compiler/products/xcresult/attachments and rollback live in `/private/tmp/im4-ios1-signposts-current.o06a557v`. Only CHANGE_MARKERS is appended after compilation. Current connection remains **REVIEW=REQUIRED_IOS_PENDING**; actual same-cut adoption needs later root release and original R2 review. No SP1 old snapshot/Group/Composer/attachment delta is mixed.
- `NEW_DEPLOY_SURFACE=0; JENKINS_CHANGE=0; SECRET_PLACEMENT=unchanged; PROD_MUTATION=false; AUTO_ROLLBACK=false`. No actual commit/ref/Main/push/sign/real device/CI/Jenkins/cloud/SQL/prod writes; no cache/DB clearing or runtime rollback.

| File | WDT lines |
| --- | --- |
| `BlueStoneIM.xcodeproj/project.pbxproj` | 662–2524 |
| `BlueStoneIM/ConversationStore.swift` | 1–796 |
| `BlueStoneIM/Core/AppSupport/AppState+RealtimeEventDispatch.swift` | 1–507 |
| `BlueStoneIM/Core/AppSupport/AppState+RealtimeSequenceRecovery.swift` | 1–436 |
| `BlueStoneIM/Core/AppSupport/AppStateLocalSupport.swift` | 1–354 |
| `BlueStoneIM/Core/AppSupport/MessageMapping/AppState+RemoteMessageApply.swift` | 1–664 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/AppState+RealtimeCompute.swift` | 1–124 |
| `BlueStoneIM/Core/AppSupport/RealtimeMessageFlowSignposts.swift` | 4–116 |
| `BlueStoneIM/Features/Chat/ChatViewTimeline.swift` | 1–697 |
| `BlueStoneIM/RealtimeClient.swift` | 1–761 |
| `BlueStoneIM/RealtimeConnectionDiagnostics.swift` | 1–198 |
| `BlueStoneIM/Stores/ScopedMessageMemoryStore.swift` | 1–243 |
| `BlueStoneIMTests/ScopedMessageMemoryTests.swift` | 417–735 |

<!-- WDT_IOS1_SIGNPOST_CURRENT_CONNECTION_20261110_END -->


<!-- WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_BEGIN -->
## WDT_IOS1_STORES_MESSAGE_MEMORY_20261110

- Private closed message-memory module on fixed actual `4c8874763fde9b2ca91c0e19ffbf84340e2c8263` / IOS `ef00d27cdffb88040aed3d69bc807bf35b02c2b5`, status **COMPUTE_SP1_UNREVIEWED_NOT_MAIN_AT_INPUT**. No Main/actual/ref/commit/push mutation or parent approval implied.
- Move full original normalized cell/frame, scoped observers, command/atomic/pending FIFO/install/publication, per-window/RTC derivation tokens, lookup cache and latest-tail pending/pinned retention into IM4Stores. App ConversationStore/AppState keep sole instance/authority entry,5 original Published fields/order, mapping/read/network/persistence/global RTC policies and side effects. App has aliases/delegates, no shadow state/window maps.
- IM4Stores6 sources (original ContactStore preserved) depends Domain and existing Data LocalMessageScope. Domain12 adds original7-field RTC Authority pure value;3 consumed getters public/4 fields internal. All original47 module sources remain byte-identical; Package wiring only and test PBX2objects/2memberships; pins/config8/resources/schema/keys/errors unchanged. Scope/binding/stamp construction stays original owner with private maps and opaque stamp query/matches, no extra generation/revision gate.
- Store-owned synchronous diagnostic handles carry only explicit stage/install/projection callbacks; OSLog/App flow stays App and its12 original bodies remain exact. Pure RTC extractor stays App. No App class/Any container/reverse import, new business await/queue/timer/cache authority, unchecked/unsafe isolation or iOS17 API.
- New normal Debug App443/allXCTest161 and ordinary unsigned generic arm64 Release/min15 passed; static5+GRDB/WXT/Metal single links, real memory classes exist only in IM4Stores. Initial module compile failed explicit ObservableObject isolation; original Scoped non-Observable role restored via narrow synchronous metadata signal at original F1 phase. Failure source/partial products/build xcresult retained.
- This module's focused19 (2new+7scope/F1+2retention+5compute/ACK+3SP1; not original compute19) first18pass/1fail: new App identity fixture used isolated nil scope fields. Original scope/window assertions preserved; fix only fixture to original authenticated context + unique account, rebuildDebug and targeted1/1pass. No final19 rerun. Initial failure/source/App/XCTest/xcresult retained; corrected App binary identical, XCTest changed. Normal Release production inputs unaffected by test-only correction.
- Current same-host native worker/explicit legacy SP1 each has2 independent A/B flows, arrival/install/projection/terminal once, business controls equal. Projection is not drawn/visible/read proof; disabled allocation/time and phase6/full plan/performance remain unmeasured/incomplete.
- Fixed input contains no named MemoryMessageStore or message-window budget/lease API. None invented or claimed tested; original retention/read/selection/scope contracts retained. Other App Stores/business policies remain App; whole Stores/Features goal not closed.
- Complete source/blob/mode, own delta,29-method map + constructors/fields,100 logical compute maps,12 SP1 bodies, public necessity/call map, raw failures/builds/products/native results and rollback: `/private/tmp/im4-ios1-memory-stores.b357uvc3`. Only this noncompiled index changes after builds. Later root actual same-cut release, original R2 first full new-module/current-connection review, original R7 integration; no private preapproval/self-approval.
- `NEW_DEPLOY_SURFACE=0; JENKINS_CHANGE=0; SECRET_PLACEMENT=unchanged; PROD_MUTATION=false; AUTO_ROLLBACK=false; REVIEW=REQUIRED_IOS_PENDING`. No signing/real-device/CI/Jenkins/cloud/SQL/production action or data clearing.

| File | Current marker lines / unit |
| --- | --- |
| `BlueStoneIM.xcodeproj/project.pbxproj` | exact2 test file/build objects +2 memberships |
| `BlueStoneIM/ConversationStore.swift` | 243–288 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/ConversationDerivationClock.swift` | 1–17 |
| `BlueStoneIM/Core/AppSupport/RealtimeCompute/ConversationStore+PreparedRealtime.swift` | 22–22 |
| `BlueStoneIM/Core/AppSupport/RealtimeMessageFlowSignposts.swift` | 9–23 |
| `BlueStoneIM/RTCCallRecordMessage.swift` | 472–472 |
| `BlueStoneIM/Stores/ConversationStore+History.swift` | 461–461 |
| `BlueStoneIM/Stores/ConversationStore+Types.swift` | 15–15 |
| `BlueStoneIM/Stores/ScopedMessageMemoryStore.swift` | 1–60 |
| `BlueStoneIMTests/MemoryStoresBoundaryTests.swift` | 6–81 |
| `Package.swift` | exact Package target source/dependency additions |
| `Sources/IM4Domain/RTCCallRecordAuthority.swift` | 1–23 |
| `Sources/IM4Stores/ConversationMemoryDerivation.swift` | 1–63 |
| `Sources/IM4Stores/ConversationMemoryFrame.swift` | 1–125 |
| `Sources/IM4Stores/MessageMemoryDiagnostic.swift` | 1–38 |
| `Sources/IM4Stores/MessageWindowRetention.swift` | 1–40 |
| `Sources/IM4Stores/ScopedMessageMemoryStore.swift` | 1–299 |

<!-- WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_END -->


## WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110

- Private fixed base 5fceac898f39069ec71d613be518c2c1ab3c4e75 plus semantic Group prefixes 92439..6a040..8c6fd. Input status: COMPUTE5FCE_GROUP6A040_LIFECYCLE8C6FD_UNREVIEWED_NOT_MAIN_AT_INPUT.
- Extract 19 pure conversation/message/event/receipt/JSONValue DTOs into IM4Data. Retain original App aliases, message projections, Foundation Any bridge, Loader, RealtimeEnvelope, codec/compute/session/permission/persistence orchestration.
- Preserve ordered fields, mutability, CodingKeys, decoder branches, defaults, aliases, Int64 and strict Bool. Only new explicit public constructor reproduces RemoteConversationPage former implicit memberwise initializer used by existing callers. Checked Sendable values only.
- Extend existing Package Data source list; PBX, five modules, entire wire/page/compute and preceding prefixes remain intact. No deployment/Jenkins/secrets/production changes.
- `Package.swift`: complete marked blocks; exact line navigation is in packet change-marker-locations.json.
- `BlueStoneIM/RemoteAPIModels.swift`: complete marked blocks; exact line navigation is in packet change-marker-locations.json.
- `BlueStoneIM/Core/Networking/DTO/RemoteMessageEventModels.swift`: complete marked blocks; exact line navigation is in packet change-marker-locations.json.
- `BlueStoneIM/Core/Networking/DTO/RemoteConversationModels.swift`: complete marked blocks; exact line navigation is in packet change-marker-locations.json.
- `BlueStoneIM/Core/Networking/DTO/RemoteMessageReceiptModels.swift`: complete marked blocks; exact line navigation is in packet change-marker-locations.json.
- `BlueStoneIM/Core/Networking/DTO/RemoteMessageModels.swift`: complete marked blocks; exact line navigation is in packet change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/RemoteMessageEventModels.swift`: complete marked blocks; exact line navigation is in packet change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/JSONValue.swift`: complete marked blocks; exact line navigation is in packet change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/RemoteConversationModels.swift`: complete marked blocks; exact line navigation is in packet change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/RemoteMessageReceiptModels.swift`: complete marked blocks; exact line navigation is in packet change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/RemoteMessageModels.swift`: complete marked blocks; exact line navigation is in packet change-marker-locations.json.
- Frozen before compilation. Validation, hashes and patches are recorded in private packet /private/tmp/im4-ios1-data-conversation-events-private.ntysdmy1. Actual writer, original R2 review and integration remain pending root release.
- Internal dependency closure: copy the existing App decodeLossyStringIfPresent body unchanged into Data NetworkDTOScalarDecoding.swift; original App helper remains for unmoved consumers. First compile failure and its complete source/partial products are retained in first-debug-missing-scalar. No decoder or assertion change.


## WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110

- Fixed private input b93383682b3248934ba91ca591cf7b908107716f (740 files). Status at input: COMPUTE5FCE_LIFECYCLE8C6FD_MESSAGEB933_UNREVIEWED_NOT_MAIN_AT_INPUT. Group6a040 later Main status is separate; no prior history rewritten.
- Extract six token-free account/profile wire DTOs (62 stored fields) into existing IM4Data: RemoteAccount, RemoteIMUser, RemoteMeProfile, RemoteAccountCancellationResponse, RemotePasswordChangeResponse, RemotePasswordResetResponse. App keeps aliases and all mapping/selection/login/Keychain/token/permission/IO/error/retry authority.
- Exact original decoder fields, CodingKeys, aliases, defaults, failure behavior, numeric handling retained. Checked Sendable only. No new constructor or public helper. Two existing flexible Bool functions copied unchanged as internal Data dependencies; originals remain App.
- `BlueStoneIM/Core/Networking/DTO/RemoteAccountModels.swift`: complete marked blocks; exact line navigation in private packet.
- `BlueStoneIM/Core/Networking/DTO/RemoteLoginModels.swift`: complete marked blocks; exact line navigation in private packet.
- `Package.swift`: complete marked blocks; exact line navigation in private packet.
- `Sources/IM4Data/NetworkingDTO/NetworkDTOScalarDecoding.swift`: complete marked blocks; exact line navigation in private packet.
- `Sources/IM4Data/NetworkingDTO/RemoteAccountMutationResponseModels.swift`: complete marked blocks; exact line navigation in private packet.
- `Sources/IM4Data/NetworkingDTO/RemoteAccountProfileIdentityModels.swift`: complete marked blocks; exact line navigation in private packet.
- PBX, five-module topology, resources/settings, prior19 message DTOs and Compute/Group/Lifecycle remain unchanged. Private-only; original R2 required before any integration. No actual/ref/control write, deployment/Jenkins/secret-placement/production mutation.
- Source index frozen before compilation. Validation and own patch are in /private/tmp/im4-ios1-data-auth-profile-private.m5p9mez4; no new token fixtures.


## WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110

- Fixed private input78cc71056b80cc250ef2281af45d35345a767570 (742 files). Input status: COMPUTE_LIFECYCLE_MESSAGE_ACCOUNT_PREFIX_UNREVIEWED_NOT_MAIN_AT_INPUT. Group/Composer later Main facts remain separate. No prior history rewritten.
- Extract the complete eight-type raw challenge/verification response closure (67 original fields) into existing IM4Data. JSONValue and all necessary scalar helpers already exist in Data;no helper added.
- App retains eight aliases,entry preference/normalization/unavailable-message policies and original mixed SlideCaptchaTicket/SlideCaptchaVerifyRequest with Any/SDK/Foundation bridge. App session/refresh/lifetime/tenant/Keychain/IO/error/gates unchanged.
- Preserve original decoder branches,keys,strict/lossy/default/error behavior. Checked Sendable only;no new memberwise constructor,policy helper or unchecked wrapper.
- `BlueStoneIM/Core/Networking/DTO/RemoteAuthChallengeModels.swift`: complete marked blocks;exact lines recorded in private change-marker-locations.json.
- `Package.swift`: complete marked blocks;exact lines recorded in private change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/RemoteAuthChallengeModels.swift`: complete marked blocks;exact lines recorded in private change-marker-locations.json.
- PBX,module topology,pins,resources,settings and all preceding message/account/compute/group/lifecycle source remain intact. Package adds one necessary Data source member.
- Index frozen before build. Private validation,own patch and results: /private/tmp/im4-ios1-data-challenge-private.4icr6ibp. No real token/key/challenge fixture. REVIEW=REQUIRED_IOS_PENDING;no actual adoption authorized.


## WDT_IOS1_STICKER_STATE_FAMILY_20261110

PRIVATE ONLY / REVIEW REQUIRED. FixedMain ec790074f981f9d485eb85ef2e7cf93003e4a02d preserves Data29. Complete StickerStore/StickerMessageAssetStore storage/defaults/commands/cache/upload/asset observation bodies move to IM4Stores; same AppState instances via aliases, no relay/shadow/copy-back. Pure library/cache/draft values and original Codable move to Domain; original remote DTO mapping stays App extensions. Package adds two real sources; PBX/resources/UI unchanged. Scope legacy cache key/defaults and App auth/generation policy remain unchanged; full five-tuple scope goal remains pending root coordination. Paths and exact ranges are in frozen private family source manifest/line map; normal builds and six original focused required; no actual adoption/Main or parent Features refresh.


## WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110

- Private exact4da912cfeb92c60e66cc74e536dc0f7c06524165 input743. All prior packets/actual/index/objects/refs/Main remain read-only. Read-only boundary inventory: /private/tmp/im4-ios1-data-boundary-inventory.9aupfye0/READONLY-HANDOFF.json.
- Fullsession/login/refresh/tenant/workspace family:28 originalData value models,278 originalfields;12 originalpure codecs inData and16 originalmixed Decodable adapters inApp. No shadowmodel/session/Anycontainer/unsafe/authorityowner.
- App mixedinit uses typedlocals plus one necessary Data full-field initializer. Original conditional/lazy/error order,authselection,logo/admission rules,policy helpers and allIO/Keychain/restore behavior stayApp. SharedDomain lifetime mode retains originalcases/Codable/rawparser;actual lifetime enforcement staysApp.
- Originalexplicitconstructors/defaults/keys/letvar/encoding andscope/ticket/callbacks preserved. Data existing1693public andalloriginal2257tests retained;normalcut verification evidence follows in private packet.
- `BlueStoneIM/Core/Networking/DTO/RemoteAuthSessionModels.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `BlueStoneIM/Core/Networking/DTO/RemoteLoginModels.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `BlueStoneIM/Core/Networking/DTO/RemoteTenantMembershipModels.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `BlueStoneIM/Core/Networking/DTO/RemoteWorkspaceAccessModels.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `BlueStoneIM/Core/Storage/IMAPIContext.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `BlueStoneIM/RuntimeRouteModels.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `Package.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/AuthSessionWireModels.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/EnterpriseEntryWireModels.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/LoginWireModels.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/RuntimeRouteWireModels.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/StoredAuthSessionWireRecord.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/TenantMembershipWireModels.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `Sources/IM4Data/NetworkingDTO/WorkspaceMutationWireModels.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- `Sources/IM4Domain/IMSessionLifetimeMode.swift`: complete marked blocks;originalbody/field mapping andexact lines in family-mapping.json/change-marker-locations.json.
- Package adds7Data sources+1Domain source only;no PBX,target,dependency,pin,resource,identity/config changes. Index frozen before compilation. No actual adoption,review/Main/push/CI/prod action.
- Validation and rollback evidence: /private/tmp/im4-ios1-data-session-family-private.s28pg_qu. Thisfamily is not wholeData/Stores/Features/phase4/5/6 completion.
- First compile retained under first-debug-cut. RemoteTenantEnterResult decoder references App hasTenantAPIBaseURL;its originaldecoder now staysApp (same condition/lazyorder),not a new Data helper. Original RemoteApp(appID:) fallback has an explicit publicequivalent constructor because its formerlyimplicit memberwise initializer mustcross the module boundary. No business/default/assertion change.
- Source-generator correction:second debug cut compiledsuccessfully but repeatedPackage source members were found. Its exactsource/log/products are retained under first-success-duplicate-package-members. Final Package is rebuilt fromimmutablebase and adds each member once;no model/branch/default/assertion changed. Final normalbuild binds this exactsource cut.

<!-- WDT_IOS1_ATTACHMENT_DETAIL_PREVIEW_BOUNDARY_20261110_BEGIN -->
- 固定输入：Composer710，COMPOSER_PREFIX_UNREVIEWED_NOT_MAIN；db1f 是相同 cut 的实际来源锚点，不追 Main。
- 详情、进度、错误、预览、手势和原 AV/QuickLook 展示保留在 Feature；App 组装纯值、命名动作及窄渲染插槽，持有原下载、缓存、权限、保存/分享和导航服务。
- 复用原 FileStore 单消息观察和 F4 会话绑定/身份刷新；不新增 authority、queue、cache、强制 remount 或物理 Features target。
- 原 Composer/输入桥/Bindings、网络/Domain/Core/Stores、选择流程、Package/pins 与配置保持；仅本附件单元独立验证，历史证据不重跑。
<!-- WDT_IOS1_ATTACHMENT_DETAIL_PREVIEW_BOUNDARY_20261110_END -->

## WDT_IOS1_ATTACHMENT_DISMISS_ADMISSION_20261110

- 原 R2 确认 P2（正式 finding 编号待报告）：F4 拒绝的图片预览关闭不再消耗 Feature 一次性关闭状态；已接纳关闭保持防重入与单次完成。
- `BlueStoneIM/Features/Chat/ChatAttachmentPreview.swift`：`AttachmentImagePreviewActions.dismiss` 返回接纳 Bool；`requestDismissal` 先锁，拒绝时由原 coordinator 恢复相同 trigger；布局/文本/手势阈值与 policy 不变。
- `BlueStoneIM/App/ChatAttachmentPreviewAssembly.swift`：原完整 F4 guard 未变，通过后调用原 dismiss 并返回 true，拒绝返回 false；原 save/permission/已接纳系统 completion 不变。
- `BlueStoneIMTests/AttachmentDetailBoundaryTests.swift`：原测试前缀不变；新增真实 Feature cancel 快捷键同 host 旧拒绝→当前关闭一次回归，及四种原 trigger 的拒绝恢复/已接纳单次状态回归；无新增产品测试 hook。

## WDT_IOS1_ATTACHMENT_REJECTED_DRAG_RECOVERY_20261111

- 正式 P2 `IOS1-ATTACHMENT-REJECTED-DRAG-PRESENTATION`：原 F4 拒绝后的同 host 图片预览，匹配 latch 释放时用原 snap-back spring（0.28/0.86）恢复真实 `dismissalOffset = .zero`；保留受理前防重入锁及受理后一次完成。
- `BlueStoneIM/Features/Chat/ChatAttachmentPreview.swift`：false-admission 最小复位；原实际 onChanged/onEnded policy 原体提取为同函数内共享 caller，供实际 DragGesture 和 internal DEBUG 被动观察共同使用；无新 public API/hook，布局/scale/阈值/原 accepted completion 不变。
- `BlueStoneIMTests/AttachmentDetailBoundaryTests.swift`：原386整文件前缀保留；新增实际安装的 production State/caller 在 viewport390、startX5、translation380 下旧 F4 拒绝→同 retained preview 状态与像素复位→fresh 关闭一次回归；状态层驱动，不冒称 OS touch/drag。
- 原 new latch finding 已由 R2 CLOSED；新 drag finding 仍须原 R2 针对复审。固定输入 actual386；未写 actual/Main；所有 RED/原制品/旧像素留各自 source cut。
- 当前行区间导航：`BlueStoneIM/Features/Chat/ChatAttachmentPreview.swift` 225–265（共享实际 caller）、266–275（拒绝复位）、399–文件末（internal DEBUG 被动观察）；`BlueStoneIMTests/AttachmentDetailBoundaryTests.swift` 559–659（原生 State/render/同 host 回归），其中测试入口 581。行号仅供导航，以统一 WDT 标识和完整差分为准。


## WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110

完整RTC33关联族：27 Data记录/5 Domain值/App ICE错误；原策略、VoIP字典与freshness、ICE错误和redial guard保留原App。基于固定Main2b6+session28最小投影；不覆盖MemoryDomain/Store6。private only，待原R2独审。

文件：5原RTC DTO App适配、5新Data wire文件、Domain RTCWireValues、Package成员与本索引。源映射/预算/正常构建/真实消费者与Host结果见独立私有交接；不以编译替代运行或全Data验收。


## WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111

完整搜索16定义：11公开Data原记录、2私有Data原helper；DisplayModel/Guard/分页留App。原Identifiable投影/displayTitle、日期跳转目标与analytics body仍App；不新增Domain枚举、导航、URI/scope/权限或查询合同。固定RTC775技术prefix，仅private，待原R2未来完整actual审。

- `BlueStoneIM/Core/Networking/DTO/RemoteSearchResultModels.swift`：完整标识块 1,327；当前共327行。
- `BlueStoneIM/Core/Networking/DTO/RemoteSearchSyncModels.swift`：完整标识块 1,264；当前共264行。
- `Sources/IM4Data/NetworkingDTO/SearchResponseWireModels.swift`：完整标识块 1,205；当前共205行。
- `Sources/IM4Data/NetworkingDTO/SearchResultWireModels.swift`：完整标识块 1,221；当前共221行。
- `Sources/IM4Data/NetworkingDTO/SearchConversationWireModels.swift`：完整标识块 1,97；当前共97行。
- `Package.swift`：完整标识块 282,286；当前共308行。

依赖现有Data RemoteMessage/JSONValue/scalarcodec和原App SearchInvalidation映射；Package仅登记3Data源，保MainMemory/Stores6及RTC/session技术prefix。补丁定位：本私包 search-own7-vs-prefix.patch；scope/字段/方法/公有API、正常构建/原生合同/相关consumer及失败cut结果见本私包最终PRIVATE-HANDOFF.json。采用前只按完整标识块组合，须原R2独审，不以本族当全Data或运行验收。


## WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111

Private candidate: move remaining ready pure Networking DTO wire records and necessary Account/Notification raw values to Data/Domain. App policy, display, route/permission/SDK/IO and mixed codec witnesses stay in their original App files. Full fields, constructors, codec order, consumers and retained blockers are recorded in the external private packet; no Main/runtime approval is implied.

- `BlueStoneIM/Core/Networking/DTO/RemoteAccountModels.swift`: `WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN/END` contains original-name aliases and exact App policy/codec extensions.
- `BlueStoneIM/Core/Networking/DTO/RemoteAppPolicyModels.swift`: `WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN/END` contains original-name aliases and exact App policy/codec extensions.
- `BlueStoneIM/Core/Networking/DTO/RemoteBootstrapModels.swift`: `WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN/END` contains original-name aliases and exact App policy/codec extensions.
- `BlueStoneIM/Core/Networking/DTO/RemoteDeviceNotificationModels.swift`: `WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN/END` contains original-name aliases and exact App policy/codec extensions.
- `BlueStoneIM/Core/Networking/DTO/RemoteDirectoryModels.swift`: `WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN/END` contains original-name aliases and exact App policy/codec extensions.
- `BlueStoneIM/Core/Networking/DTO/RemoteFileModels.swift`: `WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN/END` contains original-name aliases and exact App policy/codec extensions.
- `BlueStoneIM/Core/Networking/DTO/RemoteFilePolicyModels.swift`: `WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN/END` contains original-name aliases and exact App policy/codec extensions.
- `BlueStoneIM/Core/Networking/DTO/RemoteGroupMutationModels.swift`: `WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN/END` contains original-name aliases and exact App policy/codec extensions.
- `BlueStoneIM/Core/Networking/DTO/RemoteInviteModels.swift`: `WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN/END` contains original-name aliases and exact App policy/codec extensions.
- `BlueStoneIM/Core/Networking/DTO/RemoteLegalModels.swift`: `WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN/END` contains original-name aliases and exact App policy/codec extensions.
- `BlueStoneIM/Core/Networking/DTO/RemoteMessageModels.swift`: `WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN/END` contains original-name aliases and exact App policy/codec extensions.
- `Sources/IM4Data/NetworkingDTO/AccountPolicyWireModels.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/AppPolicyWireRecord.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/BootstrapWireRecord.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/DeviceNotificationWireModels.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/DirectoryPageWireModels.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/GroupFileWireModels.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/FavoriteFileWireModels.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/UserFileWireModels.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/SplashWireRecord.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/GroupCreationWireModels.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/InviteReviewWireModels.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/LegalDocumentWireRecords.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/MessageMutationWireModels.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Data/NetworkingDTO/NetworkDTOStrictScalarDecoding.swift`: original wire storage/constructors/codecs.
- `Sources/IM4Domain/AccountNotificationWireValues.swift`: five original raw enums only.
- `Package.swift`: explicit Data/Domain source entries.

Validation: normal Debug App/all-XCTest first pass; unsigned generic arm64 Release first pass (minimum iOS 15). Native 1,973 cases / 42 original contract roots valid and nonempty: 1,556 values + 417 errors, zero semantic differences; two raw private reflection-address differences retained separately. Focused 83 identities: evidence combines 79 console outcomes with an official 4-case supplement (79 pass / 4 baseline-reproduced failures); both full83 attempts failed to seal result bundles, so no single official83/all-green claim. Independent exact786 prefix official8 = 4 pass / 4 same first-assertion failures. OPEN findings and all cuts remain in the external private packet. Rollback: reverse only this own28 patch against immutable prefix786; no actual/Main/control writes or review approval.

Navigation for this marker (current line ranges; full blocks must be applied together):
- `BlueStoneIM/Core/Networking/DTO/RemoteAccountModels.swift`: 18–94, 96–98.
- `BlueStoneIM/Core/Networking/DTO/RemoteAppPolicyModels.swift`: 5–27, 29–424.
- `BlueStoneIM/Core/Networking/DTO/RemoteBootstrapModels.swift`: 4–474.
- `BlueStoneIM/Core/Networking/DTO/RemoteDeviceNotificationModels.swift`: 6–8, 10–12, 14–78, 80–82, 84–86, 88–90, 92–94, 96–98, 100–102, 104–106, 108–110, 112–114.
- `BlueStoneIM/Core/Networking/DTO/RemoteDirectoryModels.swift`: 6–107, 109–111.
- `BlueStoneIM/Core/Networking/DTO/RemoteFileModels.swift`: 4–19, 21–23, 25–35, 37–39, 41–43.
- `BlueStoneIM/Core/Networking/DTO/RemoteFilePolicyModels.swift`: 4–71.
- `BlueStoneIM/Core/Networking/DTO/RemoteGroupMutationModels.swift`: 10–22, 36–38, 40–62.
- `BlueStoneIM/Core/Networking/DTO/RemoteInviteModels.swift`: 4–40, 85–87, 89–128, 130–132.
- `BlueStoneIM/Core/Networking/DTO/RemoteLegalModels.swift`: 55–104, 106–170.
- `BlueStoneIM/Core/Networking/DTO/RemoteMessageModels.swift`: 18–20, 22–24, 26–28, 30–32, 34–36.
- `Package.swift`: 192–194, 226–241.
- `Sources/IM4Data/NetworkingDTO/AccountPolicyWireModels.swift`: 4–339.
- `Sources/IM4Data/NetworkingDTO/AppPolicyWireRecord.swift`: 4–78.
- `Sources/IM4Data/NetworkingDTO/BootstrapWireRecord.swift`: 4–210.
- `Sources/IM4Data/NetworkingDTO/DeviceNotificationWireModels.swift`: 4–377.
- `Sources/IM4Data/NetworkingDTO/DirectoryPageWireModels.swift`: 4–89.
- `Sources/IM4Data/NetworkingDTO/FavoriteFileWireModels.swift`: 4–188.
- `Sources/IM4Data/NetworkingDTO/GroupCreationWireModels.swift`: 4–136.
- `Sources/IM4Data/NetworkingDTO/GroupFileWireModels.swift`: 4–248.
- `Sources/IM4Data/NetworkingDTO/InviteReviewWireModels.swift`: 4–336.
- `Sources/IM4Data/NetworkingDTO/LegalDocumentWireRecords.swift`: 4–68.
- `Sources/IM4Data/NetworkingDTO/MessageMutationWireModels.swift`: 4–215.
- `Sources/IM4Data/NetworkingDTO/NetworkDTOStrictScalarDecoding.swift`: 3–20.
- `Sources/IM4Data/NetworkingDTO/SplashWireRecord.swift`: 4–71.
- `Sources/IM4Data/NetworkingDTO/UserFileWireModels.swift`: 4–224.
- `Sources/IM4Domain/AccountNotificationWireValues.swift`: 3–36.

## WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110

- 原完整范围 187 个真实 AppState 成员 + 5 个整对象传递 =192；52 个原业务/IO/导航引用归 App，135 个 UI 消费改窄值及具名动作。12 整文件闭合，并仅处理 Layout4/Timeline7；余65/7原范围保留，不借改名统计。
- 9 App assembly/action 文件、2 Feature 值/动作文件和2测试文件；原方法/服务/DTO/Store/Memory/SDK权威及 accepted completion 保留。新操作复用既有 F4 binding；UI一次锁拒绝恢复 Bool，不增加权威或统一服务包。
- 本次新私有 copy 技术前缀对齐冻结 drag actual305；原 Header/Attachment/drag主体现有字节及 PBX旧对象/配置/顺序保留。未借 Core physicalFeatures/FileStore/Calls 或 A RTC/Search/DTO可变包。
- 正常 Debug +全部171 XCTest源文件编译通过；正常 unsigned generic arm64 Release15/-O/WMO/jobs4通过。最终 selected16=actual16=PASS16/skip0；真实原UI与候选13对像素全部0差异。早期5pass2fail及本轮编辑fixture缺原policy许可失败均保留；合法续期、原editEnabled前提补齐，所有旧断言/服务/超时不弱化。
- 非纯生产差分1706行；含测试/PBX2180行。1367行原体纯移动有逐块原/新路径、范围、原文及hash证据；修改Swift最长664，View builder最长146。phase0–6、全套100%测试、iOS15真机/同签升级及性能仍未完成。
- 此 marker 不编译、不嵌入 App；较早 as-run→文档追加切片另行保留，最终正常构建/原生执行绑定包含 marker 的完整当前源码。独立可见R2审查仍required，不自批、不整合Main/actual、不push/签名/安装/CI/云/SQL/生产。
- `BlueStoneIM.xcodeproj/project.pbxproj`：仅13新Swift的26对象/四类引用共+52行，无删除及配置改写。

当前源码导航：
- `BlueStoneIM/App/ChatMessageInteractionAssembly.swift`：当前 1–600 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/App/ChatMessageSheetAssembly.swift`：当前 1–123 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/App/ChatReceiptAssembly.swift`：当前 1–46 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/App/ChatReactionAssembly.swift`：当前 1–183 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/App/ChatForwardAssembly.swift`：当前 1–81 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/App/ChatPinnedAnnouncementAssembly.swift`：当前 1–75 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/App/ChatAttachmentActions.swift`：当前 1–390 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/App/ChatPresentationAssembly.swift`：当前 1–165 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/App/ChatNavigationActions.swift`：当前 1–452 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatMessageSurfaceInputs.swift`：当前 1–36 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatConversationSurfaceInputs.swift`：当前 1–131 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatAttachmentSelection.swift`：当前 1–171 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatConversationSheets.swift`：当前 1–527 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatForwardViews.swift`：当前 1–437 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatHistorySearchViews.swift`：当前 1–662 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatHistorySupportViews.swift`：当前 1–262 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatMessageActionViews.swift`：当前 1–633 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatViewAttachmentActions.swift`：当前 1–4 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatViewLayout.swift`：当前 1–351 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatViewNavigation.swift`：当前 1–4 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatViewReply.swift`：当前 1–41 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ChatViewTimeline.swift`：当前 1–664 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/MessageActionSheets.swift`：当前 1–331 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ReactionPickerView.swift`：当前 1–128 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIM/Features/Chat/ReadReceiptSheet.swift`：当前 1–350 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIMTests/ChatSecondarySurfaceBoundaryTests.swift`：当前 1–332 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。
- `BlueStoneIMTests/ChatSecondarySurfaceOriginalReference.swift`：当前 1–90 行导航；真实改动及原体对应以 own patch 与 complete192 mapping 为准。

## WDT_IOS1_SECONDARY_RECEIPT_ROW_SNAPSHOT_20261111

- 原R2正式NEEDS_FIX：`IOS1-SECONDARY-RECEIPT-ROW-NAME-COLLISION`、`IOS1-SECONDARY-SOURCE-CONTRACT-TEST-REGRESSION` 保留原编号；只在独立private副本修复，旧e014/旧787及全部原结果冻结。
- `App/ChatReceiptAssembly.swift`：对每个原readBy/unreadBy/reactionDetails记录分别用原完整IMUser及当前viewer resolver生成窄显示值；不按UID建姓名cache，不去重、过滤、交换first/last或修改原数据。
- `Features/Chat/ChatMessageSurfaceInputs.swift`：显式ReadReceipt/ReactionDetail记录+显示名presentation，id严格沿用原record.id；certification仍按真实UID归属，不改details/count/reaction权限。
- `Features/Chat/ReadReceiptSheet.swift`：原每行Text/Avatar、顺序/原记录/资料/设备/时间/ID均保留，只改窄值接线；internal DEBUG被动记录同一实际行Text/Avatar的displayName，Release无此诊断。
- `BlueStoneIMTests/ChatSecondarySurfaceBoundaryTests.swift`：新增两实际App→Feature行入口的同UID/不同快照和当前viewer独立备注反例，保同host/记录数量/恢复；旧192算法真实RED两例，原图保留。
- 四个原source-contract真实RED与runtime IDs保留；GIF读App/ChatAttachmentActions，tap读App/ChatNavigationActions，image fullScreenCover读App/ChatPresentationAssembly；逐行显示名检查读App/ChatReceiptAssembly，快捷菜单读App/ChatMessageInteractionAssembly。
- 原remark测试同步追踪current cbe已有directory与group/mention/mute的真实producer→value→row链，保viewer标识/备注/自身保护及实际消费；不在旧Feature回填实现或注释字符串。为保≤800，仅该原方法整体移入现有BoundaryTests，runtime ID不变、不增加文件/PBX。
- 此私有修复保完整原192/52动作与原F4/Bool/IO/权限/导航/权威revision/admitted completion；正常Debug/allXCTest、unsignedRelease min15及四原例+两新反例/相关receipt权限focused结果以本批独立HANDOFF/receipt为准；旧16/13静态PNG只复用原有范围，不冒称覆盖此次冲突行。
- private65/B18已安全checkpoint，修复封存后恢复原完整范围；本修复无actual/Main/push/sign/CI/生产授权。


## WDT_IOS1_FEATURES_ATTACHMENT_APPROVED305_PHYSICAL_20261111

PRIVATE_ONLY / originalR2 review pending. Fixed canonical cbe598a3f18ae5224d89a491224316bcab6d70c5 incorporates approved Main20b/B305. Original physical Features16 boundary re-created while keeping approved rejected-dismiss/latch/drag spring, original installed caller and DEBUG-only internal passive observer in the real Features owner; Release has no observer. App F4/save/IO/avatar helper policies remain internal and unchanged. Original C1 leaf blob a1b29c52fe62d13ddf4c17b85165baf7eb62e30b is269lines; AttachmentDetailBoundaryTests is659lines. Imports/exact type owners only; assertions and state/native render contracts retained. No new testability override or public App policy.


## WDT_IOS1_FILESTORE_COMPLETE_FAMILY_CBE_20261111

PRIVATE_ONLY / originalR2 pending. Original FileStore12 own scope follows aligned physical Features16 on fixed cbe; complete15 Published state and original commands/observation/lifetime in real IM4Stores, pure values in Domain, App platform IO/policies remain. Approved B305/C1 body and DEBUG-only actual installed drag observer preserved. No new fixture repair or heartbeat semantics change.


## WDT_IOS1_CALLS_COMPLETE_FAMILY_CBE_20261111

PRIVATE_ONLY / originalR2 pending. Original Calls14 own scope follows fixed cbe + aligned physical Features16 + FileStore12. Complete10 Published CallStore/state/lifecycle/prompt/VoiceSession/VideoGate in real Stores, pure values in Domain. Original App provider/RTC/IO/auth policy and all old assertions/timeouts remain. No seventh-file fixture repair in this pure cut, heartbeat conflict remains OPEN. Approved Main20b/B305 Attachment/latch/drag bodies and C1 test imports/contract preserved; old frozen packets unchanged.


## WDT_IOS1_PHYSICAL_CHAIN_EAC_ACTUAL_CANDIDATE_20261111

Local review candidate only, parent eac925cc1761ae45e61997a9fa301e926a2072fd. Original pure physical35 ordinary32/new15 preserved from frozen805 source; Package/PBX/marker context merged retaining approved Search3/Data52. New808/731Swift combined context has NOT been built or run; original805 normal Debug/Release min15 and36 native results are source-provenance reuse only. Excludes independent seven-fixture/Core61 schema/Heartbeat/Memory/RTC/database fixes. OriginalR2 full review pending; no Main integration, approval, remote, sign, CI or production.

## WDT_IOS1_CORE35_E19_CONFLUENCE_REVIEW_PENDING_20261111

- 本候选父提交固定 e19e738ab2d6dbca6d41440fd1896dbb453e8de8；Core 来源 b7be83851a7aba027b98e13ff68454e5910ba95f。保留全部 Raw/UI/fix 历史；仅两份测试合并双方既有 import/限定名及 App/physical 源路径。
- 实际合流 836 文件/759 Swift 尚未构建或运行；805 的正常构建与36项证据只属原 cut。REVIEW=REQUIRED_IOS_PENDING；未授权推进 Main。


## WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111

- BEGIN/END：`BlueStoneIM/LoginLogStore.swift`、`BlueStoneIM/Models.swift`、`Sources/IM4Stores/LoginLogStore.swift`、`Sources/IM4Domain/LoginLogValue.swift`、`Package.swift`、`BlueStoneIMTests/DomainStoreTestFixtures.swift`。
- 基于固定Main e19e738ab2d6dbca6d41440fd1896dbb453e8de8；完整LoginLog state owner的原三项Published、ObservableObject、默认值、同步willSet和reset原赋值顺序迁入Stores。App仍使用原唯一实例，必要public仅原typed值/赋值、publisher、reset及空构造。
- 原LoginLog五个只读String字段、Identifiable/Hashable语义与原memberwise赋值迁入Domain；不增加Codable/缓存/新状态。App仅类型桥接，MockData与真实Me/Security消费者原体不改。
- 原refreshLoginLogs的请求合并、hasIMSession、remote scope/session fence、defer、映射/错误/default/unauthorized处理和原会话reset入口均留App原体；不改A共享TenantSession/RemoteAuthState或Chat/B UI、不新增relay/copyback/service bag。
- 六个原真实refresh/失败/发布/会话恢复消费者用例原断言/超时不改；新增一项实际App facade/reset后同一模块owner与真实Domain值边界反例，保留实际加载App/XCTest。
- GroupModeration未冒称收口：其App隐藏mutation/token/generation/boundaryTask/owner-transfer幂等与A reset接线缺口已独立只读保全；本族不含该partial切片，也不重放Core35或Core61未审修复。future Package/PBX/marker仅由唯一Gate语义整合。
- NEW_DEPLOY_SURFACE=0 JENKINS_CHANGE=0 SECRET_PLACEMENT=unchanged PROD_MUTATION=false AUTO_ROLLBACK=false REVIEW=REQUIRED_IOS_PENDING；无actual/Main/push/sign/CI/SQL/cloud/prod授权。
- 首轮public Domain值触发Swift6的public跨模块Sendable推断边界；五个原只读String字段显式标准Sendable合成，等价原internal值隐式安全性，无@unchecked/隔离覆盖；原cut01编译RED与制品残留保留，不冒称成功。

- 实际候选新合成基于d7f176b0632e403a6c5a770d3f9c4f1bdb440fdd：保Core35/Main现有Domain23/Stores12，只追加LoginLog两源到24/13；Core2/DS10/Data66/Features2及其它条款保留。五普通后像精确复用原e008冻结源；新838/761组合未build/native，不移用旧私有7/7或1653输入/304制品为此HEAD验收。原R2正式审查及R7后续正常验证分别进行。


<!-- WDT_IOS1_B18_B65_INPUT100_MAIN7EE_ACTUAL_CANDIDATE_20261111_BEGIN -->
- Local B review candidate is based solely on fixed Main7ee116fb74bc79cbbf3e1a88deb5fc5c2afe6e27. It combines the legal cumulative B18 prefix3ad69d88 -> B65fd03 -> frozen7b987bc increment; it does not replay private whole trees over current Main.
- B18 header/status/query and rendering contracts, B65 App-owned history/read-ACK/scroll/lifecycle/cache/row/Composer/voice producers and typed Feature consumers, normal14 ScaledMetric/AX/original bound action, actual100 event coverage and native-loaded-image attachment helper retain frozen B bodies. The final UIKit publication boundary protects pending native edits from synchronous owner-mirror reentry; original Core runtime methods/waits/assertions and ComposerState are retained.
- Current Core2/DS10/Domain24/Data66/Stores13/Features2 Package clauses and physical implementations stay at Main. Main SheetHeader module alias/import, attachment test IM4Domain import and all171 test memberships are retained; PBX only registers B's seven new App files. Attachment/FilePreview source readers follow actual module/App producers without changing assertions.
- Frozen B18/B65/fbb2/7b and their successes/failures remain evidence only for their original cuts. This actual Main+B combination has not been built or run natively; original R7 owns normal validation after integration. No full67/26/125 or performance/hardware/phase claim.
- Both original P2s remain OPEN pending the same R2's formal new-delta plus actual-merge decision. This preparation grants no Main, remote, CI, signing, cloud or production write. A cold8 and Group unmerged work are not imported. Main marker history is retained verbatim above.
<!-- WDT_IOS1_B18_B65_INPUT100_MAIN7EE_ACTUAL_CANDIDATE_20261111_END -->
## WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111

- BEGIN/END：`BlueStoneIM/GroupMuteMode.swift`、`Sources/IM4Domain/GroupMuteModeStateModels.swift`、`Sources/IM4Stores/GroupModerationStore.swift`、`Package.swift`、`RemoteSync/AppState+RemoteAuthState.swift` 的已释放Group retirement窄hunk、`DomainStoreTestFixtures.swift`。
- 基于固定Main d7f176b0632e403a6c5a770d3f9c4f1bdb440fdd；原三Published及完整list/settings/member/admin命令，连同隐藏idempotency/sequence/tokens/realtime-generations/boundary-Task所有权进入真实Store；不是三flags门面。
- 原mute intent/state/lifecycle/validation/projection纯值迁Domain；原通知与permission-only展示、IO/权限/SDK、scope生成/核验、服务器时间/修订最终权威和失败回退仍App；不加AppState/宽service bag/Any/global relay/copyback。
- 原reset顺序严格保留：list→settings→admin→idempotency→tokens→generations→cancel Tasks→remove Tasks；原单调sequence从不在reset清零。每个原App状态读写替换为窄typed命令，无公开整字典setter。
- 原owner-transfer幂等值完整迁入Store内部，旧算法用例仅切实际模块namespace，走正常Debug默认testable，不新增testability配置/public测试口；新实际App reset反例验证全runtime退役与跨reset sequence继续递增。
- root已在A冷启动AppState租约FROZEN_RELEASED_NO_FURTHER_A_WRITES后正式释放：仅删除原五隐藏字段，旧App幂等type同步移除，单一物理owner位于Store；未导入A未审8路径。对A冻结AppState a27b68e9的同五行兼容性核对通过，cold fields/ctor/Task/helper其它字节保留。RemoteAuthState仍只改已批准Group窄hunk，其余认证body字节保留。
- 不重放Core35、LoginLog实际候选或Core61修复；没有actual/Main/remote/sign/CI/SQL/cloud/prod写入，REVIEW=REQUIRED_IOS_PENDING。


<!-- WDT_IOS1_CORE61_GROUP15_ACTUAL_CC_20261111_BEGIN -->
- 实际语义合流仅含已完成原R2私有内容首审的 Core61累计34（b46ed20）和 corrected Group15（5f9302b），共同父固定 cc9746551659807108b1238a404ad4d93b91d3e7；48路径并集为范围上限，非owner保持当前Main。
- Core fixture追加helper与现有LoginLog用例并存；返回底部reader保留当前Main真实App/Feature路径和断言；Group reset/sequence/取消接线只合既有Group窄块；Package仅追加Group两个源，保留LoginLog和全部现有模块；marker历史保留。证书2、B UI47/IME teardown、LoginLog、A权限/device只读；不含ConversationFacade45或phase6。
- 原私有成功/失败及断言/等待预算保留，不能冒称实际组合验收。此exact组合执行一次正常Debug（全部XCTest source）和unsigned arm64 Release/min15，focused只针对实际影响链；证据见原Core owner既有handoff，最终仍需原R2 actual合流审查。
- NEW_DEPLOY_SURFACE=0 JENKINS_CHANGE=0 SECRET_PLACEMENT=unchanged PROD_MUTATION=false AUTO_ROLLBACK=false REVIEW=REQUIRED_IOS_PENDING；仅本地候选，无Main/push/CI/sign/install/cloud/SQL/prod写入。
<!-- WDT_IOS1_CORE61_GROUP15_ACTUAL_CC_20261111_END -->
## WDT_IOS1_CONVERSATION_FACADE_FAMILY_20261111
Complete ConversationStore state, commands and projected observation physically in IM4Stores; pure identity/friend/sync values in Domain. App retains RTC interpretation, diagnostic IO and existing SyncEngine assembly. Normal builds/focused validation pending; private source only.


<!-- WDT_IOS1_CONVERSATION_FACADE_ACTUAL_764_20261111_BEGIN -->
- 实际本地候选唯一父76438eb86d9618db94d9d727789b675bbe9e0a2f；仅语义投影已完成原R2首次完整内容审查的Facade45（146421a / IOSe3f65bf），不把私有首审当actual批准。父764的Core34/Group15、cert2、当前B UI47/IME两reader/返回底部reader、LoginLog及全部非owner保持。
- 范围上限原45（18修改/18新建/9删除）；两条父已有等价测试路径幂等去重。Package保Group两个源再追加Facade Domain2/Stores16；PBX只删除原9旧App扩展引用。AppState、RuntimeBindings device observer、完整device cleanup及A SDK根权限链只读；无phase6算法混入，原252行merge按原审源保留。
- 原sole Stores owner、五Published/runtime/claims/tasks/reset、相同注入engine、metadata/window原子帧、scope/epoch/ABA/selection和同步重入语义保留。原2307/父2308测试方法保全，新增原已审实际App默认owner测试。此新actual图单独正常Debug/全部XCTest、unsigned arm64 Release/min15和仅受影响focused，旧62=60P2F/143unlink与后继16P仍各属原cut，不冒最终全62。
- NEW_DEPLOY_SURFACE=0 JENKINS_CHANGE=0 SECRET_PLACEMENT=unchanged PROD_MUTATION=false AUTO_ROLLBACK=false REVIEW=REQUIRED_IOS_PENDING；无Main/push/CI/sign/install/Jenkins/cloud/SQL/prod写入，身份配置不改。exact最终证据在原Core owner自身handoff，唯一原R2 actual审后才可Root/R7 Main gate。
<!-- WDT_IOS1_CONVERSATION_FACADE_ACTUAL_764_20261111_END -->

- Facade actual首次27断言全PASS但保留8条SQLite unlinked。仅修owned PagedCommitFixture清理：取消/退役generation/detach不变，保留该fixture自身UUID临时目录直到测试进程释放异步投影持有的SQLite；不增加生产接口、不改断言/预算或删除他人数据。原cut01源/build/native保全，final正常Debug及共享清理路径针对复跑另行绑定；Release仍为cut01真实运行，全部Release输入与final逐项同源，不冒新cut执行。

<!-- WDT_IOS1_UNPUBLISHED_IDENTITY_BASELINE_20261111 -->
- Unpublished iOS1 local verifier, simulator fixtures, documentation and existing source oracle use the current App target identity `app.xltest.com` with existing Team `A3PN7W63G3`; App project and signing inputs are preserved.
- The verifier retains cc974's single-argument certificate extraction and strict Team/profile-name/production-APS/expiry/leaf/get-task-allow/diagnostics rules. Original synthetic methods and simulator fake negative/lifecycle guards are retained.
- The existing Swift oracle expects Debug's absent APS key, Release production APS, exact derived topics and nonempty profile-name contract while retaining both schemes/postactions/file checks. Its new-XCTest execution awaits Root's final parent; preparation makes no runtime-oracle claim.
- Preparation parent `cc9746551659807108b1238a404ad4d93b91d3e7`; scope6 existing files plus this append. NEW_DEPLOY_SURFACE=0; JENKINS_CHANGE=0; SECRET_PLACEMENT=unchanged; PROD_MUTATION=false; AUTO_ROLLBACK=false; REVIEW=REQUIRED_IOS_PENDING.

<!-- WDT_IOS1_DATA5_THROUGH8_MAIN42_ACTUAL_20261111_BEGIN -->
Cumulative reviewed Data5/6/7/8 own mechanisms on exact Main42: protected session IO, current identity cache, runtime route raw records/storage, and specialized brand wire codecs. App authority/locks/validation and current Core/Group/Facade/UI/signing remain the Main42 preimage.
<!-- WDT_IOS1_DATA5_THROUGH8_MAIN42_ACTUAL_20261111_END -->

### WDT_IOS1_LATE_AUTH_REFRESH_AUTHORITY_CASES_20261111

- 原 R2 P1 IOS1-COLD-RESTORE-LATE-REFRESH-FAILURE-AUTHORITY 的真实 normal ctor→shared refresh→fallback/remembered recovery 可控 RED。十条新用例覆盖迟到跨 epoch/tenant/普通 revision、新 authority durable session/cache 不被旧错误清除、当前撤销/过期清理与取消 waiter 后 shared refresh/coalescing 仍生效。原十四方法 body 逐字相同。仅测试依赖新增secondary gate/请求路径和真实 SnapshotCache remove 观察；不改任何生产源，先保存官方 RED。记忆凭据录入使用原 DI，是恢复链 fixture，不代替 R7 ThisDeviceOnly 实际 Keychain。

### WDT_IOS1_LATE_AUTH_REFRESH_FAILURE_AUTHORITY_20261111

- P1 独立修复，前缀为冻结 cold8 repo6e6f3e99；不混入 Data17/identity-cache/Core Group。原 auth fence 捕获后同时冻结可选 IM scope；fallback await 的成功/失败、failure handler 入口、remembered 尝试入口/失败和 recovery false 后破坏性提交前复核同一 frame。neutral-login 迟到不可用错误不能再发 retired tenant-login。
- 唯一生产路径 `Core/AppSupport/RemoteSync/AppState+StoredSessionRefresh.swift`。不新增 Task 取消判断，不取消共享 refresh，不改成功提交、终止分类、clear/cache/persistence body。官方 RED2=10选中/实际，3对照PASS+7迟到路径FAIL，所有 gate 到达；RED1的6个fallback前置失败不冒复现，原制品保留。原十四方法 body 不变；最终 focused24 待验证，P1 保持 OPEN 交原 R2。

### WDT_IOS1_REFRESH_DEVICE_ERROR_AUTHORITY_OWNER_20261111

- Root明确释放后应用已实证tenant POST refresh的最小联动proposal：SDK不提前发无原authority的全局设备事件，typed device failure交原shared refresh owner fence，再调用原完整handleCurrentDeviceRevoked。完整cleanup body不动，补current device full cleanup对照。此为观察URL的第一步，不冒充其它请求已安全；全通知caller清单193处/164显式IMAPIContext等继续盘清。

<!-- WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN -->
- Preserve immutable caller auth fence through HTTP routing, fallback and preferred probes; exact-fence GET separation; synchronous fenced device-revocation consumption. Contextless API contracts remain an explicit P1 release blocker.
<!-- WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END -->

<!-- WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN -->
- Complete authenticated raw/root API owner propagation and explicit public/anonymous device rejection classification. Additive internal protocol overloads preserve original conformers; original device cleanup body remains intact. Final native and original R2 review remain required.
<!-- WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END -->

<!-- WDT_IOS1_PLATFORM_OWNER_REFRESH_RETRY_20261111_BEGIN -->
Original active owner authority is separate from platform request credentials; exact validated platform refresh continuation allows one same-session revision. Original global fence equality remains.
<!-- WDT_IOS1_PLATFORM_OWNER_REFRESH_RETRY_20261111_END -->

## WDT_IOS1_CORE26_MAIN42_REPAIR_20261111

- 范围：Main42 Core26 原失败和原127 SQLite warning 的自有 producer 修复，与 phase6 v2/原presence单hunk分包。
- PushToken：原输入与归一化不变，经 Python hashlib+OpenSSL 两独立实现证明后纠正旧 SHA256 golden；保不泄露 raw token 断言。
- exactConnectAck：保原 requestID gate、实际握手状态/次数/等待，诊断 expected 纳入真实 rejected responseObserved 并新增 auth/requestRejected/acknowledged 的精确检查；生产 SDK/Auth 只读，原R2须核合同演进。
- outbox reader：原 AppState 巨文件函数已拆分，改读现存 AppState 及4个实际 AppSupport producer，保原方法body锚点及全部XCT断言，不伪造旧路径。
- SQLite：只停止删除 realtime-binding、message-callback、route/mismatch/cold-video 五类自有 UUID 合成 fixture backing；原 cancel/release/generation/detach/断言/等待不变，不新增生产 close API、不保留用户目录。ios1-reauth 107 warning 由原 A Auth fixture owner 接续。
- 证据：本包 evidence/push-token-independent-golden-proof.json、sqlite127-producer-map.json、A-PRODUCER-DEPENDENCIES.json。只跑修复直接相关 focused，结果尚待；无独立审查批准，不宣称26或49全过。

## WDT_IOS1_AUTH_ACTUAL_COLD_CUMULATIVE_PREREQUISITES_20261111

- Auth actual sole parent8cf，保完整 inherited Data19/B identity/S1。累计原A31、AuthOnly v3与原Cold真实constructor依赖，不混SDKv3/M13/Data9+/新A17修复。
- Core原owner精确释放AppState最小hunk：nil默认测试host选择不改生产检测；保留真实constructor task、pending admission；A仅采用此hunk，不覆盖其它Core/Group/Facade字段。
- 补回原Cold14全部原方法/等待及A31累计实际测试；采用原Cold task/admission函数、Realtime initial scene/background lifecycle，以及BlueStoneIMApp原初始view-task唯一forwarding hunk，保持真实入口和负向fence/取消保护。
- Root释放原Core first7：仅六既有测试和原marker。最终完整actual统一正常编译、直接Cold/P1/Core7回归及原R2正式审；历史private支持不代替actual批准。

- Auth actual首次正常编译65保全；只补原Cold/P1共享makeRefreshableMessageSendContext(deviceID:)默认参数和context/session双处设备绑定。默认device-1及全部原测试/断言/等待不变，生产0；新普通child仍soleparent8cf，不重写旧失败候选。

- Auth actual v2正常Debug0，官方61=60P1F0skip保全。只补原StoredSessionRefresh既有Cold绑定前置：cold_launch共享刷新保凭据提交/fence而不旁路重绑socket；constructor/foreground caller各按原生命周期准入。共享task不取消，非Cold调用保持原重绑。原测试/断言/等待/取消和gate次序零改；final仅复验Cold40受改正负控制，其余v2实际21按精确路径等价限定复用，不重跑整61/Data38。


## WDT_IOS1_BOOTSTRAP_DATA15_16_20261111 — Data17 机制15/16真实 IO 闭包（2026-11-11）

- 范围：仅 PRELOGIN_LASTGOOD_AND_HTTPS 与 BOOTSTRAP_LASTGOOD_CACHE；独立隔离工作区 `ios1-bootstrap-data15-16-parallel/IM4`，普通本地分支 `codex/ios1-bootstrap-data15-16`，`BASED_ON_CANONICAL_HEAD=8cf8e148ae9fc85e416ac495f8bab92bbadc450a`。不是整体 Data17/IOS1 阶段0–6完成，不写 Main/remote/其它 owner 源码。
- 真实迁移：`BlueStoneIM/PreloginBootstrapResolver.swift` 原 envelope/checkpoint/protocol、文件/Keychain actor 与专用 URLSession byte-stream HTTP 机制分别迁到 `Sources/IM4Data/PreloginLastGoodStorage.swift`、`PreloginHTTPSClient.swift`。App 保留窄 alias/adapter、原错误映射、源地址 helper 转发和完整 resolver；没有换成通用 HTTP 路径。配置根/key/audience、签名、撤销/过期、fencing/回滚与离线调度仍在原 App。
- 缓存迁移：`BlueStoneIM/Core/Networking/IMAppBootstrapSupport.swift` 原 entry/snapshot 与实际 UserDefaults/JSON IO 移到 `Sources/IM4Data/AppBootstrapLastGoodRecords.swift`。原 RemoteAppBootstrap 已在 Data，mode/route/policy 复用已有 Domain/Data 值。唯一 purpose-specific generic record 直接持有该真实值，App 既有 Codable/归一化原样供应，不建第二 cache/新 proof record。App save/load/snapshots、hostlist/build/environment/TTL/revision排序/选择/清理归属及 HostConfigurationLoader 原 body/顺序保留。
- 合同：原 `BlueStoneIM/PreloginBootstrap/<scopeHash>/last-good.json`、JSON字段/Date/Data编码、原子写+completeFileProtection、Keychain service `<bundleID>.prelogin-bootstrap`/account scopeHash/WhenUnlockedThisDeviceOnly、v3/v2/v1 defaults 三键/旧 entry 缺 servingHost fallback 全保。保 HTTPS/source host/port/path、无 credentials/query/fragment、拒绝所有 redirect、HTTP200/最终同URL、256KiB header+stream双界、3s/5s/2connection、取消及 URLSession TLS 默认行为。原两个 unchecked 声明随真实不可变 session/delegate 搬迁，无新增 unchecked/type-erased service 或秘密位置。
- 注册仅 `Package.swift` 的 IM4Data 三条本族 sources；PBX 仅新增一个直接测试文件的 BuildFile/FileReference/group/source phase 共四条登记，target/dependency/其它登记/身份均不改。
- 测试：新增 `BlueStoneIMTests/BootstrapDataStorageAndHTTPTests.swift` 七项，覆盖真实 App adapter 的文件首读/重开/重复/损坏、只读父目录写失败旧字节保全、合成唯一 Keychain 的首读/重写/损坏或无 entitlement fail-closed、真实 URLSession 合成响应的状态/302/最终URL/大小/取消/transport error/GET header，以及真实 bootstrap cache 的模式/路由/策略 roundtrip、缺 host 兼容、NaN编码失败旧字节保全。所有原测试与断言/等待原样保留。Keychain 测试只访问 UUID 隔离的合成 service/account 并清理自身项，不读取真实账户。
- 已验证：本族六份 Swift 语法/均≤800、PBX lint、diff check；原 scheme BlueStoneIM 正常 unsigned Debug build-for-testing（Swift6、jobs4、min15、锁定 GRDB7.11.1/WebRTC149.0.0）成功，真实 App + 全 XCTest 编译。编译初轮漏保留 resolver 对源检查 helper 的调用被编译捕获，补同一 helper 窄转发后正常增量成功；初轮失败日志保留。实际 App 链入三族 Data 实现符号；Info bundle app.xltest.com、MinimumOSVersion15.0。generic Simulator destination 生成 arm64+x86_64，未占用任何模拟器。
- 验证限制：七项新增及59项原相关 focused 共66项仅已编译，尚未运行；不报 runtime PASS、iOS15真机、Release/覆盖升级/签名/APNs 或全部阶段完成。原 R7 统一使用既有 `4F567B38-8768-434F-9B24-EB543546A34E`，精确 selection/未执行命令见本族 evidence，不新建第六台/重复其它在途作业。
- 导航：两个 App 入口内完整本标识 block/紧邻注释；三份 Data 源及新测试文件整块本标识；Package/PBX 只采本标识对应最小 hunk，保 Core M13/A/B 的登记。精确行号/路径/hash/正反 patch/commit、编译产物及待执行输入在 `/private/tmp/im4-ios1-bootstrap-data15-16-evidence/HANDOFF.md` 与 `candidate.json`。审查仍固定 R2，runtime/Gate 固定 R7，仅 Root 派发；本 source 不自批、不 Main。
- 回退：候选单普通 commit 的反向 patch/revert，仅本族九路径；共享 Package/PBX/marker 后继整合时按本族 hunk 逆向，不覆盖其它 owner 新登记。无数据迁移、cache wipe、账户变化或运行态回滚。`PROD_MUTATION=false`、`AUTO_ROLLBACK=false`、`NEW_DEPLOY_SURFACE=0`、`JENKINS_CHANGE=0`、`SECRET_PLACEMENT=unchanged`、`REVIEW=REQUIRED_IOS_PENDING`。

- 2026-11-11 实际 focused 增量：原 R7 在 1c741697865aa387c1a924740fc5b3669affe9c5 正常副本一次运行66项，65P/1F/0SKIP、exit65；原失败与全部raw保留于 `/private/tmp/im4-ios1-bootstrap-data15-16-runtime-r7-20261111`。唯一失败是新 cache roundtrip case 的两条完整值等式：合成 publicationID 非空但 publicationStatus=nil；原8cf的 RemoteBootstrapModels.swift:308–309 已将缺省值归一为trim/lowercase app status（本例 enabled），该生产codec字节一直未改。不是字典展示顺序或本次Data抽取丢字段。
- 本族 fixture 定向修正：仅给本case设置明确 `publicationStatus = "enabled"`，同时在设置前用原codec断言缺省状态确为 enabled；两条原完整bootstrap数组等式、mode/routes/policy、legacy缺host、损坏不删除、编码失败旧字节保全及全部其它断言原样保留。无 production/App/Data/Package/PBX变动，不改变生产归一化。修复独立普通child，原1c历史与原65P1F不改；本次原source正常增量编译/产物与仅1条待原R7补跑输入另存 `/private/tmp/im4-ios1-bootstrap-data15-16-fixture-fix-20261111/HANDOFF.md`，不重跑66/Release/全suite。原65P只按未变源码及测试边界精确复用，不冒新66P；正式R2独审和新case真实运行仍待Root派发。

<!-- WDT_IOS1_DATA_HTTP_ENVELOPE_RECORDS_20261111_BEGIN -->
- Data17 mechanism9: raw HTTP error/list/envelope decoders plus the typed conversation-page carrier move to Data; App retains both resolvedError merges, classification/presentation/retry and existing off-main scheduling/fences. The exact APIEnvelope Sendable specialization remains T == RemoteConversationPage. No unchecked carrier or mixed AuthData move.
<!-- WDT_IOS1_DATA_HTTP_ENVELOPE_RECORDS_20261111_END -->

- WDT_IOS1_DATA17_NATIVE_REALTIME_20261111: Move the original native URLSession WebSocket, NWConnection WebSocket/QUIC and path monitor implementations into IM4Data. Preserve existing App feature configuration, authority, route, lifecycle, and batch expansion. Keep the original two native errors’ Foundation domain/code.

- WDT_IOS1_DATA17_RAW_REALTIME_FRAME_20261111: Move raw frame input, envelope decoding, and bounded batch expansion into IM4Data. The App retains the original injected codec target, worker, synchronous manual entry, prepared-message nil distinction, RTC policy, and generation checks.

- WDT_IOS1_DATA17_MEDIA_DOWNLOAD_SPLASH_BYTES_20261111: Move native media download, temporary file install, bounded remote-image byte/metadata readers, and splash byte checks and disk I/O into IM4Data. App retains URL authority, signed refresh, retry, task scheduling, image preparation, render and cache-key policy.

## WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111

- 基线 actual8cf8e148，完整M13实际raw blob族；不从旧v2/A31覆盖。Data新增文件记录、内容校验/流式hash、POSIX防链接/权限修复、同名part原子提升、实际读/写/统计/LRU选择/删除和临时blob IO，继续原Data identity/index和SQLite仓，不新cacheDB。
- App保IOSMediaCacheScopeContext、registry/actor、session generation、原政策/preview/display fallback、IntegrityAuthority原输入归一化和原App错误类型；原actor调用Data同步raw机制，原prune两个await及原utility detached wrappers保持，不新增主线程IO或任务/队列。
- 精确保护原700/600、O_NOFOLLOW/单链接、原completeUntilFirstUserAuthentication/backup排除、cache key/目录/part命名/格式/错误与LRU顺序；strictPhoto/硬件缺口不变。
- 共享注册只在Package的IM4Data.sources新增本族4条；无PBX/目标/签名/依赖变化。必要新Data源码均真实执行，未移动UIImage/render/权限整对象，未触及SDK/Auth/RuntimeBindings/共享fixture/B view。
- 实际typed消费者：原App MediaLayeredCacheStore→Data MediaBlobCacheStorage；MediaFileIntegrityAuthority→Data MediaBlobIntegrityExpectation并桥回原错误；原AttachmentTemporaryFileWriter/MediaCacheFileIO保Task边界→Data MediaBlobFileIO；既有SQLite media index不变。
- 验证与源/制品/正反差分见本包。原QoS两caller与Core26两admitted case需直接验证，零warning不冒全IO排空/未选scope关闭；A shared fixture依赖仍保。独立R2未审、无Main/PROD写。

- M13后续直接消费者fixture隔离：两个原admitted方法分别使用单次UUID设备namespace；通过原immutable IMStoredAuthSession构造器逐字段保留其13项元数据，只替换匹配deviceID，并把原A生成的登录响应中platform/tenant/session三处device_id同步。A helper/transport/生产fence/原断言/等待/权限与退休路径不改。原native23=22P1stale与fresh-process单例1P完整保留；只补必要两case同进程，不把单例PASS替代原矩阵或自动减Core23。

## WDT_IOS1_DATA17_M17_REAL_IO_CONSUMERS_20261111
- M17: original RTC diagnostic actor delegates synchronous append/read/rotation/atomic file mechanics to IM4Data; App keeps sanitization, paths, thresholds, export format, sequence and error policy.
- Original App UserDefaultsCallRecordStore remains the actual IM4Stores persistence adapter; schema-v1 typed archive/defaults/disk IO now executes in IM4Data with original disk-first fallback, atomic write and delete behavior. No new actor, queue, authority, Sendable widening or DTO copy.

- WDT_IOS1_SDK_GET_V3_20261111: Adopt Core’s four-field HTTP trace scope and sole emitter. Native URLSession records the original delivery point once. The existing shared raw GET result carries the creator’s diagnostic source beside the response. Each logical caller links the returned creator and measures its original decode execution. The shared request key, Task lifecycle, request wire and authority behavior stay unchanged.
- This cut adopts Root’s isolated HTTP fixture helper, A-owned reauthentication temporary backing lifetime fixes, two source reader fixes, and the Core group self snapshot fixture method. B cleanup and Core route diagnostics remain separately owned.

- WDT_IOS1_A17_CURRENT_FIXTURE_CONTRACT_20261111: Bind the original refresh skew test to the committed five-minute policy. Use a valid lowercase legacy enterprise code in the bound device proof request test while retaining canonical uppercase, credentials, header and request order assertions.

<!-- WDT_IOS1_CHAT_PHYSICAL_FEATURE_CLOSURE_20261111 -->
- Chat UI, pure layout, input/presentation owners and immutable UI values move into IM4Features/Domain; scoped application authority, SDKs and routes retain their App adapters. Existing composer, IME, visibility, read, attachment and rendering contracts remain the validation scope.
- UIKit editing events update the sole Feature keyboard-layout flag after the current view update, fenced by the latest per-owner event revision; text/send/scroll/read callback timing is unchanged. Existing runtime-warning and native RED evidence is retained alongside focused followup validation.
- Private authoring prefix remains 6a23646568bfa3ab6ad89ca8346e280aac297478. Core source-reader hunks retain their original owner; final actual projection, original R2 review and gate integration remain separate. No Main/remote/CI/signing/cloud/production mutation.

<!-- WDT_IOS1_CHAT63_ACTUAL_F928_20261111_BEGIN -->
- Local IOS1 Chat63 candidate on `f928fdb344989f8a111757ed71ff7540e7a7e0d2` projects the frozen Chat content and originally released source readers. The parent keeps its Auth cold-scene entry, Data M9–17, App identity and SDK v3/A17 changes.
- `WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111` retains four factory-owned UUID backings across three B test files for their outstanding asynchronous consumers. The parent test paths, assertions, waits, SDK behavior and transport authority are retained.
<!-- WDT_IOS1_CHAT63_ACTUAL_F928_20261111_END -->

## WDT_IOS1_STORES_ORGANIZATION_DIRECTORY_OWNER_20261111
- The existing App organization directory Store resolves to one IM4Stores owner. MainActor, snapshot, refresh and mutation IDs, and narrow publishers retain the original logic. IM4Data provides the existing directory tree type and IM4Domain provides member values.
- App still owns tenant and scope checks, permissions, request and commit order, member projection, reset entry points, and the Contacts view adapters.

## WDT_IOS1_CORE_OUTGOING_FIXTURE_PERSISTENCE_20261111
- Original outgoing regressions use an independent coordinator, snapshot and route store per fixture. Text renewal cases explicitly load the original policy before asserting the original send and refresh sequence, without triggering unrelated login transition requests.

## WDT_IOS1_PHASE6_PRODUCTION_CHAIN_20261111
- Production history paging, prefetch and jumps carry the existing SDK source correlation to the message derivation worker, then recheck App scope, request fence and prepared Store input before committing.
- Realtime keeps admitted order and bounded recomputation. The existing synchronous path handles contention after three attempts, with separate actual Store frame and mounted projection observations.

## WDT_IOS1_PHASE6_REVIEW_SEARCH_AND_TRACE_20261111
- Conversation search rechecks the same scope and session epoch after worker suspension. A same-authority fallback still returns the original persisted local results.
- Derivation diagnostics use the conversation ID resolved by the actual Store command, including a guarded synchronous fallback. Store installation and mounted observation retain the same frame revision.

## WDT_IOS1_PHASE6_SEARCH_READ_AUTHORITY_20261111
- Capture conversation search authority before SQLite. Check the same scope, epoch, local generation and captured ticket after SQLite, after remote derivation and around error handling. A current authority still gets local results while offline or on HTTP failure or cancellation, and can use renewed credentials.
- `ScopedMessageCallbackTests.swift` holds the actual search HTTP request and SQLite FTS statement to check retirement and same-authority fallback through the App entry.

## WDT_IOS1_CHAT_SCREEN_SCOPED_STORES_20261111

AppFeatureComposition now supplies the existing current-user, enterprise, batch-forward, conversation and contact Stores to ChatView. Chat uses the same initial values, keyed updates, and live reply identity. The original conversation, permission and policy authority fallbacks remain in place. This batch does not close Phase 4. The original ChatTimelineAssembly memory-commit callback, scroll/read controls, and session authority remain unchanged.

## WDT_IOS1_CHAT_SCREEN_ACTION_BOUNDARIES_20261111

ChatView and its page extensions consume existing Stores and typed App composition for authority, history, people, calls, forwarding, message, media and search operations. The composition preserves the original live scope checks, protected-access snapshot and publisher, conversation fallback, and Core transcript install callback. Composer scope updates use the existing session identity publisher. App services continue to own authorization and request behavior.


## IOS1 B · 其余六个 Feature 界面归属（2026-11-11）

该批基于已冻结的 Chat tree `9b24a323ee9741fd9beb22ac1b5f00cd345021b0`。以下标识适用于现有 App 入口到 `Sources/IM4Features` 的实际界面迁移。业务策略、Store 观察、作用域验证和 SDK 仍由原 App 接口提供。未增加模块依赖边。

| 标识 | Feature 路径 | 现有 App 入口和合并边界 |
| --- | --- | --- |
| `WDT_IOS1_FEATURES_AUTH_UI_20261111` | `Sources/IM4Features/Auth/` | `BlueStoneIM/AuthViews.swift`、`BlueStoneIM/Features/Auth/`。原登录、注册、重验证、企业入口、忘记密码、Captcha 命令和 WebKit 路由保持在 App。 |
| `WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111` | `Sources/IM4Features/Conversations/` | `BlueStoneIM/ConversationViews.swift`、`BlueStoneIM/Features/Conversations/`。保留原缓存更新、精确认证及会话跳转。 |
| `WDT_IOS1_FEATURES_CONTACTS_UI_20261111` | `Sources/IM4Features/Contacts/` | `BlueStoneIM/ContactsViews.swift`、`BlueStoneIM/Features/Contacts/`、`BlueStoneIM/GroupDetails/`。目录、组与资料仍使用原 Store 观察和权限命令。原 `GroupDetailLayout.swift` 的三项控件已迁移，Xcode 的四处旧登记随原文件删除。 |
| `WDT_IOS1_FEATURES_CALLS_UI_20261111` | `Sources/IM4Features/Calls/` | `BlueStoneIM/FilesRTCViews.swift`、`BlueStoneIM/VideoCallViews.swift`、`BlueStoneIM/Features/Calls/`。RTC 及 CallKit 操作在原入口，保留渲染端口、可用性和通话时长格式。 |
| `WDT_IOS1_FEATURES_FILES_UI_20261111` | `Sources/IM4Features/Files/` | `BlueStoneIM/Features/Files/`。预览、文件导出与下载取消仍走原验证、缓存和 SDK 边界。 |
| `WDT_IOS1_FEATURES_ME_UI_20261111` | `Sources/IM4Features/Me/` | `BlueStoneIM/MeSettingsViews.swift`、`BlueStoneIM/Features/Me/`。原设备管理、验证码、认证、策略及系统权限命令保留。 |
| `WDT_IOS1_FEATURES_PURE_CONTROLS_20261111` | `Sources/IM4Features/Contacts/`、`Sources/IM4Features/Me/` | 原纯控件通过 App 类型别名接入，业务及发布配置不在该差分。 |
| `WDT_IOS1_FEATURES_SURFACE_PACKAGE_20261111` | `Package.swift` 的 `IM4Features` 源码列表 | 启用六个目录。原 Swift 6、iOS 15、GRDB 与依赖边保持。 |
| `WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111` | `BlueStoneIMTests/ChatAttachmentLeafBoundaryTests.swift`、`ChatBubbleResendRenewalTests.swift`、`ChatBubbleSessionRenewalTests.swift` | 仅四处 factory 自有 UUID backing 提前清理被移除。原断言、等待、取消与作用域围栏保留。 |

以 BEGIN/END 标识、实际差分和私有 WIP 验证回执为准。已通过包含 171 个测试源码的正常 Debug 构建，以及 Auth、Conversations、Contacts、Calls、Files 和 Me 的分批定向模拟器验证。原冻结 Chat 的 63 个 Feature 源码逐字节保留。原 A、Core 仍拥有各自的源码测试读取器及已复现的会话列表 Store 崩溃。现有企业搜索页面仍在原 App 路径。正式提交、原 R2 审查与实际合并父提交由原链路处理。

## WDT_IOS1_CORE23_ISOLATED_AUTH_FIXTURE_20261111
- Uses the byte-identical A shared helper already present on the parent; four original Core fixture/consumer methods use isolated authenticated input without login-transition RPCs. All original assertions, waits, hydration, contexts and call-state setup remain.
- Root-released diagnostic producer correction changes only five incorrect conversation endpoint literals back to the actual SDK/server wire paths; no allowlist expansion or redaction change.

## WDT_IOS1_TYPED_INCREMENTAL_CONVERSATION_DECODE_20261111

- App 在现有主快照增量路径中保留取消和每次请求的权限围栏。仅精确匹配 `POST /api/im/conversations/sync` 与 `RemoteConversationSyncData` 时使用后台解码，原成功和错误封套在 MainActor 继续分类。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+PrimarySnapshotSync.swift:57` 和同文件第 87 行的标记段覆盖主快照结果传播与增量请求权限围栏。SDK 标记在 `BlueStoneIM/Core/Networking/IMAPIClient+RequestExecution.swift:432` 和 `BlueStoneIM/Core/Networking/IMAPIClient+ResponseAndLogging.swift:124`。新增验证段位于 `BlueStoneIMTests/HTTPSDKSharedPhysicalTraceV3Tests.swift:277`。
- 合并时同时保留四个标记文件的逻辑，依赖现有会话权限围栏和后台解码入口。原 36 处强制分页调用不变。正式父 `887a97103` 上的原候选 `21b1c6a86` 完成普通 Debug 及原七项定向运行，7 项通过。索引修订仅补注释和定位，沿用该次验证范围。

## iOS1 三个聊天叶级的 App 装配

依次采用 `b5a75213 → 2d3de304 → 3a688f04` 的冻结差分和 `9e816ab9` 的两处 `IM4Domain` 导入。共享的 `FeatureRoutingComposition.swift` 保留三个独立标识。实际父确认后按原顺序应用源码差分和标识补丁，再把本节追加到该父索引末尾。

<!-- WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN -->
## WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111

MessageBubble 接收行模型、显示快照和窄动作。App 装配保留当前用户、群和回执观察的原首值，并在动作入口校验会话。

移除原气泡内的 AppState 回退、权限查询、显示投影和旧叶级便捷初始化入口。ChatTimelineRowComposition 提供相应值和动作，相关挂载测试改走同一工厂。

- `BlueStoneIM/App/ChatMessageBubbleAssembly.swift` 第 8–127, 132–145 行
- `BlueStoneIM/App/ChatTimelineRowComposition.swift` 第 1–3, 8–420 行
- `BlueStoneIM/App/FeatureRoutingComposition.swift` 第 86–88 行
- `BlueStoneIMTests/ChatAttachmentLeafVisualTests.swift` 第 1–3, 10–55 行
- `BlueStoneIMTests/ChatBubbleBoundaryTests.swift` 第 8–106 行
- `BlueStoneIMTests/ChatBubbleVisualBoundaryTests.swift` 第 1–3, 10–55 行
- `BlueStoneIMTests/ChatMediaSessionAssemblyTests.swift` 第 10–159 行
- `BlueStoneIMTests/ChatReplyMediaBoundaryTests.swift` 第 18–79 行
- `BlueStoneIMTests/ChatTimelineRowFactoryTests.swift` 第 12–83, 85–130, 230–385 行
- `BlueStoneIMTests/IdentityChatPresentationTests.swift` 第 199–263 行

原 2d3de304 的 D3 13 项通过。气泡浅深色对照、同制品装配像素和 100 次输入及实时反应正控均通过。 行号按标识候选列出，以 BEGIN/END 和实际差分为准。
<!-- WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END -->

<!-- WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN -->
## WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111

ChatComposer 的 App 装配接入鉴权、企业、用户和现行会话观察。草稿和编辑器使用原所有者，媒体、提及、工具和目录回调用现行身份校验。

移除 Composer 和名片面板的 AppState 环境绑定、局部鉴权装配及重复传递的环境对象。动作由 App 注入，表情目录和贴纸分别沿用原缓存和服务，测试读取器检查该装配。

- `BlueStoneIM/App/ChatComposerActionAssembly.swift` 第 21–53, 82–181, 183–205, 219–284, 310–367, 382–419, 425–470, 522–548 行
- `BlueStoneIM/App/ChatComposerAssembly.swift` 第 24–26, 54–61, 148–225 行
- `BlueStoneIM/App/ChatComposerComposition.swift` 第 2–6, 96–231 行
- `BlueStoneIM/App/ChatComposerContactCardAssembly.swift` 第 1–5, 9–57 行
- `BlueStoneIM/App/ChatComposerInputActions.swift` 第 6–46 行
- `BlueStoneIM/App/ChatComposerPresentations.swift` 第 5–160 行
- `BlueStoneIM/App/ChatComposerSections.swift` 第 5–141 行
- `BlueStoneIM/App/FeatureRoutingComposition.swift` 第 91–93 行
- `BlueStoneIMTests/RemoteStickerAndEmojiModelTests.swift` 第 283–315 行

原 3a688f04 的 D3 12 项通过，覆盖重验证、IME、焦点、语音与失败草稿恢复。 行号按标识候选列出，以 BEGIN/END 和实际差分为准。
<!-- WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END -->

<!-- WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_BEGIN -->
## WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111

AttachmentDetailSheet 使用 App 注入的附件观察和值，保留 FileStore 双键、上传和下载优先级、原 Face ID 校验、缓存与分享回调。

移除附件详情直接 AppState 读取和仅转发的系统预览包装。observeChatAttachment 保留原入口并适配 FileStore，预览与回退由原 App 服务执行。

- `BlueStoneIM/App/ChatAttachmentDetailAssembly.swift` 第 1–3, 7–276 行
- `BlueStoneIM/App/ChatAttachmentObservationAssembly.swift` 第 3–6, 53–74, 77–183 行
- `BlueStoneIM/App/FeatureRoutingComposition.swift` 第 94–98 行

原 3a688f04 的 D3 12 项通过，覆盖进度、旧动作拒绝、许可撤销、重试取消及附件四组零像素差。 行号按标识候选列出，以 BEGIN/END 和实际差分为准。
<!-- WDT_IOS1_CHAT_ATTACHMENT_DETAIL_APP_LEAF_20261111_END -->

标识补丁基于 `9e816ab9ad6ed8a55d5fc801923a236fc4384193`，见 `swift-markers.patch`。本次验证覆盖 20 个 Swift 文件的字节复原和 DEBUG 开关两种语法树。原两轮证据保留，合图后的 24 项定向等待实际父放行。

<!-- WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_BEGIN -->
- Data17 M12 序列补缺。基于 `887a97103b1b593245c1ab7c328f113a392e44eb`，现有 `remote_snapshot` 进入恢复队列，`AppState+RealtimeSequenceRecovery.swift:75–203` 将非空 SDK 页接到现有 worker。提交及后续游标、覆盖清理、重试均依赖原 scope、epoch、history claim 和群历史边界。沿用空页边界、最大页数、历史窗口及退避顺序。每个有效提交页经 `AppState+SnapshotPersistence.swift:40–89` 的既有单会话 `.history` 投影落盘，恢复调用复用同一校验，其他调用保持原默认。
- `AppState+RealtimeCompute.swift:68–174`、`RealtimeComputeTypes.swift:28–44`、`AppState+RemoteMessageApply.swift:56–63` 在 prepared 校验和同步回退传递禁止递归补缺的选项，其它调用默认保留原值。`Sources/IM4Stores/ConversationStore+Sync.swift:43–65` 暴露 exact claim 身份核对。依赖既有 Core Phase6 worker、Store claim、SDK HTTP trace 合同。
- `BlueStoneIMTests/RealtimeBackgroundComputeTests.swift:604,678–865,889–893,953–1033` 复用 Phase6 transport、trace 和挂载模式，覆盖真实 SDK 两页、数据库回读和挂起时的群历史边界切换。原 App SDK、PrimarySnapshotSync、B UI、Package/PBX 不需要修改。本索引在原基线末尾追加，Root 按实际合流顺序保留其它 owner 的新增段；本族回退只逆转本标识相关 hunks。
- 验证见本族独立 handoff，按唯一标识及 `git log -S WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111` 定位。正常 Debug 通过，C7 定向 5/5，通过实际 remote_snapshot→SDK 两页、后台计算、Store/UI 同 revision、SQLite 回读、群历史边界过期及原三条回归。原夹具与落盘缺口的失败记录保留。 `PROD_MUTATION=false` `AUTO_ROLLBACK=false` `NEW_DEPLOY_SURFACE=0` `JENKINS_CHANGE=0` `SECRET_PLACEMENT=unchanged`。
<!-- WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_END -->

<!-- WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_BEGIN -->
- M12 原独审 P2 `M12_RECOVERY_DROPS_PENDING_DURABILITY_ON_PROJECTION_REVISION_RACE`。修订单独以 `3e15cb44c359a4ebc1b86801a3ddea33cd9051c8` 为唯一父，其前一层为实际基准 `a0aa291551598c7434cb481d0905f066b3035475`。原 worker、ACK、SDK 和数据库 scope 级 revision 规则继续沿用。
- `AppState+SnapshotPersistence.swift:40–110` 给补缺返回 SQLite 已确认的覆盖值。若同一有效 ticket 的 SQLite revision 已超过本次预领版本，最多三次重新取会话当前快照和版本，保留旧 scope 写入防线。其它快照调用沿用既有 best-effort；身份冲突或被拒事务不得报告已确认覆盖。
- `AppState+RealtimeSequenceRecovery.swift:39–225` 只按已确认覆盖推进或退休目标。已有内存进度可先重新落盘；原重试和续页保持当前 scope、epoch、claim、群边界。 `AppState+RemoteMessageApply.swift:310–321` 移除内存 apply 直接退休目标的分支。 `RealtimeComputeRuntime.swift:26` 仅 Debug 暂停点用于稳定复现预领版本竞争。
- `BlueStoneIMTests/RealtimeBackgroundComputeTests.swift:771–776,839–941,1002–1010` 经实际 SDK 令 A 预领版本后挂起、B 先提交，再恢复 A 并以新的 coordinator 重开同一 SQLite，核对两条会话及 A 重取的最新消息内容。正常 Debug 和 C7 定向 6/6 通过。A 预领 4，B 先提交至 5，A 以 6 重取最新投影落盘，重开后两会话覆盖均为 5。原五项断言保留；旧挂载用例等 SQLite 确认后判定目标退出，SDK 测试夹具明确加载本次策略。运行证据见独立 handoff。共享索引仅追加本标识段，合流顺序由 Root 决定。回退逆转本修订单父差分。
- `PROD_MUTATION=false` `AUTO_ROLLBACK=false` `NEW_DEPLOY_SURFACE=0` `JENKINS_CHANGE=0` `SECRET_PLACEMENT=unchanged`。
<!-- WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_END -->

<!-- WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111_BEGIN -->
- Data17 M3 清理 marker 归属。基于 `d7ff2f8dd9ee9de4847f1693e1d25d2a1bc09278`，把 `MessagePersistenceCleanupTombstoneStore` 整体移入现有 `Sources/IM4Data/MessageDatabasePaths.swift:310–510`。类体除跨模块所需公开修饰外逐字相同，保原路径、格式、原子写入、文件保护和排除备份属性，以及按散列定位、启动 drain 与残留处理。
- `BlueStoneIM/MessagePersistenceScopeCleanup.swift:78` 记录移除位置，App 继续持有 scope 清理栅栏。`MessagePersistenceCoordinator.swift:3` 接入 IM4Data，原登出调度、写 marker 后登记清理、失败时隔离及拒绝重用、启动 drain 和 SQLite generation/revision 原样。原 Data purge/quarantine 入口、Package.swift 与 PBX 无差分。
- `BlueStoneIMTests/MessageDatabaseTests.swift:487–527,616–617` 保留旧用例，增加 marker 原始字节、重启后同 scope 空库、相邻 scope 保留及 IM4Data 编译归属断言。正常 Debug、最低部署目标 iOS 15.0，C7 定向 6/6。测试只在临时 SQLite 和缓存目录触发正常 coordinator 清理。构建、运行与正反补丁见本族 handoff。此索引为单独追加，Root 按实际合流顺序保留前缀。
- `PROD_MUTATION=false` `AUTO_ROLLBACK=false` `NEW_DEPLOY_SURFACE=0` `JENKINS_CHANGE=0` `SECRET_PLACEMENT=unchanged`。
<!-- WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111_END -->

<!-- WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_BEGIN -->
## WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111

- Debug 的 `--notification-settings-screenshot` 在 App 根窗口直接挂载原通知设置页和 `NavigationStackCompat`。截图读取系统实际通知授权用于显示，开关的写入回调在权限请求或打开系统设置前返回。
- `BlueStoneIM/BlueStoneIMApp.swift` 第 37、58、63、72–77 行围住 AppDelegate 的冷启动与通知回调，第 151–179 行为根场景入口和模拟器默认环境写入条件。原 prelogin 视图、运行时根场景和 `RootView.task` 段保持原字节。
- `BlueStoneIM/Features/Me/NotificationSettingsView.swift` 第 7–40、48–56、94–98 行定义 Debug 标志、原导航布局及只读回调。常规 Debug 和 Release 沿原 gate 和通知权限入口运行。合并需同时带上两份 Swift 差分，并在实际父提交的索引末尾追加本节。
- 冻结父为 `63efbb28cda7bf658b4618cc7dd60366a2e4a8d7`。两份 Swift 通过 Debug 和 Release 语法检查，原通知测试源码保持原字节。R2 独审、实际父确认、构建和同身份 4F 整页复拍待原链路执行。隔离交接的 `source-forward.patch` 定位源码差分，`CHANGE_MARKERS-APPEND.md` 提供本索引段。
<!-- WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_END -->

### 实际父 `a0aa291551598c7434cb481d0905f066b3035475` 接续

- 两份 Swift 入口源码精确移植。原索引前缀和其三叶记录完整保留。`BlueStoneIMTests/HTTPVerificationContactAndRemarkTests.swift` 第 637–688 行只更新原通知源码合同方法。Feature 负责单一 Form、原提醒 Toggle、禁项与无 Section，App wrapper 负责真实绑定、挂载与前台刷新、离开取消及权限调用，Me 的通知路由仍使用正常入口。
- 原测试 ID 与同文件其他方法保留。实际父单独构建与制品身份见 `BUILD-RECEIPT.json`。原 57c 回执继续作为首次冻结证据。

## WDT_IOS1_CHAT_PROTECTED_ENTRY_FEATURE_20261111

- `Sources/IM4Features/Chat/ChatProtectedScreen.swift` 第 5–86 行承接实际聊天路由的锁定与解锁界面及验证中的本地显示状态。SwiftPM 原 `Chat` 源目录清单自动纳入该文件。
- `BlueStoneIM/ChatViews.swift` 第 344–379 行继续由原 `ChatScreenAuthority` 传入初值、更新和授权动作。原会话、联系人、黑名单、Composer 和时间线接线留在解锁内容及 App 装配。Files 的原调用通过已有 IM4Features import 使用同一锁屏，权限回调仍由 Files App 入口提供。
- `BlueStoneIMTests/ComposerInputBoundaryTests.swift` 第 531–563 行经原 App 路由挂载，覆盖锁定、替身通过实际 App 权限命令解锁及撤销授权后重新锁定时输入框的存在性。旧测试和既有原生证据保留。实际构建和定向执行见隔离交接。

## WDT_IOS1_CHAT_DELETION_CONFIRMATION_FEATURE_20261111

- `Sources/IM4Features/Chat/ChatMessageDeletionAlerts.swift` 第 4–66 行接管聊天界面原两处删除确认及候选显示绑定，保留原文字、按钮角色、取消和确认顺序。原 SwiftPM Chat 目录清单自动纳入。
- `BlueStoneIM/App/ChatTranscriptLayoutAssembly.swift` 第 178–191 行在实际 `unlockedBody` 接入 Feature modifier。仍从原 `ChatMessagePresentationState` 提供绑定，App 保留同一 `secondaryDeletionActions` 的会话 fence、命令和原 overlay 动画。
- `BlueStoneIMTests/ComposerInputBoundaryTests.swift` 第 566–644 行经原 App 路由读取实际 modifier，覆盖两处按钮的取消、确认和会话退役 fence。构建与定向证据见隔离交接。

## WDT_IOS1_CHAT_MOUNT_FIXTURE_ISOLATION_20261111

- `BlueStoneIMTests/ComposerInputBoundaryTests.swift` 第 234–273 行保留假 transport 和现有记住登录注入，路由及注册恢复存储使用夹具。合成用户通过现有非持久化投影进入实际 App 观察链。定向用例只清理各自的 UUID defaults suite。

## WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111

- 精确限定 `POST /api/tenant/users/profiles` 和 `RemoteUserProfilesResponse`。复用原 codec、HTTP 分类和备份重放，只传递具体 Sendable 封套字段。退役请求在冷启动记账前退出，当前权限的普通取消继续原记账。
- 变更标识及当前源码行区间
  - `BlueStoneIM/Core/Networking/IMAPIClient+RequestExecution.swift` 第 90、256–259、283、357、374、453–457 行
  - `BlueStoneIM/Core/Networking/IMAPIClient+ResponseAndLogging.swift` 第 195–199 行
  - `BlueStoneIM/Core/Networking/IMAPIClient+Contacts.swift` 第 3–22 行
  - `BlueStoneIM/Core/Networking/IMAPIClient+RuntimeRouting.swift` 第 215–227 行
  - `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+AvatarRealtimeAuthority.swift` 第 216–235、254、318 行
  - `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+CertificationRefresh.swift` 第 209–219、238、241、249–257、268–272、399–422 行
  - `BlueStoneIM/CertificationProfileBroker.swift` 第 274–280、303、312、330、340、351 行
  - `BlueStoneIMTests/DataHTTPMechanismBoundaryTests.swift` 第 3、90–193、195–313 行
- 合图时保留现有分页和增量解码类型门。定向验证覆盖原百人线程与返回值、晚取消、换代撤销、备份等待期间退役及当前 401/TLS 和合法备份重放。

## WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111

- 仅现有 `GET /api/tenant/org/members`（含 `department_id`）与 `RemoteOrganizationMemberList` 使用已检查 Sendable 的 typed 列表传递。成功、错误及登录安全封套仍由原 codec 顺序解析。百人资料复用同一内部传递，保原门与检查位置。
- 标识位于 `BlueStoneIM/Core/Networking/IMAPIClient+RequestExecution.swift`、`IMAPIClient+ResponseAndLogging.swift`、`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+OrganizationDirectorySync.swift`、`Sources/IM4Data/NetworkingDTO/RemoteDirectoryModels.swift` 及 `BlueStoneIMTests/DataDirectoryContactDTOBoundaryTests.swift`。
- 当前标识行区间
  - `Sources/IM4Data/NetworkingDTO/RemoteDirectoryModels.swift` 第 114、239 行
  - `BlueStoneIM/Core/Networking/IMAPIClient+ResponseAndLogging.swift` 第 13–72、166–239 行
  - `BlueStoneIM/Core/Networking/IMAPIClient+RequestExecution.swift` 第 90、125、154、174、184、217、225、257、258、283、357、374、454–456 行
  - `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+OrganizationDirectorySync.swift` 第 314–322、328–344 行
  - `BlueStoneIMTests/DataDirectoryContactDTOBoundaryTests.swift` 第 3、391–674 行
- 合图保留 owner 与作用域、同作用域续权成功、过期 401/撤销拒绝和原 GET 传输共享。沿原 600 人夹具、原目录定向合同及资料传递对照验证，实测见隔离交接。

<!-- WDT_IOS1_ORG_MEMBERS_QUERY_ENCODING_20261111_BEGIN -->
- `BlueStoneIM/Core/Networking/IMAPIClient+Contacts.swift:65–73` 组织成员 GET 请求保留既有 Contacts helper 生成的百分号编码。自定义部门 ID 中的 `&` 与 `+` 在最终 URL 中仍属于 `department_id` 值，空输入仍省略查询参数。
- `BlueStoneIMTests/DataDirectoryContactDTOBoundaryTests.swift:211–294` 通过真实 SDK 与 URLSession 核对最终 URL、鉴权头、普通和空输入、混合字符及主备重放。本节与资料 P2/P3、M9 typed decode 一起准备，组合回退以冻结的整树反向补丁为准。
- 原资料 4P、M9 6P 和查询 2P 分别绑定原制品。当前组合仅做源码核对，组合构建与定向待原 R2。
<!-- WDT_IOS1_ORG_MEMBERS_QUERY_ENCODING_20261111_END -->

<!-- WDT_IOS1_ORG_MEMBERS_PREFERRED_PROBE_AUTHORITY_20261111_BEGIN -->
- `BlueStoneIM/Core/Networking/IMAPIClient+RuntimeRouting.swift:289–349` 仅组织成员 GET 的延迟首选探测独立于目录刷新 ID，沿用现有路由快照、租户世代和完整会话授权。有效首选请求的成功及实际失败继续记账，本地取消、策略拒绝或退役退出时保留稳定探测计数。主备和既有 URL 选项保持原合同。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+OrganizationDirectorySync.swift:320` 探测复用的原目录授权闭包同时校验登录状态；前台同作用域续权的成功发布条件保持原样。
- `BlueStoneIMTests/DataHTTPMechanismBoundaryTests.swift:315–498` 以真实 App 目录刷新、GET 路由和可控等待覆盖刷新结束后首选探测、会话退役、本地取消及实际失败。原组合 4P 和旧 4P、6P、2P 属各自原制品，修订定向见交接。回退使用本 finding 的反向补丁。
<!-- WDT_IOS1_ORG_MEMBERS_PREFERRED_PROBE_AUTHORITY_20261111_END -->

<!-- WDT_IOS1_STICKER_MANIFEST_DATA_20261111_BEGIN -->
- Stores62 贴纸 manifest 持久化。本组合投影的唯一父为 `98330d2b6bdae2eeafdd8471fbd3909d88ae9096`，原 Data 迁移为 `fc7f59516754b537472e7c5adbc53ec1888d15a2`，`Sources/IM4Data/StickerManifestRecordStore.swift:1–53` 复用原 `CachedStickerManifest` typed 记录，接管键、编解码、scope/schema 校验、占位/签名 URL 清理和 UserDefaults 写入。保留原 `im2.ios.stickerManifest.<hash>`、原 schema v1 及只在编码成功后写入的行为。
- `Sources/IM4Stores/StickerStore.swift:5,22,26,46,269` 保留激活、缓存发布、排序、刷新和错误状态，移除 Store 内原 key/JSON/IO 代码。`Package.swift:287` 仅登记既有 IM4Data 显式源码列表的必需 Swift 文件。本段覆盖持久化，App 贴纸入口的刷新保护见下一段。
- `BlueStoneIMTests/DomainOlderHistoryAndConversationListTests.swift:205–215,224–241,254–262,402–416,470–479` 保留原用例并核旧 key/schema、挂载冷缓存、错 scope 拒绝、原 App hydration 先于刷新及签名过滤。挂载走隔离 defaults，原 App 默认 store 用唯一合成 key，校验无旧条目并在结束清除。首轮发现原过滤遗漏 `sig`，`Sources/IM4Domain/StickerLibraryStateModels.swift:376–382` 仅在持久副本中过滤这个精确查询参数，保留运行时渲染 URL 和旧缓存读取。原迁移制品正常 Debug、最低部署 iOS 15.0，C7 定向 4/4。源证据及组合投影的验证边界见 handoff。
- `PROD_MUTATION=false` `AUTO_ROLLBACK=false` `NEW_DEPLOY_SURFACE=0` `JENKINS_CHANGE=0` `SECRET_PLACEMENT=unchanged`。
<!-- WDT_IOS1_STICKER_MANIFEST_DATA_20261111_END -->

<!-- WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_BEGIN -->
- iOS1 贴纸 manifest 刷新晚到保护，原刷新修复为 `4d24368f72bacb9a85b9aef06ac0eebdadeb2380`，随 Data 迁移投影到同一候选。 `AppState+StickerLibraryActions.swift:286–414,455–473` 对实际清单请求使用 scope、绑定 generation、已有 auth authority/credentialsAdvanced 合同及本次 refresh ID，await list 和 hydrate 后验证同一 owner 才发布、持久化、更新刷新状态或排轮询。旧结果与错误均不接管当前请求。
- `AppState+StickerLibrary.swift:23,54–68` 在既有 context 变更入口退休不兼容绑定并保护缓存补齐和后续刷新。 `AppState.swift:475–479` 与 `AppState+RemoteAuthState.swift:396` 接已有退出/reset，普通同 epoch 凭据续期仍有效，同 scope 重认证保留可见缓存并退休旧 epoch，A→B→A 使用新绑定。 `AppState+StickerUploadAndHydration.swift:169–184,195,200,203,255,263,269,294,297,304,318,362–383` 在 metadata 返回和进入既有资产处理前检查，轮询睡醒后先验原绑定再发请求。
- `BlueStoneIMTests/DomainOlderHistoryAndConversationListTests.swift:482–605,1153–1258` 的单一实际 SDK 入口用例在 file-detail 补齐挂起时覆盖 scope 切换、A→B→A、同 scope 重认证、force 替换和合法凭据续期，并读回两个合成缓存键。原刷新制品正常 Debug、最低部署目标 iOS 15.0，C7 新增用例 1/1。当前组合投影的索引保留实际父全部字节并按顺序追加两段，整族回退用组合反向差分。源证据与组合验收入口见 handoff。
- `PROD_MUTATION=false` `AUTO_ROLLBACK=false` `NEW_DEPLOY_SURFACE=0` `JENKINS_CHANGE=0` `SECRET_PLACEMENT=unchanged`。
<!-- WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_END -->

<!-- WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN -->
- R2 复审修订基于 `557f8513a1ae3f52890f8ca67758b4937bd3bd78`，组合候选投影到实际父 `98330d2b6bdae2eeafdd8471fbd3909d88ae9096`。`Sources/IM4Domain/StickerLibraryStateModels.swift:375,378,393–399` 对可解析的根相对、路径相对、协议相对和绝对 URL 引用检查签名查询，保留 v1、稳定定位和运行时 URL。
- `BlueStoneIM/AppState.swift:477,478,567–571,584`、`BlueStoneIM/Core/AppSupport/AppState+StickerLibrary.swift:51,56–67,301–310,315,329,374,377,420,422,428,434–440,457`、`BlueStoneIM/Core/AppSupport/AppState+StickerLibraryActions.swift:305–338,342,363–374,382–389,399,456–472` 和 `BlueStoneIM/Core/AppSupport/AppState+StickerUploadAndHydration.swift:170–385` 让冷准备和刷新共用操作归属，退役准备不能发出 force；下载补齐保持同会话续期合同，消息资源沿原授权检查。
- `BlueStoneIM/Core/AppSupport/AppState+IndexedMediaCache.swift:66,68,102–114,140,146,162,164,192–205,264` 与 `BlueStoneIM/MediaLayeredCache.swift:330,332,399,401` 在异步准备后将操作归属传到文件接纳点，已接纳的写入按原 scope 合同完成 SQLite 索引。退役任务不能接纳迟到字节或复制到暂存目录。
- `BlueStoneIMTests/DomainOlderHistoryAndConversationListTests.swift:166,196–201,220,221,245–252,607–773,1155–1165,1172–1180,1187–1200,1214,1220–1229,1260–1300` 扩充原 Store/v1 用例，并覆盖挂起下载、索引与暂存正控、凭据续期、旧冷准备晚归以及当前清单提交。原 `2c7fd805042caa6e9114c44828ba2ba15a5c59e7` 的 Debug 制品在 C7 定向 7/7。本次为实际父上的源码投影，回退差分见交接。
- `PROD_MUTATION=false` `AUTO_ROLLBACK=false` `NEW_DEPLOY_SURFACE=0` `JENKINS_CHANGE=0` `SECRET_PLACEMENT=unchanged`。
<!-- WDT_IOS1_STICKER_MANIFEST_R2_20261111_END -->

## iOS1 阶段 0 · 聊天守卫的语法范围核对

- `WDT_IOS1_REFACTOR_CHECK_CHAT_AST_SCOPE_20261111` 对应 `scripts/refactor-check.sh:207–591`。在原阶段 4 内复用 Swift frontend parse，只取 `ChatView` 和三类已挂载叶的声明与扩展，按显式 AppState 绑定判断可执行成员读取。Swift 插值保留，相邻声明、普通局部值、注释和纯字符串保持通过。R2 原定向反例、冻结旧源码和 B `a0aa2915` 的源码正向已复核。阶段 2/3、正常入口及 PNG 零容差流程保持原字节。候选 `78cc083b`，正反补丁和原 R2 待复审状态见 `/private/tmp/im4-ios1-stage0-guard-r2-fix-20261111/HANDOFF.md`。

## iOS1 阶段 0 · 千会话首屏企业策略 fixture

- `WDT_IOS1_STAGE0_ENTERPRISE_POLICY_SNAPSHOT_FIXTURE_20261111` 在 `BlueStoneIMTests/DomainStoreTests.swift:256` 的原千会话测试中，用每轮独立 Debug appID 和现有内存策略入口固定 `allowWorkspaceSwitch=false`。首屏原捕获点校验有效权限，原 22 条断言及截图名称保留。仅源码解析和补丁回放已通过，原 R7 复验以官方 xcresult 和逐图记录为准。源码 `6292f538`，受控旧源及回退见 `/private/tmp/im4-ios1-b5-style-diff-diagnosis-20261111/HANDOFF.md`。
- `WDT_IOS1_STAGE0_SNAPSHOT_PERSISTENCE_ISOLATION_20261111` 对应 `BlueStoneIMTests/DomainStoreTests.swift:265–289`。记住登录使用测试内存替身，注入夹具独占 defaults、消息库及缓存路径。窗口挂载、断言和 PNG 捕获保持原入口。

## iOS1 阶段 0 · Me 首页企业策略 fixture

- `WDT_IOS1_STAGE0_ENTERPRISE_POLICY_SNAPSHOT_FIXTURE_20261111` 在 `BlueStoneIMTests/IdentityAuthRoutingTests.swift:315` 的原 Me/头像测试中，用另一个每轮独立 Debug appID 固定内存 `allowWorkspaceSwitch=true`，保留空假传输和真实页面刷新。Me 的三个捕获点校验有效权限，原 3 条断言与头像附件保留。仅源码解析和补丁回放已通过，原 R7 复验以官方 xcresult 和逐图记录为准。源码 `6292f538`，受控旧源及回退见 `/private/tmp/im4-ios1-b5-style-diff-diagnosis-20261111/HANDOFF.md`。
- `WDT_IOS1_STAGE0_SNAPSHOT_PERSISTENCE_ISOLATION_20261111` 对应 `BlueStoneIMTests/IdentityAuthRoutingTests.swift:324–354`。记住登录使用测试内存替身，注入夹具独占 defaults、消息库及缓存路径。窗口挂载、断言和 PNG 捕获保持原入口。

## iOS1 阶段 0 · 截图夹具 API 启动上下文

- `WDT_IOS1_STAGE0_SNAPSHOT_API_STARTUP_CONTEXT_20261111` 对应 `BlueStoneIM/Core/Networking/IMAPIClient.swift:226–228`、同文件 `304–306` 及 `BlueStoneIMTests/DomainStoreTests.swift:275`、`BlueStoneIMTests/IdentityAuthRoutingTests.swift:339`。两条夹具将自己的合成 context 传给 API 构造，避免调用设备会话加载。默认参数保留原加载位置和路由撤销处理。原 R7 用既有只读 Debug 宿主复验两项和四对 PNG。

<!-- WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_BEGIN -->
- Data17 M17 通话历史。原实现 `3a1c077337eeb3e98fa0fc6d0a690b01a5ae847a`，本投影父为 `bef3d7644f6d51422d6dc83a047fe8865e5a3f48`，`Sources/IM4Stores/CallStore.swift:73–93,197–350` 以进程内单一 FIFO 把实际 App adapter 的整档 load、fallback migrate、scope read-modify-write 移离 MainActor。App 原调用保持同步发起，后台结果按绑定身份回主线程。相同 scope 的重复绑定复用进行中或完成的绑定。已接纳的旧 scope 写入保持原 scope，有效待写记录先于同一 scope 的下一次读。
- 新绑中产生的记录与原档按行/通话身份合并。挂断失败在 `AppState+ActiveCallActions.swift:178–181,271` 只回退本次通话记录，保持即时乐观展示，避免恢复的其他历史被旧快照覆盖。重叠的归档行可供同一绑定的回退还原。保原 disk-first、defaults fallback、schema v1、原子替换、可信 scope 选择，继续使用原 `UserDefaultsCallRecordStore` 与 IM4Data 实现。诊断 actor、RTC 信令和 UI 文件维持现有入口。
- `AppState.swift:85,531,595` 使用既有构造方式注入 CallStore 以跑正常冷启动分支。`DomainFileLifecycleAndCallStoreTests.swift:593–858,926–969` 保留原 scoped/raw 断言并等待异步发布，补真实冷登录、在途切换、写后重新构造和后台线程验收。依赖已整合 IM4Stores/IM4Data typed archive 与原 App scope 策略。候选的共享索引段单独追加，Root 保留实际合流前缀；回退只逆转本标识相关 hunks。原实现制品的正常 Debug / iOS 15.0 deployment target 和 C7 定向 12/12 通过，覆盖原归档兼容、真实冷登录、scope 退役、碰撞行回退、写后重新构造和后台 I/O。同磁盘重读由同一进程中第二次 AppState 构造验证。原 `1cb403ca8ec9c2f37a5a2655baa92e3b03531ed0` 上的同图 C7 1 项通过和 9 次后台 I/O 保留在原制品。本次源码投影与证据适用范围见 handoff，提交可用 `git log -S WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111` 定位。
- `PROD_MUTATION=false` `AUTO_ROLLBACK=false` `NEW_DEPLOY_SURFACE=0` `JENKINS_CHANGE=0` `SECRET_PLACEMENT=unchanged`。
<!-- WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_END -->

## WDT_IOS1_CHAT_CONTACT_CARD_FEATURE_PROJECTION_20261111

- `BlueStoneIM/App/ChatBubbleMetadataAssembly.swift` 第 14–24 行在原名片挂载入口传入已有目录快照和企业显示作用域。目录缺省和企业缺省仍由 App 原值提供。通话装配及原外层气泡/打开联系人命令保持。
- `Sources/IM4Features/Chat/ChatBubbleMetadataViews.swift` 第 48–87 行在原名片 View 构造内完成展示映射。原目录匹配顺序、附件名和正文优先级、缺省联系人字段、头像 seed、认证 UID 和原按钮体保持。
- `BlueStoneIMTests/ChatTimelineRowFactoryTests.swift` 第 448–505 行准备值合同。`BlueStoneIMTests/ComposerInputBoundaryTests.swift` 第 646–692 行复用隔离夹具，挂载实际 App 名片和同字段的既有 Feature 参考，覆盖目录更新和恢复。正常构建与定向运行待实际父确认。

<!-- WDT_IOS1_HTTP_RESET_LATE_CLAIM_20261111_BEGIN -->
- `Sources/IM4Data/Networking/HTTPInFlightRequestStore.swift:4–52` 对应 IOS1-HTTP-RESET-LATE-CLAIM-BASELINE。共享 GET 的创建方只清除自己的注册；借用方与空 key 无注册归属。原 `reset()` 仍仅清登记，已发 Task 继续完成。
- `BlueStoneIMTests/HTTPHeadersRemarksAndRTCContractTests.swift:146–199` 以受控 Task 验证 reset 后同键替换、旧创建方迟到、后续借用和真正创建方释放。原 SDK 的 claim/defer/finish 入口保持现状。原失败保存在旧交接，本候选的定向结果单独绑定，回退用对应反向补丁。
<!-- WDT_IOS1_HTTP_RESET_LATE_CLAIM_20261111_END -->

<!-- WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111_BEGIN -->
- `BlueStoneIMTests/HTTPRegistrationAuthorityAndInviteTests.swift` 第 206、295 行包住原 A17 配额截图用例。对照 iOS1 引入提交与 AuthFlipView，保企业码和四场景断言，校正注册预填的两项占位值。注册路由的已解析策略由测试注入，截图默认入口沿用原行为。
- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift` 第 46、50、71、79、83、122、126、313 行允许四场景使用测试私有默认值。注册清理使用注入的 session store；在线夹具仍走原策略入口。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+ProfileAndTenantAuthority.swift` 第 269、286、321 行将原群人数策略缓存读写导向调用方给定的默认值域，普通调用及截图默认仍为标准域。测试使用独立消息、发现及偏好目录和内存保护存储，原失败与新单用例证据独立保存。
<!-- WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111_END -->

## WDT_IOS1_CHAT_TOP_CONTEXT_FEATURE_20261111

- `BlueStoneIM/App/ChatTranscriptLayoutAssembly.swift` 第 278–295 行沿原 `ChatScreenColumn.top` 接入 Feature，使用原公告观察、置顶投影和渲染 builder。搜索的显示条件、padding 和 transition 仍由 App 原位置提供。
- `Sources/IM4Features/Chat/ChatScreenLayout.swift` 第 48–63 行按公告、非空置顶、搜索顺序组合原三个子项，保留原空分支及惰性求值，沿用 `ChatScreenColumn` 的原容器。该组合不引入状态、订阅或布局层。
- 源码和独立小检记录四种置顶／搜索状态的顺序、调用次数和具体 ViewBuilder 类型一致。原公告挂载及回执范围见隔离交接，正常构建和设备验证待实际父确认。

## WDT_IOS1_CHAT_TOP_CONTEXT_FIXTURE_ISOLATION_20261111

- `BlueStoneIMTests/ChatHeaderStatusBoundaryTests.swift` 第 126–155、260–268 行沿用原公告传输、测试偏好域、内存会话和注册恢复存储、非持久身份投影。通过 D 的 `startupContext` 让实际 SDK 与 AppState 共用合成会话，选定用例退役后移除自己的偏好域。
- 同文件第 62–122、278–280、307–368 行在原公告用例内挂载顶部 ViewBuilder 和列容器，测量公告、非空置顶、搜索、时间线的顺序，以及去除置顶和清空后的布局。真实聊天页另验证置顶输入和原搜索动作。原公告挂载、详情、回调退役及 ACK 断言保留。
- 名片 `caab7f4c` 为此顶部候选的唯一父。正反补丁和本图验证见独立交接。

<!-- WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111_BEGIN -->
- 阶段 3 第 5 项。基于 `b154ff44c7e7ddb7633e40c05d7c8fd5d831dd79`，`BlueStoneIMTests/PagedSnapshotCommitTests.swift:141–488` 保留原同进程断言，复用真实消息编辑、SQLite 持久化及 AppState/Store 恢复入口。新增成对选择器验证两个 XCTest 宿主依次打开同一合成作用域的 SQLite 文件，按容器内路径和 inode 校验，断言正文、editRevision、编辑标记及零 HTTP/实时请求。
- 测试 runner 通过 XCTest 配置传递同一 UUID，只访问合成会话、独立 defaults 和专用归档。原运行和只读宿主补验归 `4af80f096814e5dabff9f4d7d9959e5ad361def9` 制品。本次源码投影与清理证据见交接。
- `PROD_MUTATION=false` `AUTO_ROLLBACK=false` `NEW_DEPLOY_SURFACE=0` `JENKINS_CHANGE=0` `SECRET_PLACEMENT=unchanged`。
<!-- WDT_IOS1_OFFLINE_EDIT_PROCESS_RESTART_20261111_END -->

<!-- WDT_IOS1_PHASE6_NATIVE_MOUNTED_CHAIN_20261111_BEGIN -->
## WDT_IOS1_PHASE6_NATIVE_MOUNTED_CHAIN_20261111

- `BlueStoneIMTests/RealtimeBackgroundComputeTests.swift` 第 597–729 行增强现有挂载历史用例。原聊天入口经合成 URLProtocol 和真实 URLSession 拉取历史，验证一次后台派生、物理响应与派生关联、同一 Store 提交及挂载投影修订、最近 20 条消息 ID 与序号。
- 同文件第 1036–1095 行为该用例使用独立偏好和持久化目录、内存会话与注册存储。通过实际 SDK 取得夹具策略后预热内存，正常请求门继续生效。
- 本次投影以 `1394208c48eeb0180012832f6aafb9666a2c6796` 为唯一父，保留父版本完整索引和离线重启夹具。测试源码与 `39e683722d579869f5009aa19cded95b5cf01cb3` 同字节。该提交的 C7 定向结果仅用于挂载历史单项，见原 Core 交接。
<!-- WDT_IOS1_PHASE6_NATIVE_MOUNTED_CHAIN_20261111_END -->

## WDT_IOS1_CHAT_GIF_RENDER_PRESENTATION_20261111

- `BlueStoneIM/App/ChatMediaBubbleAssembly.swift` 第 39–54 行保留播放资格、会话 scope、原 URL 解析顺序及原缓存键。已有 GIF 恢复和占位闭包继续从原入口传入。
- `Sources/IM4Features/Chat/ChatMediaBubbleViews.swift` 第 355–378 行由现有 `AttachmentGIFPresentation` 生成渲染输入，沿用原资源排序、播放资格与本地优先级。气泡、长按和附件预览共用原入口。
- 本轮为源码验证。原 GIF 挂载和 URL 策略用例见交接，正反补丁均以同一候选父为基准。

## WDT_IOS1_CHAT_GIF_MOUNT_FIXTURE_ISOLATION_20261111

- `BlueStoneIMTests/ChatReplyMediaBoundaryTests.swift` 第 149–186、205–209 行仅隔离原 GIF 挂载选择器。SDK 和 AppState 使用同一合成会话，测试偏好、注册和保护存储、消息及媒体根独立。保原实际 GIF 装配及断言，另核 scope/generation 缓存键和本地优先级。
- GIF 生产后像复用 `06b35f488`，实际父为 `1394208c`。纯值测试及本图挂载证据见交接。


## WDT_IOS1_CHAT_GIF_ENTRY_MOUNT_20261111

- `BlueStoneIMTests/AttachmentDetailBoundaryTests.swift` 第 13–26、32、40 行复用原宿主、等待、退役和全屏 cover，仅开放测试模块内可见性。
- `BlueStoneIMTests/ChatReplyMediaBoundaryTests.swift` 第 188–299 行复用安全 GIF 夹具和原诊断。原 `38e1325f` 的单选择器实挂长按预览入口与真实全屏 cover，验证本地 URL 优先、撤回后不可播放且播放 URL 为空，以及全屏关闭。原实跑未模拟长按手势，未采集像素。此修正沿用原两份 Swift 后像和同源码 1P。
- 旧 `WDT_IOS1_CHAT_GIF_MOUNT_FIXTURE_ISOLATION_20261111` 中的 `1394208c` 仅指历史 `fc573fa0` 的实际挂载父。当前 Main `a4c0237b` 的实际父为 `7e31850`，本条索引修正以 `a4c0237b` 为唯一父。

<!-- WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_BEGIN -->
## WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111

- `BlueStoneIM/RealtimeFrameDecoder.swift` 第 16–97 行在现有 WebSocket 和 QUIC 接收 actor 上准备 extra 与 receipt 的 DTO。嵌套对象优先，解码失败继续尝试扁平载荷。已尝试但无值的结果仍携带类型。
- `BlueStoneIM/Core/Networking/DTO/RemoteMessageEventModels.swift` 第 27 行携带可选解码结果。`AppState+RealtimeMessageExtras.swift` 第 29–44 行和 `AppState+RealtimeEventDispatch.swift` 第 217 行消费结果或沿同步入口原解码器处理，沿用现有 flush、作用域、Store 和恢复路径。
- `BlueStoneIMTests/RealtimeBackgroundDecodeTests.swift` 第 301–545 行复用原传输夹具，覆盖两种接收循环、同批有序应用和去重、坏输入、同步注入及过期会话。本次投影以 `99e279f68c0324851fab00927a3ce7bc1e1859d1` 为唯一父。五个 Swift 后像与 `ded369117f867c8069dffc13a128fe5944053fee` 同字节，原 C7 三项定向结果仅在对应入口范围复用，见原 Core 交接。
<!-- WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_END -->

## WDT_IOS1_GROUP_DIRECTORY_MOUNT_LOCAL_TRANSPORT_20261111

- `BlueStoneIMTests/IdentityContactPresentationTests.swift` 第 123–135、167–174、199 行只为原群目录挂载选择器注入合成传输和独立租户，并断言真实 `GroupListView` 发出的群摘要 GET 到达该传输。原成员数、创建按钮、PNG 比较和 AppState 发布断言保留。
- `BlueStoneIMTests/IdentityPresentationTests.swift` 第 603–633、653–659 行为该选择器提供同一合成启动会话、独立偏好及内存会话。原共享群夹具调用方保留默认初始化和身份投影。
- 证据、唯一预计父及回退补丁见独立交接。

<!-- WDT_IOS1_WIRE83_FIXTURE_ISOLATION_20261111_BEGIN -->
## WDT_IOS1_WIRE83_FIXTURE_ISOLATION_20261111

- `BlueStoneIMTests/AppBootstrapLastGoodTests.swift` 第 8–43 行为原 serving host 与 App ID 缓存用例注入 UUID suite，保存、查询与清理复用现有 LastGoodStore，移除该用例的标准域清理。
- `BlueStoneIMTests/HTTPVerificationContactAndRemarkTests.swift` 第 8–110 行移除原标准域清理，使用合成 HTTP、独立偏好和目录、内存会话及原验证入口。保留初次刷新与新 AppState 模拟重登录后的验证断言。
- 依赖原 IMAPIClient 启动上下文、测试夹具和独立存储入口。按本标识合并两份测试文件并保留实际父的索引。其余九个已确认标准域写入用例继续使用隔离容器。
- 功能后像来自 `fc974b991ffd2635dc41eb3fa13339513e561de1`。为满足 800 行上限，验证测试文件在已跑用例的第 8–110 行之后移除 32 个空行，原断言和注释保留。原 Debug 定向为 2P、0F、0Skip，原 83 在该制品上另有 81 UNRUN。正反补丁与制品绑定见 A 交接。
<!-- WDT_IOS1_WIRE83_FIXTURE_ISOLATION_20261111_END -->

<!-- WDT_IOS1_TYPED_FRIEND_GROUP_MEMBER_LIST_DECODE_20261111_BEGIN -->
## WDT_IOS1_TYPED_FRIEND_GROUP_MEMBER_LIST_DECODE_20261111

- `BlueStoneIM/Core/Networking/IMAPIClient+ResponseAndLogging.swift` 第 35–85、202–244 行把两个 GET 的精确路径与响应类型匹配纳入原 typed WireCodec 传输。好友、备注新鲜读取、群成员及分页复用原请求入口和错误分类。
- `Sources/IM4Data/HTTPEnvelopeRecords.swift` 第 334 行为 RemoteList 加条件 Sendable。`Sources/IM4Data/NetworkingDTO/RemoteContactModels.swift` 第 4 行为好友关系 DTO 加 Sendable。群成员 DTO 沿用现有 Sendable，分页字段保持原模型。
- `BlueStoneIMTests/DataHTTPMechanismBoundaryTests.swift` 第 500–731 行用实际 URLSession 与合成传输验证消费者、类型匹配、去重、备注缓存、分页、旧群作用域、401、423 和取消。按标识合并四份 Swift，保留既有组织成员与 Core 实时解码范围及父索引。
- 功能后像来自 `e2bb4975df21f3e6c921c4fe0d07f6dea7e9087c`。原 Debug 定向为 3P、0F、0Skip。保留 `68c3a875f88df54158f3ceab06c602ac5cccc67d` 首轮 2P/1F，其中 423 文案断言已按既有中文映射修正。正反补丁与原制品绑定见 A 交接。
<!-- WDT_IOS1_TYPED_FRIEND_GROUP_MEMBER_LIST_DECODE_20261111_END -->

## WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111

- `BlueStoneIMTests/FeatureRoutingNavigationTests.swift` 第 1、11、84、118、167、237–258、337–428 行将原路由挂载和共享直聊／群聊夹具接到进程内记录传输。群摘要、置顶、租户策略及验证状态的合成不可用响应保留原本地种子。请求方法、主机和路径可核，未知请求拒绝。每个实例有独立偏好、启动会话、内存保护存储和消息根。
- `BlueStoneIMTests/IdentityChatPresentationTests.swift` 第 552–607、768 行，`IdentityContactPresentationTests.swift` 第 397、435、567、694 行及 `IdentityAuthRoutingTests.swift` 第 126、409 行，仅切换本批其余真实挂载入口的前置。原页面、PNG 和业务断言保留。
- `BlueStoneIMTests/IdentityPresentationTests.swift` 第 569–574 行为原直聊测试夹具增加可选隔离状态。现有调用默认构造路径与第 40 项群目录隔离保留。精确 13 项、实际请求和原生验证见独立交接。

<!-- WDT_IOS1_CORE_FULLSUITE_FIXTURE_TRANSPORTS_20261111_BEGIN -->
## WDT_IOS1_CORE_FULLSUITE_FIXTURE_TRANSPORTS_20261111

- `BlueStoneIMTests/DomainOlderHistoryAndConversationListTests.swift` 第 457–492 行为贴纸水合夹具注入合成下载失败，沿用原冷缓存、元数据 transport、先水合后刷新及签名清理断言，并记录实际三条文件请求路径。
- `BlueStoneIMTests/DomainRTCInboundAndColdLaunchTests.swift` 第 136–231 行以既有合成媒体和记录 API 验证原 answered_elsewhere 次序。SDK 与 AppState 共用合成启动 context，SDK 路由使用该用例的 UUID 偏好域。另用原不可用媒体入口触发拒接，验证同一 AppState 的异步请求和终态。
- `BlueStoneIMTests/SnapshotCacheTests.swift` 第 481–545 行保留原重连回调和提示时序，使用已有 HTTP 注入和独立偏好，并核对回调实际请求本地 profile。原冷恢复用例沿用父版本。
- 原定向候选以 `e69f1aa3d6bff39760c79d4904b07bad0d73b358` 为唯一父。本次投影唯一预计父为 `799c0fc398d950305c3476ef1a980d517e6ea188`。定向结果和出站审计见原 Core 交接。
<!-- WDT_IOS1_CORE_FULLSUITE_FIXTURE_TRANSPORTS_20261111_END -->

<!-- WDT_IOS1_WIRE83_FRIEND_PRESENCE_POLICY_FIXTURE_20261111_BEGIN -->
## WDT_IOS1_WIRE83_FRIEND_PRESENCE_POLICY_FIXTURE_20261111

- `BlueStoneIMTests/HTTPRuntimeRouteAndOutboxTests.swift` 第 503–509 行在原好友在线状态测试的隔离认证状态安装既有合成应用策略，有效期 60 秒。真实强制认证门读取有效缓存，原假传输用于好友接口。保留单路径、联系人和展示断言。
- 原 799 官方 83 项为 82 通过、1 失败，失败请求序列多出 current-policy。复用既有策略夹具和安装入口，按标识合并并保留父索引，回退采用本候选逆向补丁。源码解析与夹具核对通过，待执行原单项 XCTest。
<!-- WDT_IOS1_WIRE83_FRIEND_PRESENCE_POLICY_FIXTURE_20261111_END -->

<!-- WDT_IOS1_SPLIT_REALTIME_DOMAIN_TEST_SOURCES_20261111_BEGIN -->
## WDT_IOS1_SPLIT_REALTIME_DOMAIN_TEST_SOURCES_20261111

- 以 `799c0fc398d950305c3476ef1a980d517e6ea188` 为基线拆分两个 XCTest 源。原 `DomainStoreTests` XCTestCase 及 `@MainActor` 声明留在 `BlueStoneIMTests/DomainStoreTests.swift:11–12`。源码契约方法及其 `#filePath` 读取仍在同文件 748–763 行。
- `BlueStoneIMTests/RealtimeBackgroundComputeTests.swift:1–698` 保留实时 WebSocket 和 Phase6 HTTP 推导的 14 个测试。挂载历史和顺序补洞的 4 个原测试移到 `BlueStoneIMTests/RealtimeMountedHistoryAndRecoveryTests.swift:13–411`，原 URLProtocol 和 trace recorder 保持在同文件私有范围。两个文件分别保留同字节的 `phase6HTTPFixture`、`phase6Page`、`computeRow` 和 `computeMessage` 私有声明，以保持原访问边界和调用体。
- `BlueStoneIMTests/DomainStoreTests.swift:1–766` 保留 26 个原测试。三个联系人查找和投影测试移到已编译的 `BlueStoneIMTests/DataDirectoryContactDTOBoundaryTests.swift:677–757`，仍属于 `DomainStoreTests` 扩展，复用原夹具。
- `BlueStoneIM.xcodeproj/project.pbxproj` 仅给 `RealtimeMountedHistoryAndRecoveryTests.swift` 加入现有 `BlueStoneIMTests` target。合流时保留本条与同批其它变更索引及 target 引用。撤销以 D 的 inverse patch 恢复父树。
- Swift frontend parse、方法和私有范围等价、项目引用及四个文件行数已作静态核对。Wire83 选择器未触及。合流后用同一构建的官方枚举验证原 ID，设备运行与发布未执行。

<!-- WDT_IOS1_SPLIT_REALTIME_DOMAIN_TEST_SOURCES_20261111_END -->

<!-- WDT_IOS1_DOMAIN_TEST_SOURCE_SPLIT_20261111_BEGIN -->
## WDT_IOS1_DOMAIN_TEST_SOURCE_SPLIT_20261111

- DomainOlderHistoryAndConversationListTests.swift 386 行与 DomainStickerManifestTests.swift 13–579 行。四个贴纸清单用例、两个 private 方法和两个 private actor 原字节转移，XCTest 仍属 DomainStoreTests。
- DomainFileLifecycleAndCallStoreTests.swift 737 行与 RTCCallRecordProjectionTests.swift 554–780 行。冷登录归档、账号分离、磁盘恢复三个用例及 private GatedCallArchive 原字节转移。waitForCallArchive 与全部调用留原文件，XCTest 仍属 DomainStoreTests。
- RTCCallRecordProjectionTests.swift 第 2 行显式导入 Combine，供迁入归档用例的原 publisher 订阅。其它既有用例和本测试目标保持原归属。
- 新贴纸测试文件与 D 的新 Realtime 测试文件在合流中各注册一次，仍使用既有 BlueStoneIMTests Sources。

<!-- WDT_IOS1_DOMAIN_TEST_SOURCE_SPLIT_20261111_END -->

<!-- WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111_BEGIN -->
## WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111

- `BlueStoneIM/Core/Networking/IMAPIClient+ResponseAndLogging.swift` 第 37–86、216–259 行将群目录分页 GET 与 `RemoteList<RemoteUserGroup>` 接入既有类型化 WireCodec 后台传输。解码返回后检查取消，继续走原响应分类和会话围栏。
- `BlueStoneIMTests/HTTPProductionRoutingAndEnterpriseContextTests.swift` 第 2、442–475 行沿用原双页选择器及假传输，保留偏移与结果断言，加入第二页重复群和两次后台解码观测。
- 依赖既有 `RemoteList` 条件 Sendable 和群 DTO。按标识合并并保留父索引，回退采用本候选逆向补丁。Swift 6 语法解析、提取的路由和诊断断言及原夹具静态核验通过，正式双页 XCTest 待执行。
<!-- WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111_END -->

<!-- WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_BEGIN -->
## WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111

- `BlueStoneIM/Core/Networking/IMAPIClient+ResponseAndLogging.swift` 第 35–53、70–121、269–273 行仅为群目录分页检查刷新归属、会话 fence 和取消。匹配唯一 scope、limit、offset 及规范十进制偏移。`BlueStoneIM/Core/Networking/IMAPIClient+Groups.swift` 第 23–50 行在分页边界检查归属，通过既有百分号编码入口保留 scope 值和原分页参数。
- `BlueStoneIM/Core/Networking/IMAPIClient+RequestExecution.swift` 第 154、174、225 行在原失败分类与记账前转交错误供群目录退出。`BlueStoneIM/Core/Networking/IMAPIClient+RuntimeRouting.swift` 第 290–362 行为延迟探测复核会话和实际路由，探测生命周期独立于发起刷新代次。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+OrganizationDirectorySync.swift` 第 17–51 行绑定前台刷新所有权。`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+SecondarySnapshotSync.swift` 第 258–272 行同时绑定后台快照刷新代次。两处在投影和错误处理前复用原作用域、刷新代次及当前会话。
- `BlueStoneIMTests/HTTPProductionRoutingAndEnterpriseContextTests.swift` 第 442–475 行沿用双页后台解码与偏移断言，并验证首见对象内容。`BlueStoneIMTests/HTTPRuntimeRouteDataStorageContractTests.swift` 第 134–346 行覆盖第 0 页后台解码时切租户、同租户换会话、发起新刷新及主动取消，另核唯一查询项与当前 401/403/423。`BlueStoneIMTests/DataHTTPMechanismBoundaryTests.swift` 第 733–792 行验证延迟探测归属。
- 对应原 R2 finding `STALE_OWNER_AFTER_DECODE`、`CANCELLED_DECODE_UPDATES_COLD_LAUNCH`、`NONCANONICAL_PAGE_QUERY_MATCHES`。依赖既有 GET、WireCodec、会话和路由状态，保留旧标记与源码报告。隔离 Swift 6 断言及基于既有模块的源码类型检查通过。正式构建和 XCTest 待后续 exact 制品，修正和整项正反补丁见 A 交接。
<!-- WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_END -->

<!-- WDT_IOS1_GROUP_DIRECTORY_CANCEL_SELECTOR_20261111_BEGIN -->
## WDT_IOS1_GROUP_DIRECTORY_CANCEL_SELECTOR_20261111

- `BlueStoneIMTests/HTTPProductionRoutingAndEnterpriseContextTests.swift` 第 539–565 行复用隔离认证状态和现有无强制验证策略，设置 60 秒有效期。原取消用例等待假传输记录唯一的群目录第 0 页 GET 后取消，保留 401 输入、会话及提示断言，并核对总请求数。
- 对应 R2 `CANCEL_SELECTOR_CAN_PASS_ON_CURRENT_POLICY_REQUEST`。沿用六个选择器。按实际父 `03ee130a1` 投影整项群目录源码，保留父测试拆分、好友、RTC 和完整索引。基于既有模块的源码类型检查、等待谓词隔离验证和正反补丁校验通过，正式 XCTest 待同一绑定制品。
<!-- WDT_IOS1_GROUP_DIRECTORY_CANCEL_SELECTOR_20261111_END -->


<!-- WDT_IOS1_GROUP_DIRECTORY_CANCEL_TIMEOUT_20261112_BEGIN -->
## WDT_IOS1_GROUP_DIRECTORY_CANCEL_TIMEOUT_20261112

- `BlueStoneIMTests/HTTPProductionRoutingAndEnterpriseContextTests.swift` 第 551–559 行复用精确请求谓词。等待耗尽后若第 0 页 GET 仍未观测到，记录 XCTest 失败并由既有 defer 清理任务。共用等待助手、原 401 及成功路径断言保留。
- 对应 R2 `CANCEL_SELECTOR_CAN_PASS_ON_CURRENT_POLICY_REQUEST`。按实际父 `03ee130a1` 冻结，原六项选择器及父索引保留。现有模块类型检查和等待耗尽控制流隔离验证通过，正式 XCTest 待同一绑定制品。正反补丁见 A 交接。
<!-- WDT_IOS1_GROUP_DIRECTORY_CANCEL_TIMEOUT_20261112_END -->

## WDT_IOS1_RTC_HANGUP_POLICY_FIXTURE_20261112

- `BlueStoneIMTests/DomainRTCTerminalAndMainShellTests.swift:385` 显式调用 A 维护的 `installActiveAppPolicyForHTTPFixture(on:)`，为原真实请求门提供同 App scope 的有效内存策略。保留原 FakeHTTP 记录、首请求 hangup 与所有通话时间断言。需要原 A helper 落入实际组合后再编译和执行。

## WDT_IOS1_CANCELLED_RTC_LICENSE_FIXTURE_20261112

- `BlueStoneIMTests/DomainRTCTerminalAndMainShellTests.swift:430` 给原注销用户用例注入与当前用户匹配的合成 IM session、既有假 HTTP 和 no-op 语音媒体。原设置许可、真实许可门与注销用户提示保持原样。私有补丁通过 Swift frontend parse，XCTest 编译和运行待组合。按本次反向差分回退两条夹具与对应标识，保留其他作者索引。

<!-- WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112_BEGIN -->
## WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112

- `BlueStoneIMTests/RTCCallRecordMessageTests.swift` 第 4、584–732、735–799 行在既有 `DomainStoreTests` 增加写入和恢复两个 app-host 选择器。复用 `AppState` 冷登录归档绑定、`upsertVoiceCallRecord`、`CallStore` 和 `UserDefaultsCallRecordStore`。合成账号、电话状态与传输限制在测试进程。接收文件 799 行，原 M17 同进程用例留在 780 行的 `RTCCallRecordProjectionTests.swift`，复用原 XCTest target 引用。
- 两个进程用同一 UUID 目录和同一真实磁盘档案，各自使用专用 defaults suite。每阶段通过该 suite 和同一内存会话存储保存、加载合成会话，并将加载后的 context 传给 API 和 AppState。恢复端验证写入端 PID、文件身份、租户 B 的正向对照以及 A 的唯一终态。沿用隔离 app-host 和原 runner 的标准域核对。
- `BlueStoneIM/AppState.swift` 第 218、558、582 行为现有当前用户身份缓存增加 defaults 注入，普通 AppState 构造默认使用标准域。`Core/AppSupport/AppState+ColdLaunchSessionRestore.swift` 第 115、144 行和 `Core/AppSupport/RemoteSync/AppState+ProfileAndTenantAuthority.swift` 第 78–80 行统一使用该注入。M17 用例使用阶段 suite 进行冷启动恢复、身份写入及租户切换读取，并读回已缓存的身份。
- 实际父基线为 `9e6d47861d771db0563db9c3acc40428ab7cd151`。静态检查及正反补丁见 Core 交接。由原 reviewer 定向复审，回退可应用反向补丁。普通 RTC、APNs 和真机留给真实环境。
<!-- WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112_END -->

<!-- WDT_IOS1_RTC_FRIEND_SYNC_FIXTURE_20261112_BEGIN -->
## WDT_IOS1_RTC_FRIEND_SYNC_FIXTURE_20261112

- `BlueStoneIMTests/DomainRTCJoinAndPeerResolutionTests.swift` 292–298 行在现有作用域许可配置之前绑定合成 IM 身份，复用现有 FakeHTTP 和 no-op 语音客户端，继续验证原联系人同步提示。
- 源码见 Core `a598a84411e49fc158a39d6145162ae3c0511ae0`（`a04-core-forward.patch`）。本索引按 `c9999d887` 冻结组合核对，待实际父绑定后由原 R2/R7 验收。
<!-- WDT_IOS1_RTC_FRIEND_SYNC_FIXTURE_20261112_END -->

<!-- WDT_IOS1_RTC_VIDEO_ORDER_POLICY_FIXTURE_20261112_BEGIN -->
## WDT_IOS1_RTC_VIDEO_ORDER_POLICY_FIXTURE_20261112

- `BlueStoneIMTests/DomainRTCHeartbeatTests.swift` 206、391 行在原 provider 和 hangup 路径前调用 A 的同状态策略 helper。现有准备及操作 transport、策略过期、provider、hangup、租约续期、媒体状态和时序断言保持原字节。
- 先应用 A 的 `installActiveAppPolicyForHTTPFixture(on:)` 定义，再应用 Core `a598a84411e49fc158a39d6145162ae3c0511ae0` 的 `a04-core-forward.patch`。本索引按 `c9999d887` 冻结组合核对，待实际父绑定后由原 R2/R7 验收。
<!-- WDT_IOS1_RTC_VIDEO_ORDER_POLICY_FIXTURE_20261112_END -->

<!-- WDT_IOS1_ME_DEAD_STATUS_CARD_20261111_BEGIN -->
## WDT_IOS1_ME_DEAD_STATUS_CARD_20261111

- `ME-DEAD-STATUS-CARD` 移除 iOS1 本地静态 `IM4Features` 产品中未调用的 `Sources/IM4Features/Me/VerificationStatusCard.swift`，并移除 `BlueStoneIM/Features/Me/RealNameVerificationViews.swift` 的对应私有别名。
- Me 及强制实名认证入口继续经 `RealNameVerificationFlowView`、`RealNameVerificationContent` 渲染 `RealNameStatusHeroCard`。现有页面布局、常量和测试保持原样。
<!-- WDT_IOS1_ME_DEAD_STATUS_CARD_20261111_END -->

<!-- WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN -->
## WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112

- `Sources/IM4Data/NetworkingDTO/RemoteDirectoryModels.swift` 第 4、68 行将组织树及递归节点声明为编译器核验的 `Sendable` 值类型。收藏沿用既有 `Sendable` DTO。
- `BlueStoneIM/Core/Networking/IMAPIClient+ResponseAndLogging.swift` 的精确路由、归属检查和类型化传输，以及 `IMAPIClient+RequestExecution.swift` 的出站和记账入口，仅针对组织树 GET 与收藏列表 POST。沿用原请求方法、路径、参数、缓存、合流、错误分类及重放策略。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+OrganizationDirectorySync.swift` 的树刷新和 `BlueStoneIM/Core/AppSupport/AppState+FilesAttachments.swift` 的收藏页把 Store 请求归属、scope/epoch 和完整会话 fence 带入 SDK。分类前淘汰退役/取消响应，拒绝旧凭据的授权错误和安全阻断。同一 epoch 续票后仍允许当前请求消费成功及普通业务错误，旧凭据不产生路由记账、重放或探测。收藏在 AppState 安全处理入口复查授权。
- `BlueStoneIM/Core/Networking/IMAPIClient+RuntimeRouting.swift` 的延迟组织树探测复用原探测模型，以当前路由和原完整授权代替已结束的 Store 刷新 ID。取消在分类和冷启动记账前传播。
- 原组织树与收藏页测试保留。新增回归在 `BlueStoneIMTests/HTTPRuntimeRouteDataStorageContractTests.swift` 覆盖退役/取消的解码返回、当前 GET 备路和延迟探测、收藏新旧安全拒绝、同 epoch 续票成功及 POST 单次出站。复用 `BlueStoneIMTests/DataHTTPMechanismBoundaryTests.swift` 已有探测暂停夹具。
- 实际唯一父 `d0c12539b39df8dc57cd84994a096b06a894fed9`。替换未合入的 `2994a1495` 并保留原 R2 NEEDS_FIX 证据。离线检查、正常 arm64 Debug 构建和定向运行状态见 A 交接。回退以此单提交反向差分为界。
<!-- WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END -->

<!-- WDT_IOS1_M9_DECODE_FIXTURE_LATCH_20261112_BEGIN -->
## WDT_IOS1_M9_DECODE_FIXTURE_LATCH_20261112

- `BlueStoneIMTests/HTTPRuntimeRouteDataStorageContractTests.swift` 第 376–385、476–485、521–529 行复用现有加锁门闩，只暂停首个真实后台解码回调。等待失败时取消任务、释放解码并等待任务退出。原组织树和收藏业务断言继续保留。
- `BlueStoneIMTests/DomainHistoryAndReadReceiptTests.swift` 第 769 行开放既有 `Phase6AliasContentionGate` 的测试模块可见性，门闩实现和原调用保持原样。第 430、439 行所在的 M9 延迟探测用例在现有等待后直接断言 in-flight 槽已释放。
- 对应 `8245cc79` 原生 7 PASS、2 SIGTRAP 及 R2 非阻塞 P3。保留原结果与两份崩溃证据。与 `8245cc79` 相比生产源码、工程和签名配置逐字节一致，仍以 `d0c12539` 为唯一父。独立构建、三个受影响选择器及回退证据见原 A 交接。
<!-- WDT_IOS1_M9_DECODE_FIXTURE_LATCH_20261112_END -->

<!-- WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN -->
## WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112

- `BlueStoneIM/Core/AppSupport/AppState+RealtimeSequenceRecovery.swift` 第 354–355 行和 `BlueStoneIM/Core/AppSupport/RealtimeCompute/AppState+RealtimeCompute.swift` 第 59–69、92–108、128–138、173–175 行仅对当前 drain 中首次通过校验的普通单条消息启用增量提交。原 decode、merge、校验和回退入口继续生效，既有诊断计入派生排队和快照提取。
- `Sources/IM4Stores/ConversationStore.swift` 第 129–133 行和 `Sources/IM4Stores/ConversationStore+PreparedRealtime.swift` 第 9–15 行从已校验的 prepared merge 进入 scoped Store。 `Sources/IM4Stores/ScopedMessageMemoryStore.swift` 第 36–66、78–87、111–118、209–263 行仅对同 ID、窗口键一致且其余会话有序的当前 frame 原子更新目标窗、排序和未读。插入、结构冲突、批次与重入保留原提交路径。
- `Sources/IM4Stores/ConversationMemoryFrame.swift` 第 29–33 行和 Store 既有 `memoryCommits` 回调配合，在 DEBUG 读取实际已安装 frame 的目标会话及 revision。后续全量 stage 清除标识。发布顺序、业务事件和生产日志不变。
- `BlueStoneIMTests/RealtimeBackgroundComputeTests.swift` 第 11–120、140–150、167、198–202、211–228、260–262、281、292–306、320–329 行通过生产 WebSocket 入口核对同消息与实际安装 revision。重算和无关窗口对照共用已清理的群会话，避免后续群人数清理覆盖标记。孤立 ACK 在凭据轮换后核对一次原路径安装，并确认退休会话无安装。 `BlueStoneIMTests/ScopedMessageMemoryTests.swift` 第 76–207 行对照显式关闭增量、孤儿窗修复及通知重入。
- 实际父为 `483010cd9241bb6b802a658814803a10bc4f5d40`。保留 M9 文件和索引两节，复用 scoped memory、串行 worker 与现有 XCTest。用本标识定位单父提交，整项回退使用逆向提交。宿主 Store 对照与 iOS Debug 构建证据见 Core handoff，原生执行及列表首消费待原 R2 定向复审后由 R7 核实。
<!-- WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END -->

<!-- WDT_IOS1_PHASE6_TEST_FILE_SIZE_SPLIT_20261112_BEGIN -->
## WDT_IOS1_PHASE6_TEST_FILE_SIZE_SPLIT_20261112

- `BlueStoneIMTests/RealtimeBackgroundComputeTests.swift` 原第 686–767 行的 HTTP 别名、嵌套诊断和采样发射用例移至 `BlueStoneIMTests/RealtimeMountedHistoryAndRecoveryTests.swift` 第 635–721 行。目标文件已有四个逐字节相同的 private fixture 方法，访问范围和用例主体保持原样。
- `BlueStoneIMTests/ScopedMessageMemoryTests.swift` 原第 440–548 行的两项挂载转发用例及两个 private helper 移至 `BlueStoneIMTests/BatchForwardStateTests.swift` 第 523–633 行。第 3–7 行导入原挂载代码需要的模块，两个用例仍属 `DomainStoreTests`。
- 复用原 `BlueStoneIMTests` target 源文件注册。基于 `19dc3c1af1321a238412459f825ffabab0970e91`，iOS1 源码行数、Debug 测试包和选择器核验见 Core handoff，回退使用本提交的反向差分。
<!-- WDT_IOS1_PHASE6_TEST_FILE_SIZE_SPLIT_20261112_END -->

<!-- WDT_IOS1_COLD_RESTORE_FIXTURE_TRANSPORT_20261112_BEGIN -->
## WDT_IOS1_COLD_RESTORE_FIXTURE_TRANSPORT_20261112

- `BlueStoneIMTests/SnapshotCacheTests.swift` 第 354–387 行沿用现有 FakeHTTP、录制实时和本地会话夹具。独立 defaults、设备作用域和临时持久化目录由本用例持有，退出时取消真实完成入口安排的恢复 Task。保留原四条断言、恢复调度与重试延时。
- 精确父提交为 `7aab37223f0f7e50b7c4c6a6ff490e681335c588`。只合并本用例标识和本索引段。Swift 语法检查与两并发 arm64 Debug 测试包编译通过。原生 XCTest 未运行。单父候选及原选择器见 Core handoff。回退使用本提交的反向差分。
<!-- WDT_IOS1_COLD_RESTORE_FIXTURE_TRANSPORT_20261112_END -->

<!-- WDT_IOS1_SDK_DECODE_POLICY_FIXTURE_20261112_BEGIN -->
## WDT_IOS1_SDK_DECODE_POLICY_FIXTURE_20261112

- `BlueStoneIMTests/HTTPSDKSharedPhysicalTraceV3Tests.swift` 第 67–103 行的 `testSDKV3OriginalThreeDecodeBranchesEmitCapturedExecutionThroughSoleCoreBackend` 复用已解析的合成 App 策略，供真实策略门读取。三条原请求、两条后台及一条主线程解码、合成传输无到达样本的合同继续适用。按顺序核对传输的具体方法与路径。
- 以 `658e85fdbedd767705c77705da45442f0c22a616` 为唯一父。保留 signed `7aab372` 的 71 PASS、1 FAIL 原生回执，候选 Debug 编译及 R2 复审入口见原 A 交接。整合时追加本节并保留 Core 的索引增量。
<!-- WDT_IOS1_SDK_DECODE_POLICY_FIXTURE_20261112_END -->

<!-- WDT_IOS1_HTTP_DERIVATION_FIXTURE_ADMISSION_20261112_BEGIN -->
## WDT_IOS1_HTTP_DERIVATION_FIXTURE_ADMISSION_20261112

- `BlueStoneIMTests/RealtimeBackgroundComputeTests.swift` 第 655–665、682–689 行使用独立 defaults 并沿用既有本地策略预热。`BlueStoneIMTests/RealtimeMountedHistoryAndRecoveryTests.swift` 第 756–788 行按请求路径和会话返回两页。原挂起、两条跳转结果和 Store 提交顺序断言保留。
- `BlueStoneIM/Core/AppSupport/RealtimeCompute/RealtimeComputeRuntime.swift` 第 25–27 行的 DEBUG 只读 `queuedDerivationCount` 让该用例在放行前确认第二个调用已经进入真实等待队列。现有 admission 和 commit 逻辑沿用。按本标识和对应反向差分回退，聚焦编译和原生复验状态见 Core handoff。
<!-- WDT_IOS1_HTTP_DERIVATION_FIXTURE_ADMISSION_20261112_END -->

<!-- WDT_IOS1_SEQUENCE_RECOVERY_PROBE_LIFETIME_20261112_BEGIN -->
## WDT_IOS1_SEQUENCE_RECOVERY_PROBE_LIFETIME_20261112

- `BlueStoneIMTests/RealtimeMountedHistoryAndRecoveryTests.swift` 第 153–161、194、265–274、288 行的两个挂起用例共用 `RealtimeBackgroundDecodeTests.swift` 第 597–619 行的锁保护单次触发和可释放等待。保留原 recovery、边界、安装和持久化断言。
- 按本标识和对应反向差分回退，聚焦编译、原始崩溃归因和原生复验状态见 Core handoff。
<!-- WDT_IOS1_SEQUENCE_RECOVERY_PROBE_LIFETIME_20261112_END -->

<!-- WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_BEGIN -->
## WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112

- `BlueStoneIM/Core/AppSupport/AppState+RealtimeSequenceRecovery.swift` 第 137、226–232 行在 DEBUG 将原历史 claim 和 Task 句柄交给 `RealtimeComputeRuntime.swift` 第 28–30 行的测试观察入口。沿用原排队、提交和任务 defer。
- `BlueStoneIMTests/RealtimeBackgroundDecodeTests.swift` 第 597–693 行先关闭已复制的 probe，再退役所属历史边界与 claim、取消任务，最后释放 gate。异步 teardown 等待 recovery 与 retry 任务退出后清理本地 URLProtocol。
- `BlueStoneIMTests/RealtimeMountedHistoryAndRecoveryTests.swift` 第 296–299、438–484 行保留原边界测试，并追加已读到页面而 worker 尚未提交的提前退出断言，核对 Store revision、SQLite 投影和历史 claim。聚焦编译、定向复审与回退见 Core handoff。
<!-- WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_END -->

<!-- WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112_BEGIN -->
## WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112

- `BlueStoneIMTests/RealtimeBackgroundDecodeTests.swift` 第 657–796 行关闭夹具 HTTP 入场，取消并等待已知 delivery ACK、认证头像相关任务，排空已准入的原生 HTTP 后关闭 session。仍走原 `URLSessionHTTPTransport` 和 `URLProtocol`。
- 同一夹具在释放 worker 前核对回执权限退役发布，再验证迟到 HTTP 入场被拒绝、旧页被 worker 拒绝、Store 与 SQLite 未发生后续提交。`BlueStoneIMTests/RealtimeMountedHistoryAndRecoveryTests.swift` 第 440–480 行使用既有独立 defaults 参数；原边界、两页原生 trace 和挂载断言保留。聚焦编译及实际回执见 Core handoff。
<!-- WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112_END -->

## WDT_IOS1_THUMBNAIL_SOURCE_BINDING_20261112

- `BlueStoneIMTests/DesignSystemTests.swift:182–207` 更新 `testThumbnailCacheHitUsesAdmissionGateBeforeDecode` 的编译时相对源路径。加载器由 App target 编译，两个 bubble 视图由 `IM4Features` 编译。沿用三个准入／解码顺序和两个像素预算断言。
- 以 `7aab37223f0f7e50b7c4c6a6ff490e681335c588` 为私有父提交。arm64 单 Swift 对象编译和 XCTest 链接通过。本机 Swift 按原编译路径复现旧路径读取失败，并通过修正路径的原断言。iOS XCTest 待运行。合并时保留各自索引增量，回退应用本提交反向差分。补丁和编译路径见 B 的登录与 DesignSystem 私有交接。

## WDT_IOS1_D583_UI_SOURCE_CONTRACTS_20261112

- `BlueStoneIMTests/BatchForwardStateTests.swift:104` 在原消息行方法验证选择模式的资格和成员门，再核实际 `IM4Features.ChatTimelineRowDecoration` 的状态和禁用。 `BlueStoneIMTests/RemoteStickerAndEmojiModelTests.swift:159` 验证真实 transcript tap、两面板关闭和共享 draft 绑定，保留打开且当前 composer 才预加载的约束。
- 私有父 `7aab37223f0f7e50b7c4c6a6ff490e681335c588`。两处 D583 原失败由本机 Swift 精确复现，修正版断言通过，并拒绝四种测试源反例。两个 arm64 XCTest 对象编译、链接通过。真实手势和两条原生 XCTest 未跑。整合时保留其他标识增量，回退使用 B 交接的反向差分。

## WDT_IOS1_STICKER_COMPOSER_PREPARE_CONTRACT_20261112

- `BlueStoneIMTests/RemoteStickerAndEmojiModelTests.swift:152–169` 更新 `testStickerMessageViewResolvesTenantFilePayloadsBeforeRendering` 的面板准备接线检查。沿真实表情面板、当前会话输入动作和 scoped sticker binder 回查 `AppState.prepareStickerExpressionPanel`，保留原租户文件 ID、请求边界、资源解析和渲染检查。
- 在原七项投影上独立追加。按标识应用对应正反差分，保留同文件的 D583 手势测试及其他索引增量。原签名失败、本机源码断言复验及后续 R2／原生运行状态见 B 交接。

## WDT_IOS1_MOUNTED_RECOVERY_DEFAULTS_SUITE_20261112

- `BlueStoneIMTests/RealtimeMountedHistoryAndRecoveryTests.swift:155–158` 将两页挂载恢复用例的 UUID suite 交给同文件的 `trackedRecoveryFixture`（第 442–448 行）。其余调用沿用 Core 默认 suite。该 helper 统一创建和清理 defaults，沿用 Core 的 HTTP drain、回执撤权和旧页拒绝。
- 按本标识逆向恢复 `4001f1e4` 的三处前像，并保留完整 Core/SDK 索引前缀。八项 provisional 的源码和制品读回见 B 交接。

## WDT_IOS1_PRODUCTION_ROOT_FIXTURE_20261112

- `BlueStoneIM/BlueStoneIMApp.swift:463–473`、`491–498`、`539–540` 增加 DEBUG 挂载入口。测试窗口使用生产 `RootView` 的认证订阅、AuthRoot/MainShell 分支和通话封面，同时隔离系统角标输出。
- `BlueStoneIMTests/IdentityAuthRoutingTests.swift:202–203` 与 `BlueStoneIMTests/DomainRTCPreviewAndMediaStateTests.swift:62–65` 使用该入口。启动宿主仍沿原截图旗标。差分、定向检查和回退见 B 的 R2 交接。

## WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112

- `BlueStoneIM/Core/AppSupport/ScopedAppPolicyStores.swift:171–183`、`BlueStoneIM/AppState.swift:133–139` 和初始化读、`AppState+AppPolicyAndLegal.swift` 的 policy 读写、`AppState+AccessDiagnosticsRuntime.swift:24–25` 使用同一实例 last-good 域。默认仍为标准域。
- `BlueStoneIMTests/IdentityAuthRoutingTests.swift:165–172`、`235–237` 和 `BlueStoneIMTests/DomainRTCPreviewAndMediaStateTests.swift:20–93` 使用各自 UUID suite。终态用例带有效缓存挂载，等待独立的强制请求与应用结果。回退见 B 的 R2 交接。

## WDT_IOS1_SPLIT_MOUNTED_ROOT_SOURCE_20261112

- 将 `RTCCallIdleTimerCoordinator` 从 `BlueStoneIM/BlueStoneIMApp.swift` 移到已编入 App 的 `BlueStoneIM/Features/Calls/CallScreenViews.swift:8`。保留原 MainActor、唤醒策略和生产 RootView 调用。
- 将已挂载收藏用例移到 `BlueStoneIMTests/DomainMessageActionsAndInitialSyncTests.swift:735` 的 `IdentityPresentationTests` 扩展，将两条来电身份解析用例移到 `BlueStoneIMTests/DomainRTCJoinAndPeerResolutionTests.swift:312` 的原 `DomainStoreTests` 扩展。测试类、selector、方法和断言保持原字节。
- 三个源文件分别为 794、752、781 行，保持 800 行上限。三个目标文件已注册，回退应用 B 交接的反向补丁。

## WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112

- `BlueStoneIM/Core/AppSupport/DebugFixtures/AppState+DebugScreenshotFixtures.swift:323`（标识行 323, 337, 359）。提取并复用原认证截图 context，保留既有 DEBUG 入口。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+LocalMessageScope.swift:34`（标识行 34, 52）。退役捕获协调器所属媒体 registry，保留失效顺序。
- `BlueStoneIM/MediaLayeredCache.swift:222`（标识行 222, 228）。DEBUG 读取媒体 registry generation，用于宿主和私有对照。
- `BlueStoneIM/MessagePersistenceCoordinator.swift:17`（标识行 17, 31, 82, 476, 480, 608）。协调器注入退役 registry，旧入口默认 shared，复用 per-scope purge fence。
- `BlueStoneIMTests/RegistrationFlowPolicyTests.swift:384`（标识行 384, 638）。注册三态核调用返回与排空，证明私有载荷与 marker 清理、旧 ticket 失效和宿主不变。
- 沿 a8c 的 9cc 退役差分添加源码标识，保留原方法、作用域和标识。以本标识及绑定的正反补丁为准。移除新增注释可逐字节恢复 a8c Swift 源，SwiftSyntax token 等价检查与定向载体绑定见 B 交接。


<!-- WDT_IOS1_HTTP_FIVE_SCOPED_FIXTURES_20261112_BEGIN -->

## WDT_IOS1_HTTP_FIVE_SCOPED_FIXTURES_20261112

- 五条原选择器及源码定位。
  - `BlueStoneIMTests/DataHTTPMechanismBoundaryTests.swift:91` `testUserProfilesHundredRowsDecodeOffMainAndPreserveValues()`。
  - `BlueStoneIMTests/HTTPProtectedSessionTests.swift:324` `testUnsignedSimulatorEnterpriseLoginPersistsProtectedSessionAndAuthenticates()`。
  - `BlueStoneIMTests/HTTPEnterpriseLoginAndCaptchaTests.swift:386` `testEnterpriseFirstLoginAcceptsNestedOnlySessionIdentityAndRetainsResolvedContext()`。
  - `BlueStoneIMTests/HTTPEnterpriseLoginAndCaptchaTests.swift:495` `testEnterpriseFirstPendingLoginRemainsPlatformOnlyAndNonAuthenticated()`。
  - `BlueStoneIMTests/HTTPRegistrationPendingRecoveryTests.swift:63` `testRegistrationSuccessfulLoginCancelsConfirmationAndLateStatusCannotClearSession()`。
- `BlueStoneIMTests/HTTPProtectedSessionTests.swift:728` 复用真实 Keychain 保存与逐项清理读回。C101 保留成功登录、迟到确认不得清会话及其余原断言。
- Profiles 保留 100 行、请求计数及离主线程解码。其余三条登录场景保留原状态断言和测试自有 Keychain/preferences 作用域。
- 四个 XCTest 文件先按 06ca9d1 原字节投影，再移除三份文件的空行使 Swift 文件均在 800 行内。Swift token 等价，文件前后像和逆补丁见原 A 交接。

<!-- WDT_IOS1_HTTP_FIVE_SCOPED_FIXTURES_20261112_END -->

<!-- WDT_IOS1_A04_ACTIVE_APP_POLICY_HTTP_FIXTURE_20261112_BEGIN -->

## WDT_IOS1_A04_ACTIVE_APP_POLICY_HTTP_FIXTURE_20261112

- `BlueStoneIMTests/HTTPRoutingAndSessionTestFixtures.swift:714` 为 A04 测试提供独立的 active app policy 夹具。标识行 714–736，`throws` 声明在第 717 行。原 JSON、解码和过期时间设置保留。

<!-- WDT_IOS1_A04_ACTIVE_APP_POLICY_HTTP_FIXTURE_20261112_END -->


<!-- WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN -->
## WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112

- 生产侧以同一 `ConversationMemoryFrame` 原子发布按 ID 的首行索引、顺序、消息窗口和 revision。历史重复 ID、旧 positional rename 及不满足已排序前提的输入继续走原兼容语义。
- 已接纳的同 ID 单消息提交使用索引、相邻比较和必要时二分定位。消息窗独立变化复用元数据数组；真实行变化或换序仍保留旧数组读合同。RTC 跨窗相关变化保留原全量权威计算。
- `ScopedMessageMemoryStore.conversationRowUpdates(id:)` 提供已安装帧的可选元数据，按绑定隔离。现有 `MemoryCommit` 附上 `changedConversationRowIDs` 和 `conversationOrderChanged`，保留原消息差分。列表消费由原 B 后续接入。
- 文件：`ConversationMemoryFrame.swift`、`ConversationMemoryDerivation.swift`、`ScopedMessageMemoryStore.swift`、`ConversationStore+Lifecycle.swift`、`ConversationStore+PreparedRealtime.swift`；定向断言在 `ScopedMessageMemoryTests.swift`。
- Swift 6 iOS-simulator 15.0 下 IM4Stores Debug/Release 条件 typecheck 与定向 XCTest 源码 parse；主机用等价最小模型执行帧/发布检查。正式 R2 和 R7 待原入口核验。
<!-- WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END -->


<!-- WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112_BEGIN -->
## WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112

- `ConversationMemoryFrame` 复用已有首行索引计数识别重复物理 ID。`MemoryCommit.requiresFullConversationListProjection` 在前后帧任一含重复且元数据、顺序/绑定或窗口变化时为 true，覆盖次行提及、纯消息变化及重复创建和清除。
- 普通无重复路径沿原行 ID 和消息差分；B 的一次读取直接用 `ConversationStore.conversationMessageSnapshot(id:)`，保首行和同帧窗口。连续观察仍走既有 publisher。
- 改动仅在 `ConversationMemoryFrame.swift`、`ScopedMessageMemoryStore.swift` 和现有 `MessageSidecarCommitTests.swift`。Store 保留物理行，B 在既有消费者边界处理聚合与代表行。
- Swift 6 arm64 iOS-simulator 15.0 下 IM4Stores 类型检查及定向 XCTest 源码 parse 通过。主机用生产帧、Store 和派生源及最小模型替身复核信号。正式原生运行待原 R7。
<!-- WDT_IOS1_STORES_DUPLICATE_LIST_INVALIDATION_20261112_END -->

## WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112

- `BlueStoneIM/ConversationViews.swift:219–228` 接已安装的 `MemoryCommit`，按 binding 隔离。`BlueStoneIM/Features/Conversations/ConversationListProjection.swift` 第 105–117 行合并行和消息差分，第 149–152 行核对 binding 后调用 `ScopedMessageMemoryStore.conversationMessageSnapshot(id:)`，从同一安装帧读取索引行和消息窗口。对应 `e384-stores62-provisional.forward.patch` 第 255 行的 `@@ -60,226 +66,133 @@`，单次读取在补丁第 521 行。
- `ConversationListRenderCache.swift` 和 `ConversationListMentions.swift` 共用原行投影与排序规则。普通更新只重投影脏行，原位置稳定时更新同一行和提及计数。初建、筛选变化、影响排序或成员资格、插删、换绑定保留全量路径。既有 table diff 与几何逻辑沿用。
- `BlueStoneIMTests/DomainStoreTests.swift` 在真实挂载列表核单消息和搜索全量路径，保滚动和几何断言。 同文件另核非目标行、删除和迟到 binding。定向检查、R7 合同和回退见 B 交接。

## WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112

- 普通、未读和搜索投影在筛选和排序前按已安装顺序保留同 ID 首行，与点击打开的索引一致。提及总数和 @我 记录继续遍历物理行；已知重复 ID 的脏行或消息事件走全量。
- 单行刷新从安装帧一次读取索引元数据及消息窗口。
- 千会话挂载用例固定 Debug 列表时钟，检查可见摘要更新、原 cell 身份和邻行内容，单独推进一分钟验证全量，再验证搜索全量、滚动和 96 pt。

<!-- WDT_IOS1_CONVERSATION_LIST_CORE_INVALIDATION_20261112_BEGIN -->
## WDT_IOS1_CONVERSATION_LIST_CORE_INVALIDATION_20261112

- 列表在核对 binding 和 revision 后消费 Core 的 `MemoryCommit.requiresFullConversationListProjection`。仅次行元数据变化时仍从物理快照刷新提及总数与 @我 摘要，等待应用的全量请求保留至实际投影。
- 定向断言覆盖空首行、消息与顺序差分的次行提及变化、后继普通点提交、旧 revision 和全量完成后的点更新恢复。
<!-- WDT_IOS1_CONVERSATION_LIST_CORE_INVALIDATION_20261112_END -->


<!-- WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_BEGIN -->

## WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112

- `BlueStoneIM/Core/AppSupport/AppState+RuntimeBindings.swift:24` 现有 apiContext 观察器按完整 LocalMessageScope 清空并退役旧通话归档。 标识行 24, 30。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+ProfileAndTenantAuthority.swift:167` App 归档绑定和 ensure 校验五元组，拒绝旧上下文。持久化 v3 键及 v1、remote 两级 fallback 沿用原规则。 标识行 167, 198。
- `BlueStoneIM/Core/AppSupport/RemoteSync/AppState+StoredSessionRefresh.swift:23` 在线主刷新和租户 fallback 先按原 fence 持久化，再提交上下文并接回变化后的有效 scope。原冷启动及同 scope 换票保留原接线。夹具可给该刷新传入私有 defaults。 标识行 23, 28, 398, 408。
- `BlueStoneIMTests/RTCCallLifecycleIntegrationTests.swift:425` 走真实在线刷新入口。两份夹具响应在 data 根提供 tenant_id；核同设备租户、完整 scope 和在途绑定连续，新 device 提交后自动绑定及挂载 RTCEntryView 行读回。保留旧 fallback 拒绝、退出与已接纳落盘断言。夹具使用私有媒体 registry，清理前等待原 scope 的 purge 完成。复用生产导航容器，等待已挂载入口；同一真实挂载画面必须经成功 OCR 同时确认新标题出现、旧标题缺席。截图或 OCR 失败即报错，AX 仅保留为诊断。标识行 425, 766。
- `BlueStoneIMTests/RTCCallRecordProjectionTests.swift:556` 冷登录归档夹具使用私有媒体 registry，目录清理前等待原 scope 的 purge 并检查待清理状态。标识行 556–679。
- `Sources/IM4Stores/CallStore.swift:75` 运行绑定含 device。FIFO 在 fallback 提升前和 UI 回读时校验退役准入，已接纳的写入仍落原键。原字符串 API 保留。 标识行 75, 104, 210, 281, 318, 385。
- 以实际父候选另行重核生产入口和签名。按 A 交接的正反差分整合及回退，保留其它 WDT 索引增量。

<!-- WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_END -->


<!-- WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN -->
## WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112

- 可见贴纸库按完整 `LocalMessageScope` 和激活代际持有。App/设备变化、退出或作用域缺字段会退役当前可见状态和上传草稿。重新激活按原兼容键只读加载。
- 保持 manifest 请求权威、operation 与代际校验。旧 GET、上传进度、完成和排序在异步边界核对原绑定。同 scope 续票保留可见库与本地上传，替换 epoch 仍退役原 manifest 请求。
- `fetchScopedFileUploadConfig` 取已有远端作用域键，贴纸持久兼容键继续只传给 manifest 存储。旧记录不迁移、不删除。
- 真实 `apiContext` 更新经 `AppState+StickerLibrary.swift` 19–30 行进入退役。认证 fence 将设备 ID 首尾空格归一为相同值时，完整 `LocalMessageScope?` 仍能识别有效→无效。原 prepare 和文件下载接线在 51–67、429 行。
- `AppState+StickerLibraryActions.swift` 14、76–158、290–365、375–476 行和 `AppState+StickerUploadAndHydration.swift` 14、34–201、375–376、537–555 行沿用原请求、上传与轮询入口。`Sources/IM4Stores/StickerStore.swift` 9–54、69–95、151–220、253–273 行持有并核对代际。
- `DomainStickerManifestTests.swift` 47、85、140–206、390–394、422–520、552–667 行包含 typed binding、真实更新后立即退役和旧进度回放。在新绑定建立后释放旧上传代理并检查同 ID 草稿进度仍为 0.02，同时保留原 file-detail GET 和完成结果断言。`DomainOlderHistoryAndConversationListTests.swift` 209–238、255–262、298–312、397–433 行只合入原贴纸夹具 hunk。
- 原业务差分定位 `3847c45ff37c4424fd75fd3db9b9c85711abee5b`，本次定向复审差分见 `sticker-runtime-scope.r2-fix.forward.patch`。实际父若已包含 B 的测试拆分，按方法移植原贴纸夹具 hunk，保留 B 已迁往 `DomainStoreTests.swift` 的内容。
- Swift 6 arm64 iOS-simulator 15.0 下 IM4Stores 和三个 App 文件定向类型检查、两份 XCTest 源码 parse 均通过。主机用真实 Store/持久化和最小 App 权威替身检查作用域回归。正式原生运行由原 R7 接续。
<!-- WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END -->


<!-- WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_BEGIN -->
## WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112

- `ContactStore` 持有按作用域的名片原名、canonical friend UID 索引及其作用域，reset 在原联系人发布前清空两组数据。`AppState.swift` 只删除三处 backing 字段（两组值和一个作用域），以标识注明归属。
- `applyFriendRelations` 继续按原顺序过滤/映射、应用已接纳的本地更新、发布联系人及备注，再提交 Store 投影。备注解析和名片查名走同一 Store。索引去歧义规则及权威 readback 仍沿原入口。
- 冷恢复只替换已接纳作用域的原名；后台保存取得当前作用域的值快照，持久格式不变。合法同 scope 重认证不触发联系人 reset。
- Store 与 App 入口：`ContactStore.swift` 123–213、687–691；`AppState.swift` 118；`AppStatePolicies.swift` 205；`AppState+ContactsInboxDevices.swift` 183–199、456–462、553–557；`AppState+TenantProfileAndRelations.swift` 103–114、151–155、205–211、261–265。
- 读取、持久化和测试：`AppState+ProfileContactProjection.swift` 194–204、242；`AppState+RemoteAuthState.swift` 401；`LocalMessageAndContactProjectionSupport.swift` 194–202、212；`ScopedResponseFenceTests.swift` 698–759。删除项以保留的标识或邻近入口定位。
- 业务前向差分来自 `ddea4b51b278b42adaa38fa8c7b61979242179cf`，标记修订见 `contact-identity.wdt-fix.forward.patch`。实际父上将 `ContactStore` API、`contact-identity.appstate-fields.patch`（只移除 AppState 三个旧 backing 字段）及 `contact-identity.app-adapters.patch` 对应调用方作为同一组移植。保留父版本其余 AppState 字段和索引区块，完整组装后再核对标识、行数与正反树。
- iOS-simulator 15.0 下 IM4Stores module-only 与七个 App 主要文件类型检查通过。主机定向运行使用真实 apply、restore、builder 与 Store 方法体及最小依赖替身；正式原生运行归 R7。
<!-- WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_END -->

<!-- WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_BEGIN -->
## WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112

- `AppState+ContactsInboxDevices.swift` 19–61、176–199、346–550 行在接受、拒绝及备注动作首次等待前绑定 scope、本地会话代际和认证 fence。备注 fallback、乐观保存、PATCH、权威 GET、回滚和完成沿用该归属。安全错误在触发会话动作前核对其 HTTP 的 exact fence。
- `TenantSession/AppState+TenantInboxMapping.swift` 123–197 行逐段核对申请、黑名单和好友刷新。合法续票后下一请求用当前凭据。取消、退役及会话安全错误结束读取链。当前会话的普通单项失败继续余下读取。
- `HTTPPlatformAuthorityRefreshRegressionTests.swift` 205–210、288–532 行沿真实 AppState 入口和隔离 HTTP，覆盖 A→B→A、新 epoch、续票、取消、迟到成功和安全错误。断言包括 Store、完成及后继请求。
- 源码基于 `5962b23fa7a88003caa33a84b461afe48ea8501e`，见 `contact-request-ownership.forward.patch` 和相应 inverse。与已审 `8c82c0c` 合成时保留其 Store canonical UID 和名片原名适配器，并在同一实际父上重算正反树。正式原生结果由原 R7 记录。
<!-- WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_END -->

<!-- WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN -->
## WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112

- `AppState+ContactsInboxDevices.swift` 41–49、191–203、453–473、549–568 行给接受、拒绝和备注的实际 HTTP 绑定原操作。旧凭据的会话安全错误在任何回滚、发布或完成之前退回，普通当前错误保留原乐观回滚。
- `TenantSession/AppState+TenantInboxMapping.swift` 147–176、197–227 行把原 owner 和本次 HTTP exact authority 交给申请、黑名单和好友读取。`IMAPIClient+Contacts.swift` 30、45、171、340、353、396、415、424 行仅让对应路由接收可选 owner。
- `IMAPIClient+RequestExecution.swift` 31–223、253–366、456、585 行核对策略等待、发包、备用路由和设备吊销通知。归属请求使用可取消的直达 transport，并保留有权的当前请求重试。`IMAPIClient+ResponseAndLogging.swift` 12–36、231–256 行持有检查和原共用 GET key 算法。
- `HTTPPlatformAuthorityRefreshRegressionTests.swift` 291–449、452–556、591–634 行覆盖真实 API 的主备尝试、策略等待、迟到安全响应、零发布和普通回滚。复用原 canonical/PATCH/GET、续票和无 owner 的对照路径。
- 窄差分基于 `602be3dcc4dec6eb154f40b0d5a1f30d7083c640`，见 `contact-http-ownership.forward.patch` 及对应 inverse。与已审 `8c82c0c` 合成时保其 canonical UID 和名片原名适配器，实父重算正反树。正式原生结果由原 R7 记录。
<!-- WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END -->


<!-- WDT_IOS1_CONTACT_POLICY_GATE_OWNERSHIP_20261112_BEGIN -->
## WDT_IOS1_CONTACT_POLICY_GATE_OWNERSHIP_20261112

- 联系人请求进入实际强制认证策略门时，传递该次 HTTP 的原 owner。平台策略和需要时的 bootstrap、租户认证状态请求复用现有发包与响应 owner 校验。仅当前精确凭据、会话代际及未取消的请求可应用策略、认证状态或提示。
- 策略门无 owner 的原认证路径沿用既有行为。独立窄差分基于冻结的 f744a5d。
- 定向回归在真实策略或认证状态传输内挂起，覆盖 A→B→A、取消、同 scope 续票、迟到成功以及当前有／无 owner 的正控。
<!-- WDT_IOS1_CONTACT_POLICY_GATE_OWNERSHIP_20261112_END -->

## WDT_IOS1_CONTACT_REMARK_FIXTURE_ADMISSION_20261112

- 联系人六项 5B 原候选 `2c4d1a05` 为 5P/1F。XCTest 初始化跳过生产冷启动恢复，备注请求夹具须为初始联系人 scope 绑定修订栅栏，使首个真实好友 GET 建立联系人行和旧备注快照。
- 保留原请求、错误、scope/epoch/续期和断言。在 PATCH 或读回被挂起时核对联系人显示备注及联系人卡片原名。仅更新该测试夹具；生产 App 和 Store 沿用原候选字节。下一次以六项单进程 5B 验证。

<!-- WDT_IOS1_PHOTO_PROTECTION_SIMULATOR_READBACK_20261112_BEGIN -->
## WDT_IOS1_PHOTO_PROTECTION_SIMULATOR_READBACK_20261112

- 7aab 原签名 5B 的照片行为用例仅因模拟器读不到 `protectionKey` 失败。同次用例直接调用 Foundation 设置 `complete` 后也读不到该键，原能力用例记为 SKIP。
- `BlueStoneIMTests/DesignSystemComponentBoundaryTests.swift` 60–69 行。真机继续严格检查 `NSFileProtectionComplete`，模拟器有键时也核对其值。模拟器缺键由现有能力用例记录。保留照片原文件、暂存数据、0600/0700 权限及清理断言；能力用例及 `PendingAttachmentFileStore` 字节一致。
- 实际父为 `21d4362f91991bf6129e378a7e2cd45a6c69ccd7`。原行为差分见 `908c3b254e800f6ffb20721b6a1fefbdc5afe5e4` 的 `forward.patch`。合并时保留标识的完整区块及本索引，并以实际父核对同一测试入口和正反向树。
- Swift 6 模拟器与设备目标语法检查通过。原生验收沿原 R7 两条精确 selector；保留历史 FAIL 和能力 SKIP。
<!-- WDT_IOS1_PHOTO_PROTECTION_SIMULATOR_READBACK_20261112_END -->

<!-- WDT_IOS1_CALL_ARCHIVE_WRITE_ADMISSION_20261112_BEGIN -->
## WDT_IOS1_CALL_ARCHIVE_WRITE_ADMISSION_20261112

- 通话归档可见写入要求当前五元组及匹配的 CallStore 绑定。加载中已准入的行仍按原 FIFO 写回原持久键。
- 通话列表与事件轮询在返回时复核发起时的五元组和本地会话代际。事件处理和 ACK 发起前沿用同一凭据上下文。已经发出的合法 ACK 保留原请求完成路径。
- 回归走真实在线刷新响应，覆盖无效设备字段、同作用域续票、作用域恢复后的旧代际，以及挂断信令与媒体、CallKit 清理。原通话归档挂载和恢复用例保留。

<!-- WDT_IOS1_CALL_ARCHIVE_WRITE_ADMISSION_20261112_END -->

<!-- WDT_IOS1_NOTIFICATION_OPEN_RECORDING_20261112_BEGIN -->

## WDT_IOS1_NOTIFICATION_OPEN_RECORDING_20261112

- 原两条通知打开用例分别注入同文件的 `RecordingIOSNotificationCenter` 和 `RecordingIOSNotificationLocalIndexStore`。原 payload、真实打开入口、观察者顺序、清理及全部断言保留。
- 以 `8214faf205841fb8546a72ba691054d65dec97e6` 为父。两条用例保留原 App-hosted XCTest selector。旧 7aab 专用载体的 2P 归其原制品。

<!-- WDT_IOS1_NOTIFICATION_OPEN_RECORDING_20261112_END -->

<!-- WDT_IOS1_PERF_CHAT_AUTOFILL_EQUAL_RESET_20261112_BEGIN -->

## WDT_IOS1_PERF_CHAT_AUTOFILL_EQUAL_RESET_20261112

- `BlueStoneIM/App/ChatHistoryRuntimeAssembly.swift:218–222`。消息填满视口后，补拉计数只从非零归零，避免对 `ChatScreenPresentationState` 发出等值通知。
- 依赖原 `ChatScrollVisibility.isContentUnderfilled` 和补拉入口。合并时保留完整标识块、非零重置、短窗尝试上限及原焦点、滚动和已读时序。
- 基线 `b5c94613321b90dd68c0d47693246e4a782ea155`，行为差分源自私有候选 `fa8bb716c926ca1478b51a4f07910518635bd55a`。本地 Swift 语法和 Combine 探针通过，覆盖 0→0、非零归零及短窗补拉正控。iOS 挂载 `UNRUN`。以本标识及交审正反补丁定位，回退该块与本索引项。

<!-- WDT_IOS1_PERF_CHAT_AUTOFILL_EQUAL_RESET_20261112_END -->

<!-- WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112_BEGIN -->

## WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112

- 15 条使用假 WebSocket 的 XCTest 在构造 `RealtimeClient` 时显式关闭 QUIC。这样 Debug 运行环境中的 QUIC 偏好不会在假 WebSocket 前启动原生连接。
- `BlueStoneIMTests/RealtimeTransportRecoveryTests.swift` 15、49、84、119、152 行覆盖心跳和重连。`BlueStoneIMTests/RealtimeTransportWireTests.swift` 16、51、58、263 行覆盖编解码、双客户端所有权和四条消息线协议用例。`BlueStoneIMTests/ScopedMessageMemoryTests.swift` 622–628、684–687 行覆盖共享消息追踪夹具和 ACK 重入。
- 基于 `98e3abf3e49ca65c2f09be989dce5b9e30ce1f55`。三份测试 Swift 语法检查及差分逆向字节核对通过，原生结果待原 R7。合并保留 11 处配置和本索引，保持用例 ID、断言、显式 fake QUIC、发现与回落测试及真实 WebSocket 回环。回退移除这 11 处配置并恢复共享构造排版，同时移除此索引。

<!-- WDT_IOS1_WSS_FIXTURE_QUIC_ISOLATION_20261112_END -->

## iOS1 公开引导和 HTTP 选路 v5

- 标记 `WDT_IOS1_HTTP_ROUTE_V5_20261113`，基线 `8ea3ec41903dd96c7f0d86576f1de51dd11a8e79`，iOS1 tree `b11d947ec4a0f26cc705895232d88f7b0a1651ad`。
- 独立启动开关 `WXT.RouteV5.public_bootstrap`、`WXT.RouteV5.platform_api`、`WXT.RouteV5.tenant_api`、`WXT.RouteV5.im_api` 默认关闭。启用后使用原有效配置内的首选／上次验证成功入口，严格等待实际发出后 3 秒无响应，备用候选通过业务验证后才更新同作用域入口。
- 轻量验证使用现有应用策略、商户上下文、最多十条消息的 IM 同步。文本发送失去回执时用原 `client_msg_no` 与当前会话的消息同步结果对账，未确认继续沿用待确认状态。已开始提交、等回执和结果不明的持久化出箱记录继续保留，启用 IM 开关时只读对账。
- 公开引导安装包保留既有两个域名，新增三个空编译槽位。签名指定的入口及实时连接、订阅继续使用原权限边界和流程。

### R2 定向修订

- 消息写入发出前用既有 SQLite 出箱事务登记 `confirmation_required`。该记录跨重启和开关保留，领取和重复入队均不能把它改成可重发。已知未发送可解除登记，成功回执或按原 `client_msg_no` 对账可以确认。503 和发出后失去路由权威保留待确认。
- 竞速在候选实际发出和串行提交前核对当前入口的明确响应和安全拒绝。公开引导冷启动只复用上次在线接受且与当前配置版本、哈希、下发域名和缓存有效期匹配的授权记录。
- 商户相对二进制资源使用商户 API 当前胜出入口及原请求超时。会话首屏先读最多十条，再按原游标补齐原二十条窗口。
- App1 Debug 和 Release 的构建默认值为 `NO`。通过现有 Xcode 构建参数按服务传入 `WXT_HTTP_ROUTE_V5_PUBLIC_BOOTSTRAP=YES`、`WXT_HTTP_ROUTE_V5_PLATFORM_API=YES`、`WXT_HTTP_ROUTE_V5_TENANT_API=YES` 或 `WXT_HTTP_ROUTE_V5_IM_API=YES`，值写入 `WXTHTTPRouteV5Defaults`。显式启动参数 `-WXT.RouteV5.<service> YES|NO` 按服务覆盖构建值，结果在进程内固定。回退时带 `NO` 重启，或将构建参数恢复为 `NO` 后重新构建及启动。

### R2 复审修订

- 开启 IM 选路时，出箱在同一 SQLite 领取事务内按当前作用域保留旧库中无法证明未发送的记录。待确认记录跨开关保留，按原编号只读确认。冷启动附件清理保留这类记录引用的暂存文件。
- 3 秒内收到的响应头结束无响应判定。3 秒后的明确错误或安全拒绝阻止竞速提交，迟到的 2xx 响应头仍需等业务校验。主、备按完整校验结果决定胜出。
- 会话首屏继续原单次二十条读取。实际打开会话时，独立发起一条消息的轻量只读判定。同一作用域合并在途判定，首屏的返回和错误沿用原处理。

### R2 第四轮修订

- 冷启动恢复和手动确认共用现有授权 `/api/im/sync`。按会话分组，每轮最多四组，每组最多三页、每页五十条。使用服务器 `next_before_seq` 续读。匹配原 `client_msg_no`、发送者、频道及频道类型前核对会话、租户和入口权威。缺失、拒绝和中断保留待确认，只更新匹配的本地消息与出箱状态。
- `BlueStoneIM/Core/AppSupport/AppState+MessageSendingAttachments.swift` 17–33、204–321 行，`BlueStoneIM/AppState.swift` 441 行，`BlueStoneIM/Core/AppSupport/RemoteSync/AppState+CachedRemoteSnapshot.swift` 177 行，`BlueStoneIM/RuntimeRouteStore.swift` 74–89 行，以及 `Sources/IM4Data/NetworkingDTO/RemoteMessageModels.swift` 14–71 行对应分组、入口和游标。游标使用既有偏好存储，键绑定数据库作用域、频道、配置与入口，完整扫完后允许下一次显式确认重新查看最新历史。
- `Sources/IM4Data/SQLiteMessageRepository+Outbox.swift` 11–23、147–224、259–270、552–630 行在原 SQLite 事务保留领取时的模式和未发送证据。类型与桥接见 `Sources/IM4Data/LocalMessageRepository.swift` 170–177 行、`BlueStoneIM/MessagePersistenceCoordinator.swift` 176–185 行及 `BlueStoneIM/Core/Networking/IMAPIClient.swift` 45–70 行。共享消息发包入口 `BlueStoneIM/Core/Networking/IMAPIClient+RequestExecution.swift` 34–35、70–96、144–145、241–242、286–287、358–389、423 行核对领取、选路及发包时状态。重启后的模式与持久化领取记录不符时，保留不明记录，已知未发送的记录可再次领取。
- `BlueStoneIM/Core/Networking/IMAPIClient+Messages.swift` 45–94、309 行按有效来源判断备用入口，端口别名归为同一个来源。单来源打开仅发原二十条请求，双来源保留原独立轻读。定向用例位于 `BlueStoneIMTests/HTTPRuntimeRouteAndOutboxTests.swift` 1164–1384、1448–1462、1538–1557 行及 `BlueStoneIMTests/HTTPGroupProfileAuthorityTests.swift` 620–633 行。
- 基于 `72171b2ea8330c3dee69480f082f159b0b8e6d75`，按原标识合并完整差分。回退沿用既有服务开关与候选逆向提交。定向 arm64 模拟器验证记录见 `/private/tmp/im4-ios1-route-v5-check.HN5vWp/r4final.xcresult`。

### R2 第五轮修订

- `BlueStoneIM/Core/Networking/IMAPIClient+Messages.swift` 5–13、43–111 行将确认专用历史读固定到当前授权 IM 来源，开关两态均复用既有重定向限制和最终响应来源校验，继续使用 `/api/im/sync` 的原请求体和分页游标。仅接纳同协议、主机、等效端口的 200 响应。
- `BlueStoneIM/AppState.swift` 358–365、446–454 行，`BlueStoneIM/Core/Networking/IMAPIClient.swift` 162–168、196–209 行，`BlueStoneIM/Core/Networking/IMAPIClient+RuntimeRouting.swift` 392–400 行及 `BlueStoneIM/RuntimeRouteStore.swift` 75–89、127–130、326–339 行绑定会话、票据、已发布配置和生效来源。变化时撤销在途确认许可。
- `BlueStoneIM/MessagePersistenceCoordinator.swift` 23–38、442–477 行和 `Sources/IM4Data/LocalMessageRepository.swift` 176–224 行将路由、存储票据和任务取消许可传到 `Sources/IM4Data/SQLiteMessageRepository+Outbox.swift` 409–465 行。在 SQLite 写者实际取得事务后复验许可，在同一同步临界区提交并清理该条消息的暂存附件。权限过期时保持待确认记录、游标和暂存文件。
- `BlueStoneIM/Core/AppSupport/AppState+MessageSendingAttachments.swift` 23–28、228–342 行和 `BlueStoneIM/RuntimeRouteStore.swift` 103–110 行按数据库作用域保存轮转位置。恢复轮次从上次位置继续，保留全局四组并发、每组三页、每页五十条上限。手动确认只调度目标会话。
- `BlueStoneIMTests/HTTPRuntimeRouteAndOutboxTests.swift` 1385–1590、1732、1765–1825 行覆盖真实 SQLite 路径在提交前变更路由版本、已选来源、会话和存储票据，控制重定向与最终响应来源，并在冷重开后确认第五组。父提交 `637bbb78ed8fc6162d821e54d2c6426d7a6a0707`，按原标识应用完整差分，候选逆向提交可回退本轮。arm64 定向模拟器结果见 `/private/tmp/im4-ios1-route-v5-check.HN5vWp/r5-final.xcresult`。

### R2 启动开关修订

- `BlueStoneIM/RuntimeRouteStore.swift` 51–95 行从构建值和真实进程启动参数生成同一份不可变快照。各服务通过原 `routeV5Enabled` 入口读取。偏好存储继续保存路由记录和恢复游标，应用在运行中写入同名偏好不改变开关。测试仅注入构造时的启动参数和构建值。
- `BlueStoneIM/Core/Networking/IMAPIClient+Messages.swift` 5–12、61–106 行，`BlueStoneIM/Core/AppSupport/AppState+MessageSendingAttachments.swift` 209–223、267–337 行，`BlueStoneIM/MessagePersistenceCoordinator.swift` 191–199、442–467 行，`Sources/IM4Data/LocalMessageRepository.swift` 196–216 行与 `Sources/IM4Data/SQLiteMessageRepository+Outbox.swift` 160–208、443–458 行删除可变开关复验。SQLite 确认继续在原同步临界区消费会话、路由、存储和取消许可。共享发包保留持久化领取模式核对及已知未发送的恢复。
- `BlueStoneIMTests/AppBootstrapHostConfigurationTests.swift` 8–24 行覆盖构建值与显式启动覆盖优先级。`BlueStoneIMTests/HTTPRuntimeRouteAndOutboxTests.swift` 1506–1581 行通过实际产品取值入口、普通历史读与暂停中的 SQLite 确认验证进程启动和偏好写入。旧库领取与回退改用同一数据库下独立的固定启动配置。
- 父提交 `df959dc911dcf0716a8acd4d8906dc928bf3f309`。按原标识合并完整差分，本轮源码回退为候选逆向提交。arm64 定向运行及同一制品的重启证据见 `/private/tmp/im4-ios1-route-v5-check.HN5vWp/` 下的 `r6-*.xcresult`。

<!-- WDT_IOS1_BINDING_SETTER_COMPILER_COMPAT_20261113_BEGIN -->
## WDT_IOS1_BINDING_SETTER_COMPILER_COMPAT_20261113

- 目的：绕过 Xcode 26.4 / Swift 6.3 在将隔离方法引用转换为 `Binding` setter 时的 IRGen 编译器崩溃。仅将直接方法引用改成显式闭包，并同步调用原方法；不修改方法体、状态、线程隔离、业务流程或 UI。
- 文件及行区间：`WenDaTong/WDTFeatures/Conversations/ConversationListSearch.swift` 264–266；`WenDaTong/WDTFeatures/Me/NotificationSettingsView.swift` 59–62；`WenDaTong/WDTFeatures/Me/SecuritySettingsViews.swift` 115–119。行号仅作导航，以同名 BEGIN/END 区块为准。
- 涉及入口：搜索输入 `changeQuery`、通知开关 `handleNotificationToggle`、Face ID 开关 `requestEnabledChange`。保持原 getter、入参、调用次数和 MainActor 隔离，不新增任务、依赖或接口请求。
- 验证：修改前已在独立 arm64 模拟器 Debug 编译复现崩溃；临时最小示例中直接传 String/Bool 方法均触发同类崩溃，显式闭包版本编译通过。修改后使用 Xcode 26.4 / Swift 6.3、`WenDaTong` scheme、独立 DerivedData、锁定依赖及 `CODE_SIGNING_ALLOWED=NO` 完成完整 arm64 模拟器 Debug 编译，结果为 `BUILD SUCCEEDED`、退出码 0，日志 `/private/tmp/wdt-binding-fix-20261113-debug.log`。独立 reviewer 静态复核通过；源码与配置哈希核对仅本次三个 Swift 文件及索引变化。未执行安装、启动、真机测试或 Release Archive；原有编译警告不在本次范围内。
- 合并与回退：本包无 Git 元数据，未创建提交。按本标识应用三个源码区块及本索引，不覆盖原方法实现。回退时分别恢复 `set: changeQuery`、`set: handleNotificationToggle`、`set: requestEnabledChange`，移除本标识和本索引项即可。修改前四个文件备份于 `/private/tmp/wdt-binding-fix-20261113-before/`。
<!-- WDT_IOS1_BINDING_SETTER_COMPILER_COMPAT_20261113_END -->

<!-- WDT_IOS1_CODEMAGIC_JDT_RELEASE_20261113_BEGIN -->
## WDT_IOS1_CODEMAGIC_JDT_RELEASE_20261113

- 目的：为当前 `ios-chat-1 3` 配置与 `/Users/zen/Desktop/jdt/codemagic.yaml` 同等的 App Store 发布流程。仅本地配置，不初始化 Git、不提交、不推送、不触发云构建或上传；来源 `jdt` 文件保持不变。
- 新增 `codemagic.yaml`，流程 ID 保留 `ios-bluestoneim-release`，工程及 scheme 改为 `WenDaTong`。沿用 `com.wendatongqiye.app`、`问达通`、`Wen Da Tong`、`appstore_credentials`、M2/120 分钟/latest Xcode、main/master push 规则、APNs 和签名流程、产物及仅上传不自动提审的发布策略。正式 Team ID 和私钥仍取原凭据组，不复制密钥到本地文件。用户在配置期间将项目版本与 YAML 的 `APP_VERSION` 更新为 `1.0.6`，保留该更新；构建号沿用 Codemagic `BUILD_NUMBER`。
- 配套文件：`scripts/codemagic-enable-apns.sh` 2–102 行从 `jdt` 原脚本引入，仅增加本标识；`scripts/verify_app1_archive.py` 16–20 行接受显式 `APP1_VERIFY_BUNDLE_ID` / `APP1_VERIFY_TEAM_ID`，未提供时保留原测试包及 Team 默认值。现有签名、证书、profile、production APNs、topic 和诊断检查均保留。`README.md` 本标识区块说明本地与 CI 身份区别及所需变量。
- CI 在自己的临时 checkout 中，仅调整 App Release 的包名、Team、版本、构建号及两个校验期望值，再执行 `use-profiles`；归档后显式再调用原校验器。本次未编辑本地 `.pbxproj`、scheme、业务代码、Info.plist、entitlements 或后端 App ID，保留用户侧项目版本修改。`.gitignore` 保持原样，现有依赖锁文件必须随工程提供。
- 验证：YAML 解析及全部 11 个脚本块的 Bash 语法通过；临时项目实测仅上述六个 Release 设置变化，Debug、测试、库及后端设置保持一致；APNs 脚本去除本标识后与来源字节一致；原归档校验 8 项测试及新增临时 6 项正式身份正反例通过。独立静态复核未发现阻断问题。未使用真实凭据进行签名、云构建、Apple API 操作或上传，故不声称真实发布成功。
- 定位与回退：未创建 Git 提交。新增 YAML 与 APNs helper 可按本标识整体移除；校验器两行恢复为固定 `app.xltest.com` / `A3PN7W63G3`，README 恢复原配置不存在说明，并移除本索引。保留先前 `WDT_IOS1_BINDING_SETTER_COMPILER_COMPAT_20261113` 编译修复及用户侧工程修改。
<!-- WDT_IOS1_CODEMAGIC_JDT_RELEASE_20261113_END -->

<!-- WDT_IOS1_JDT_SOURCE_REPLACEMENT_20261113_BEGIN -->
## WDT_IOS1_JDT_SOURCE_REPLACEMENT_20261113

- 用户要求将 `/Users/zen/Downloads/ios-chat-1 3` 整包替换到已有 Git 的 `/Users/zen/Desktop/jdt`。新包为当前源码权威，不混合旧 `BlueStoneIM` 的代码、签名配置或测试工程。导入包括此前 Binding 编译修复、Codemagic 配置及当前 `1.0.6` 版本。
- 替换前完整备份：`/Users/zen/Desktop/jdt-backup-before-replace-20261113-69Ec3Q`，含旧 `.git`、原工作区和未提交的 `BlueStoneIM.xcodeproj/project.pbxproj` 签名修改。旧工作区还原样移入备份的 `retired-worktree/`，未销毁旧文件。
- 原 `jdt/.git` 留在原地，保持 `main`、原远程配置、索引及 HEAD `d2dff2db6d190195e65effcac54d8ad9155b0d2b`。未执行 Git 初始化、暂存、提交、推送或触发上传。Git 中旧文件删除、新文件未跟踪是整包替换后的预期状态。
- 导入前进行了独立预检；文件复制排除 `.git`、`.DS_Store`、`xcuserdata` 和 `*.xcuserstate`。旧 `BlueStoneIM` 目录、旧工程及旧测试不残留在工作区。源目录不作修改；导入代码和配置先经 SHA-256 与源逐文件校验一致。
- 导入后的唯一配置差分为 `.gitignore` 本标识区块：允许新的共享 `Package.resolved` 被 Git 跟踪，避免日后提交时遗漏 Codemagic 锁版本构建必需文件；本记录是另一处文档差分。README 中“未建立 Git”的说明描述前一步独立目录配置，此次替换后使用原 `jdt` 仓库。
- 验证记录：备份内容校验通过，导入文件校验通过，原 `.git` 的 HEAD/config/main 引用字节一致。替换后索引缓存发生刷新，经 `git ls-files --stage` 对比备份确认全部索引条目一致，`git diff --cached` 为空；未改动任何暂存内容。未在本轮安装、启动、重新编译或上传 App；编译结果沿用源包上一步的 Debug 验证，不扩大为签名归档结论。
- 回退定位：可按上述备份恢复旧工作区内容，但应保留回退时现有 `.git`，不要覆盖替换之后新增的 Git 操作。业务源码没有新增此标识；以本节、备份和 `.gitignore` 标识定位本次整包替换。
<!-- WDT_IOS1_JDT_SOURCE_REPLACEMENT_20261113_END -->

<!-- WDT_IOS1_ATTACHMENT_UPLOAD_CAPTURE_20261113_BEGIN -->
## WDT_IOS1_ATTACHMENT_UPLOAD_CAPTURE_20261113

- 目的：修复 Codemagic Xcode 26.6 Release 编译中 `AppState+AttachmentUpload.swift` 原 174、183、193、359 行的 `sending 'pending' risks causing data races`。这四处位于两个局部异步函数向 `captureUploadStep` 的 MainActor 闭包捕获上传状态的位置。
- 文件和范围：`WenDaTong/Core/AppSupport/AppState+AttachmentUpload.swift` 172–179、181–191、193–202、362–377 行四处同名标识区块。在 `putAttachment` 的视频、文件 URL、Data 三个分支及 `confirmVideo` 中，诊断闭包显式捕获 `pending.mimeType`（String）和需要时的 `pending.sizeBytes`（Int64），不再捕获整个非 Sendable 的 `pending`。两字段原本为不可变 let，取值不变。请求参数、取消检查、进度、断点恢复、视频确认及备用线路时序保持原样。
- 不修改 `PendingAttachmentUpload` 的 Sendable 合约，不使用 `@unchecked Sendable`，不关闭并发检查，不修改 Codemagic、签名、版本、UI 或其他业务。`requiresAcceptedDeviceBeforeJoin` 未修改变量的警告不属于本次修复。
- 验证：本地 Xcode 26.4 / Swift 6.3 Release 无签名设备编译已复现相同四处错误；仅加局部函数 `@MainActor` 的试验不解决问题，已撤回且不保留。最终值捕获方案经独立 reviewer 静态复核通过；四处差分逆向恢复后与原始 `b71f8a2` 源文件逐字一致。最终完整 `WenDaTong` Release / generic iOS / arm64 编译通过（`CODE_SIGNING_ALLOWED=NO`、`CODE_SIGNING_REQUIRED=NO`、锁定依赖），退出码 0，`BUILD SUCCEEDED`；日志 `/private/tmp/wdt-upload-release-20261113.log`，上述四处错误消失，原有无关警告保留。失败试验日志 `/private/tmp/wdt-upload-release-20261113-actor-only-failed.log`。云端 Xcode 26.6 尚未重跑，未执行签名 Archive、安装、启动、上传或运行时上传测试。
- 合并与回退：原始基线为 `jdt` 的 `b71f8a2`；验证期间用户侧新增 `9e9abc6`，包含不生效的 actor-only 试验，最终工作区已移除该试验，未改写其提交历史。助手未暂存、提交或推送。按四个同名标识定位；回退将闭包参数中的 `mimeType` / `sizeBytes` 恢复为 `pending.mimeType` / `pending.sizeBytes`，移除对应捕获列表、标识及本索引项，保留其他历史修改。
<!-- WDT_IOS1_ATTACHMENT_UPLOAD_CAPTURE_20261113_END -->
