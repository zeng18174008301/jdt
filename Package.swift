// swift-tools-version:6.1
import PackageDescription

// WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_BEGIN
let package = Package(
    name: "IM4Core",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "IM4Core", type: .static, targets: ["IM4Core"]),
        // WDT_IOS1_DESIGNSYSTEM_ACTUAL_ASSEMBLY_20261110_BEGIN
        .library(name: "IM4DesignSystem", type: .static, targets: ["IM4DesignSystem"]),
        // WDT_IOS1_DESIGNSYSTEM_ACTUAL_ASSEMBLY_20261110_END
        // WDT_IOS1_DOMAIN_ACTUAL_ASSEMBLY_20261110_BEGIN
        .library(name: "IM4Domain", type: .static, targets: ["IM4Domain"]),
        // WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
        .library(name: "IM4Data", type: .static, targets: ["IM4Data"]),
        // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_BEGIN
        .library(name: "IM4Stores", type: .static, targets: ["IM4Stores"]),
        .library(name: "IM4Features", type: .static, targets: ["IM4Features"]) // WDT_IOS1_FEATURES_ATTACHMENT_APPROVED305_PHYSICAL_20261111
        // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_END
        // WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
        // WDT_IOS1_DOMAIN_ACTUAL_ASSEMBLY_20261110_END
    ],
    // WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    // WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
    targets: [
        .target(name: "IM4Core"),
        // WDT_IOS1_DESIGNSYSTEM_ACTUAL_ASSEMBLY_20261110_BEGIN
        .target(
            name: "IM4DesignSystem",
            path: "WenDaTong",
            exclude: [
                // WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_BEGIN
                "App", // App assembly remains in the App target.
                // WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_END
                // WDT_IOS1_PROJECT_RESOURCES_20261113_BEGIN
                "WDTConfiguration",
                "WDTDocs",
                "WDTResources",
                "WDTDesignSystem/AuthBackground.metal",
                // WDT_IOS1_PROJECT_RESOURCES_20261113_END
                "Core",
                "WDTDesignSystem/AvatarImagePipeline.swift",
                "WDTDesignSystem/AvatarViews.swift",
                "WDTDesignSystem/GroupInviteApprovalCard.swift",
                "WDTDesignSystem/PhotoLibraryPickerCompat.swift",
                "WDTDesignSystem/DesignSystemModuleBridge.swift",
                // WDT_IOS1_DOMAIN_ACTUAL_ASSEMBLY_20261110_BEGIN
                // WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
                // WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
                // WDT_IOS1_DOMAIN_ACTUAL_ASSEMBLY_20261110_END
                "Domain",
                "WDTFeatures",
                "GroupDetails",
                // WDT_IOS1_CURRENT_FEATURE_ROUTING_ASSEMBLY_20261110_BEGIN
                "Navigation", // App-level SwiftUI routing contracts are not DS implementation.
                // WDT_IOS1_CURRENT_FEATURE_ROUTING_ASSEMBLY_20261110_END
                "Stores",
                "ThirdParty",
            ],
            sources: [
                "WDTDesignSystem/SheetHeader.swift", // WDT_IOS1_FEATURES_ATTACHMENT_APPROVED305_PHYSICAL_20261111
                "WDTDesignSystem/WDTDesignSystem.swift",
                "WDTDesignSystem/AuthBackgroundViews.swift",
                "WDTDesignSystem/CommonControlViews.swift",
                "WDTDesignSystem/SwiftUICompatibility.swift",
                "WDTDesignSystem/NavigationGestureInstallers.swift",
                "WDTDesignSystem/DesignSystemModuleExports.swift",
                "WDTDesignSystem/AvatarPresentationViews.swift",
                "WDTDesignSystem/ApprovalPresentationViews.swift",
                "WDTDesignSystem/PhotoLibraryPresentation.swift"
]
        ),
        // WDT_IOS1_DESIGNSYSTEM_ACTUAL_ASSEMBLY_20261110_END
        // WDT_IOS1_DOMAIN_ACTUAL_ASSEMBLY_20261110_BEGIN
        .target(
            name: "IM4Domain",
            path: "Sources/IM4Domain",
            sources: [
                "BatchForwardModels.swift", "VoiceMessageModels.swift", "EmojiCatalogValues.swift",
                "MessageDerivationTrace.swift", // WDT_IOS1_SDK_GET_V3_20261111

                "ConversationFacadeModels.swift", "ConversationSyncModels.swift", // WDT_IOS1_CONVERSATION_FACADE_FAMILY_20261111

                // WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
                "AccountNotificationWireValues.swift",
                // WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END
                "IMSessionLifetimeMode.swift",
                // WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
                "RTCWireValues.swift",
                // WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END // WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110

                "AttachmentUploadFailure.swift",
                "FileModels.swift",
                "FavoriteAssetModels.swift",
                "AttachmentRuntimeValues.swift", // WDT_IOS1_FILESTORE_COMPLETE_FAMILY_20261111
                "CallStateValues.swift",
                "CallLifecycleValues.swift",
                "CallMediaEvents.swift", // WDT_IOS1_CALLS_COMPLETE_FAMILY_20261111
                "BatchForwardSenderProvenance.swift",
                "ChatMessageModels.swift",
                "ContactModels.swift",
                "ConversationMessageSnapshot.swift",
                "ConversationModels.swift",
                "GroupModels.swift",
                "GroupMuteModeValue.swift",
                "RTCCallRecordAuthority.swift",
                "AttachmentDownloadSnapshot.swift",
                "RTCCallRecordValues.swift",
                "StickerMessageModels.swift",
                "StickerLibraryStateModels.swift", // WDT_IOS1_STICKER_STATE_FAMILY_20261110
                // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_BEGIN
                "InboxDeviceProjectionValues.swift",
                // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_END
                // WDT_IOS1_DATA_NETWORK_DTO_20261110_BEGIN
                // WDT_IOS1_DATA_NETWORK_DTO_20261110_END
                // WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_BEGIN
                "LoginLogValue.swift",
                // WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_END
                // WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_BEGIN
                "GroupMuteModeStateModels.swift",
                // WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_END
            ]
        ),
        // WDT_IOS1_DOMAIN_ACTUAL_ASSEMBLY_20261110_END
        // WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
        .target(
            name: "IM4Data",
            dependencies: ["IM4Core", "IM4Domain", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/IM4Data",
            sources: [
                // WDT_IOS1_DATA17_M17_REAL_IO_CONSUMERS_20261111_BEGIN
                "RotatingLogFileStorage.swift",
                "CallRecordArchiveStorage.swift",
                // WDT_IOS1_DATA17_M17_REAL_IO_CONSUMERS_20261111_END
                // WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
                "NetworkingDTO/AccountPolicyWireModels.swift",
                "NetworkingDTO/AppPolicyWireRecord.swift",
                "NetworkingDTO/BootstrapWireRecord.swift",
                "NetworkingDTO/DeviceNotificationWireModels.swift",
                "NetworkingDTO/DirectoryPageWireModels.swift",
                "NetworkingDTO/GroupFileWireModels.swift",
                "NetworkingDTO/FavoriteFileWireModels.swift",
                "NetworkingDTO/UserFileWireModels.swift",
                "NetworkingDTO/SplashWireRecord.swift",
                "NetworkingDTO/GroupCreationWireModels.swift",
                "NetworkingDTO/InviteReviewWireModels.swift",
                "NetworkingDTO/LegalDocumentWireRecords.swift",
                "NetworkingDTO/MessageMutationWireModels.swift",
                "NetworkingDTO/NetworkDTOStrictScalarDecoding.swift",
                // WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END
                "NetworkingDTO/AuthSessionWireModels.swift", // WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110
                "NetworkingDTO/EnterpriseEntryWireModels.swift", // WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110
                "NetworkingDTO/LoginWireModels.swift", // WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110
                "NetworkingDTO/RuntimeRouteWireModels.swift", // WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110
                "NetworkingDTO/StoredAuthSessionWireRecord.swift",
                // WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
                "NetworkingDTO/RTCSignalingWireModels.swift",
                "NetworkingDTO/RTCCallWireModels.swift",
                "NetworkingDTO/RTCEventWireModels.swift",
                "NetworkingDTO/RTCMediaWireModels.swift",
                "NetworkingDTO/RTCConnectionWireModels.swift",
                // WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111_BEGIN
                "NetworkingDTO/SearchResponseWireModels.swift",
                "NetworkingDTO/SearchResultWireModels.swift",
                "NetworkingDTO/SearchConversationWireModels.swift",
                // WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111_END
                // WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END // WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110
                "NetworkingDTO/TenantMembershipWireModels.swift", // WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110
                "NetworkingDTO/WorkspaceMutationWireModels.swift", // WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110

                "WDTDataAttachmentTransferRepository.swift",
                "CachedRemoteSnapshotRecords.swift",
                "StickerManifestRecordStore.swift", // WDT_IOS1_STICKER_MANIFEST_DATA_20261111
                "WDTDataLocalMessageRepository.swift",
                "MediaCacheIndexRecords.swift",
                // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_BEGIN
                "MediaBlobCacheRecords.swift",
                "MediaBlobIntegrity.swift",
                "MediaBlobCacheStorage.swift",
                "MediaBlobFileIO.swift",
                // WDT_IOS1_DATA17_MEDIA_BLOB_CACHE_20261111_END
                "MessageAttachmentChecksum.swift",
                "WDTDataMessageDatabaseMigrations.swift",
                "WDTDataMessageDatabasePaths.swift",
                "WDTDataMessageDatabaseSchema.swift",
                "MessagePersistenceModelCodec.swift",
                "PendingAttachmentFileStore.swift",
                "ProfileContactProjectionRecords.swift",
                "SQLiteMessageRepository+Acknowledgements.swift",
                "SQLiteMessageRepository+MediaCache.swift",
                "SQLiteMessageRepository+Outbox.swift",
                "SQLiteMessageRepository+Projection.swift",
                "WDTDataSQLiteMessageRepository.swift",
                "SnapshotDiskCache.swift",
                // WDT_IOS1_DATA_NETWORK_DTO_20261110_BEGIN
                "NetworkingDTO/NetworkDTOScalarDecoding.swift",
                // WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
                "NetworkingDTO/RemoteDirectoryModels.swift",
                "NetworkingDTO/RemoteContactModels.swift",
                // WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110_BEGIN
                "NetworkingDTO/RemoteGroupProfileModels.swift",
                "NetworkingDTO/RemoteGroupMembershipModels.swift",
                "NetworkingDTO/RemoteGroupLifecycleModels.swift",
                // WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
                "NetworkingDTO/RemoteGroupMutationModels.swift",
                "NetworkingDTO/RemoteSearchSyncModels.swift",
                // WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END
                // WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110_END
                // WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END
                "NetworkingDTO/RemoteAvatarUploadModels.swift",
                "NetworkingDTO/RemoteStickerModels.swift",
                // WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
                "NetworkingDTO/RemoteConversationModels.swift",
                "NetworkingDTO/RemoteMessageModels.swift",
                "NetworkingDTO/RemoteMessageEventModels.swift",
                "NetworkingDTO/RemoteMessageReceiptModels.swift",
                "NetworkingDTO/JSONValue.swift",
                // WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_BEGIN
                "NetworkingDTO/RemoteAccountProfileIdentityModels.swift",
                "NetworkingDTO/RemoteAccountMutationResponseModels.swift",
                // WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_BEGIN
                "NetworkingDTO/RemoteAuthChallengeModels.swift",
                // WDT_IOS1_DATA_AUTH_CHALLENGE_VERIFICATION_DTO_20261110_END
                // WDT_IOS1_DATA_ACCOUNT_PROFILE_WIRE_DTO_20261110_END
                // WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END
                // WDT_IOS1_DATA_NETWORK_DTO_20261110_END
                // WDT_IOS1_DATA_HTTP_MECHANISM_20261110_BEGIN
                "Networking/HTTPInFlightRequestStore.swift",
                "Networking/URLSessionHTTPTransport.swift",
                // WDT_IOS1_DATA_HTTP_MECHANISM_20261110_END
                // WDT_IOS1_DATA5_THROUGH8_MAIN42_ACTUAL_20261111_BEGIN
                "ProtectedSessionStore.swift",
                "CurrentUserIdentityRecords.swift",
                "CurrentUserIdentityRecordStore.swift",
                "RuntimeRouteRecords.swift",
                "RuntimeRouteRecordStorage.swift",
                "BrandWireCodecs.swift",
                // WDT_IOS1_BOOTSTRAP_DATA15_16_20261111_BEGIN
                "PreloginLastGoodStorage.swift",
                "PreloginHTTPSClient.swift",
                "AppBootstrapLastGoodRecords.swift",
                // WDT_IOS1_BOOTSTRAP_DATA15_16_20261111_END
                // WDT_IOS1_DATA5_THROUGH8_MAIN42_ACTUAL_20261111_END
                // WDT_IOS1_DATA17_M9_M10_M11_M14_ACTUAL_20261111_BEGIN
                "HTTPEnvelopeRecords.swift",
                "NativeRealtimeQUIC.swift",
                "NativeRealtimeTransportContracts.swift",
                "NativeRealtimeWebSocket.swift",
                "RealtimeWireFrame.swift",
                "MediaDownloadByteIO.swift",
                "SplashImageByteIO.swift",
                // WDT_IOS1_DATA17_M9_M10_M11_M14_ACTUAL_20261111_END
            ]
        ),
        // WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
        // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_BEGIN
        .target(name: "IM4Stores", dependencies: ["IM4Domain", "IM4Data"], path: "Sources/IM4Stores",
                  sources: [
                            "ConversationSequenceInspector.swift", "WDTStoresConversationStore.swift", "ConversationStore+History.swift", "ConversationStore+HistoryMerge.swift", "ConversationStore+Lifecycle.swift", "ConversationStore+LocalMessages.swift", "ConversationStore+MessageExtras.swift", "ConversationStore+ReadState.swift", "ConversationStore+RemoteMerge.swift", "ConversationStore+Sync.swift", "ConversationStore+ContextTypes.swift", "ConversationStore+MutationTypes.swift", "ConversationStore+Observation.swift", "ConversationStore+PreparedRealtime.swift", "CachedConversationHistoryProjection.swift", "ConversationMessageExtraIdentity.swift", // WDT_IOS1_CONVERSATION_FACADE_FAMILY_20261111
"WDTStoresCallStore.swift", "CallLifecycleStateMachine.swift", "CallPromptCoordinator.swift", "VoiceCallSession.swift", "WDTStoresFileStore.swift", "WDTStoresContactStore.swift", "ConversationMemoryFrame.swift", "ConversationMemoryDerivation.swift",
                            "MessageMemoryDiagnostic.swift", "ScopedMessageMemoryStore.swift", "MessageWindowRetention.swift", "WDTStoresStickerStore.swift", /* WDT_IOS1_STICKER_STATE_FAMILY_20261110 */
                            // WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_BEGIN
                            "LoginLogStore.swift",
                            // WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_END
                            // WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_BEGIN
                            "GroupModerationStore.swift",
                            "OrganizationDirectoryStore.swift", // WDT_IOS1_STORES_ORGANIZATION_DIRECTORY_OWNER_20261111
                            // WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_END
                            "ConversationMessageMergeReducer.swift",
                            "ConversationMessageMergeReducer+Acceptance.swift",
                            "ConversationMessageMergeReducer+Finish.swift",
                            "ConversationMessageMergeReducer+Values.swift",
                            "ConversationMessageMergeReducer+OlderHistory.swift", // WDT_IOS1_STAGE6_SHARED_PURE_MERGE_20261111
]),
        // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_END
        .target(name: "IM4Features", dependencies: ["IM4Domain", "IM4DesignSystem"],
                sources: ["ChatAttachmentDetail.swift", "ChatAttachmentPreview.swift", "Chat", "Calls", "Auth", "Conversations", "Files", "Me", "Contacts"]), // WDT_IOS1_FEATURES_SURFACE_PACKAGE_20261111
    ],
    swiftLanguageModes: [.v6]
)
// WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_END
