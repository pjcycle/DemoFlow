//
//  AudioLevelMeterView.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import SwiftUI

struct AudioLevelMeterView: View {
    let level: Double

    private var clampedLevel: Double {
        min(max(level, 0), 1)
    }

    private var meterColor: Color {
        switch clampedLevel {
        case 0.0..<0.55:
            return .green
        case 0.55..<0.8:
            return .yellow
        default:
            return .red
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))

                RoundedRectangle(cornerRadius: 6)
                    .fill(meterColor)
                    .frame(width: proxy.size.width * clampedLevel)
                    .animation(.easeOut(duration: 0.12), value: clampedLevel)
            }
        }
        .frame(height: 12)
        .accessibilityLabel(L10n.tr("legacy.key_220"))
        .accessibilityValue(Text("\(Int(clampedLevel * 100))"))
    }
}
