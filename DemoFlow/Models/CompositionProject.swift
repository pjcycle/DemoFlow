//
//  CompositionProject.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import CoreMedia
import Foundation

struct CompositionLayer: Identifiable, Equatable {
    let id = UUID()
    let assetURL: URL
    let insertTime: CMTime
    let mute: Bool
}

struct CompositionProject {
    let baseAssetURL: URL
    let layers: [CompositionLayer]
}
