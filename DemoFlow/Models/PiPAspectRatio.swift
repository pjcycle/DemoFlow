//
//  PiPAspectRatio.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import CoreGraphics
import Foundation

enum PiPAspectRatio: String, Codable, CaseIterable, Identifiable {
    case auto = "auto"
    case sixteenByNine = "16:9"
    case fourByThree = "4:3"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .auto:
            return L10n.tr("legacy.key_194")
        case .sixteenByNine:
            return "16:9"
        case .fourByThree:
            return "4:3"
        }
    }

    var widthOverHeight: CGFloat {
        switch self {
        case .auto:
            return 16.0 / 9.0
        case .sixteenByNine:
            return 16.0 / 9.0
        case .fourByThree:
            return 4.0 / 3.0
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return width / widthOverHeight
    }

    func width(forHeight height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return height * widthOverHeight
    }
}
