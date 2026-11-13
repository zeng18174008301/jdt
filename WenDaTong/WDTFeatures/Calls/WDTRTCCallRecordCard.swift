import SwiftUI
import IM4Features

struct RTCCallRecordCard: View {
    let record: RTCCallRecordPayload
    let viewerIsCaller: Bool
    let peerName: String
    let outgoing: Bool
    let onRedial: () -> Void
    var body: some View {
        RTCCallRecordCardContent(record: record, viewerIsCaller: viewerIsCaller,
            peerName: peerName, outgoing: outgoing, onRedial: onRedial,
            makePresentation: { record.presentation(viewerIsCaller: viewerIsCaller, timeZone: $0) })
    }
}
