//
//  Item.swift
//  Project-Ezra
//
//  Created by Charles Amanze Onyewuenyi on 7/16/26.
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
