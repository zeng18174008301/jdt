import IM4Features
import SwiftUI
import UIKit
import QuickLook
import AVFoundation

struct RTCCallRecordRow: View {
    @EnvironmentObject private var state: AppState
    let call: CallRecord

    var body: some View {
        RTCCallRecordRowContent(call: call, avatar: {
            AvatarView(
                name: call.title,
                seed: UInt(bitPattern: (call.peerID.isEmpty ? call.title : call.peerID).hashValue),
                size: 44,
                imageURL: call.peerAvatarURL,
                avatarVersion: call.peerAvatarVersion,
                avatarUpdatedAt: call.peerAvatarUpdatedAt,
                certificationReference: state.certificationPillSource.reference( // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                    forExactUID: call.peerID
                )
            )
        }, certification: {
            CertificationPillView(
                exactUID: call.peerID,
                compact: true
            )
        })
    }
}

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
typealias RTCCallActionKind = IM4Features.RTCCallActionKind

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END
