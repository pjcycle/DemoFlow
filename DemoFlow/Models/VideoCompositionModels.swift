import CoreGraphics
import Foundation

struct VideoTimelineCompositionProject {
    let clips: [VideoTimelineClip]
    let clipStartSeconds: [Double]
    let renderSize: CGSize
    let frameRate: Double
    let outputURL: URL
}

enum VideoCompositionError: LocalizedError {
    case emptyTimeline
    case unsupportedInput
    case invalidVideo
    case outputWorkspaceUnavailable
    case outputMissing
    case outputEmpty
    case invalidCoverDuration
    case coverFrameUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTimeline:
            return L10n.tr("subdub.video_composition.error.empty")
        case .unsupportedInput:
            return L10n.tr("subdub.video_composition.error.unsupported")
        case .invalidVideo:
            return L10n.tr("subdub.video_composition.error.invalid_video")
        case .outputWorkspaceUnavailable:
            return L10n.tr("subdub.video_composition.error.workspace")
        case .outputMissing:
            return L10n.tr("subdub.video_composition.error.output_missing")
        case .outputEmpty:
            return L10n.tr("subdub.video_composition.error.output_empty")
        case .invalidCoverDuration:
            return L10n.tr("subdub.video_composition.error.invalid_cover_duration")
        case .coverFrameUnavailable:
            return L10n.tr("subdub.video_composition.error.cover_frame_unavailable")
        case let .exportFailed(reason):
            return L10n.f("subdub.video_composition.error.export_failed", reason)
        }
    }
}
