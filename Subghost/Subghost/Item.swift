//
//  Item.swift
//  Subghost
//
//  Created by hara ryuto   on 2026/07/16.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
