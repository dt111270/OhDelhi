//
//  SidebarSelection.swift
//  OhDelhi
//
//  The sidebar picks either a time-based smart filter or a status group.
//

import Foundation

enum SidebarSelection: Hashable {
    case smart(SmartFilter)
    case status(DeliveryStatus)

    var displayName: String {
        switch self {
        case .smart(let f):   return f.displayName
        case .status(let s):  return s.displayName
        }
    }
}
