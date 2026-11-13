import IM4Features
import Security
import SwiftUI
import UIKit
import WebKit

struct IOSSlideCaptchaVerificationOverlay: View {
    let presentationStore: SlideCaptchaPresentationStore // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110
    let challenge: RemoteSlideCaptchaChallenge

    var body: some View {
        AuthSlideCaptchaContent(width: challenge.width, height: challenge.height, pieceSize: challenge.pieceSize,
            pieceY: challenge.pieceY, backgroundImage: { UIImage.slideCaptchaDataURL(challenge.backgroundImage) },
            pieceImage: { UIImage.slideCaptchaDataURL(challenge.pieceImage) }, onCancel: { presentationStore.cancel() },
            onComplete: complete)
    }

    private func complete(dragX: Double, durationMS: Int, points: [SlideCaptchaDragPoint]) {
        let ticket = SlideCaptchaTicket(
            ticket: "",
            randstr: "",
            challengeID: challenge.challengeID,
            lotNumber: "",
            captchaOutput: "",
            passToken: "",
            genTime: String(Int(Date().timeIntervalSince1970)),
            extra: [
                "x": dragX,
                "duration_ms": durationMS,
                "track": points.map { ["x": $0.x, "y": $0.y, "t": $0.t] },
                "surface": "ios"
            ]
        )
        presentationStore.complete(ticket) // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110
    }
}

private extension UIImage {
    static func slideCaptchaDataURL(_ value: String) -> UIImage? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let payload: String
        if let comma = trimmed.firstIndex(of: ",") {
            payload = String(trimmed[trimmed.index(after: comma)...])
        } else {
            payload = trimmed
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return UIImage(data: data)
    }
}
