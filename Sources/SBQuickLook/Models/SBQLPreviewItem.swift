//
//  SBPreviewItem.swift
//  SBQuickLook
//
//  Created by Sebastian Baar on 23.02.23.
//

import QuickLook

final internal class SBQLPreviewItem: NSObject, QLPreviewItem {
    public var originalURL: URL?
    public var previewItemURL: URL?
    public var previewItemTitle: String?

    public init(originalURL: URL? = nil, previewItemURL: URL? = nil, previewItemTitle: String? = nil) {
        self.originalURL = originalURL
        self.previewItemURL = previewItemURL
        self.previewItemTitle = previewItemTitle
    }
}
