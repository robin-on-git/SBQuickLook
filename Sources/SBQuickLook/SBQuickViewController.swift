//
//  SBQuickViewController.swift
//  SBQuickLook
//
//  Created by Sebastian Baar on 23.02.23.
//

import UIKit
import SwiftUI
import QuickLook

extension UIView {

   /**
    Wrapper for useful debugging description of view hierarchy
   */
   var recursiveDescription: NSString {
       return value(forKey: "recursiveDescription") as! NSString
   }
    
    func findSubview<T: UIView>(ofType type: T.Type, condition: ((T) -> (Bool))? = nil) -> UIView? {
        for subview in self.subviews {
            guard let condition
            else {
                if let subview = subview as? T {
                    return subview
                } else if let foundIt = subview.findSubview(ofType: type) {
                    return foundIt
                }
                continue
            }
            
            if let subview = subview as? T, condition(subview) {
                return subview
            } else if let foundIt = subview.findSubview(ofType: type, condition: condition) {
                return foundIt
            }
        }
        return nil
    }

}

public class CustomQLPreviewController: QLPreviewController, UIGestureRecognizerDelegate {
    
    public override var currentPreviewItemIndex: Int {
        get {
            super.currentPreviewItemIndex
        }
        set {
            super.currentPreviewItemIndex = newValue
        }
    }
    
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // Waiting for navigation controler to appear
        if let navController = children.first as? UINavigationController {
            // If nav controller present, find `Done` label in hierarchy
            let btnLabel = navController.navigationBar.findSubview(ofType: UILabel.self) { label in
                label.text == "Done"
            }
            let doneButton = btnLabel?.superview?.superview
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(previewDone))
            tapGesture.delegate = self
            doneButton?.addGestureRecognizer(tapGesture)
        }
    }
    
    // Fixes bottom toolbar not animating when view dismisses
    @objc func previewDone(sender: UIGestureRecognizer) {
        UIView.animate(withDuration: 0.4) {
            self.view.alpha = 0
        }
        // Calling original dismiss manually because the original recognizer can't be triggered simultaneously
        self.dismiss(animated: true)
    }
    
}

/// The `SBQuickViewController` to preview one or multiple files
public final class SBQuickViewController: NSObject {
    public let qlController: CustomQLPreviewController
    internal var previewItems: [SBQLPreviewItem] = []

    // - MARK: Public
    public var fileItems: [SBQLFileItem] {
        didSet {
            showPreviewController()
        }
    }
    public let configuration: SBQLConfiguration?
    public let completion: ((Result<SBQLError?, SBQLError>) -> Void)?
    public var currentPreviewItemIndex = 0 {
        didSet {
            if currentPreviewItemIndex < fileItems.count {
                qlController.currentPreviewItemIndex = currentPreviewItemIndex
            }
        }
    }

    /// Initializes the `SBQuickViewController` with the given file items and configuration.
    /// - Parameters:
    ///   - fileItems: The `[SBQLFileItem]` data for populating the preview. Could be one or many items.
    ///   - configuration: Optional `SBQLConfiguration` configurations.
    ///   - completion: Optional `Result<SBQLError?, SBQLError>` completion.
    ///      - success: `QLPreviewController` successfully presented with at least one item. Optional `SBQLError` if some items failed to download.
    ///      - failure: `QLPreviewController` could not be  presented.
    public init(
        fileItems: [SBQLFileItem],
        configuration: SBQLConfiguration? = nil,
        completion: ((Result<SBQLError?, SBQLError>) -> Void)? = nil) {
            self.qlController = CustomQLPreviewController()
            self.fileItems = fileItems
            self.configuration = configuration
            self.completion = completion
            
            super.init()
            
            qlController.dataSource = self
            qlController.delegate = self
            qlController.currentPreviewItemIndex = 0
            
            preloadPlaceholder()
        }

    required init?(coder: NSCoder) {
        fatalError("SBQuickLook: init(coder:) has not been implemented")
    }
    
    private func preloadPlaceholder() {
        
        Task {
            
            var session = URLSession.shared
            if let customSession = configuration?.session {
                session = customSession
            }
            
            let (url, _) = try await session.download(from: URL(string: "https://icon-library.com/images/preview-icon_101018.png")!)
            let fileManager = FileManager.default
            var localFileDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            if let customLocalFileDir = configuration?.localFileDir {
                localFileDir = customLocalFileDir
            }
            let localFileUrl = localFileDir.appendingPathComponent("loadingPlaceholderImage.png")
                
            do {
                try FileManager.default.moveItem(at: url, to: localFileUrl)
            } catch {
                print("Failed to move placeholder")
            }
            
        }
        
    }
    
    public func showPreviewController() {
        
        qlController.view.alpha = 1
        let fileManager = FileManager.default
        var localFileDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        if let customLocalFileDir = configuration?.localFileDir {
            localFileDir = customLocalFileDir
        }
        let placeholderLocation = localFileDir.appendingPathComponent("loadingPlaceholderImage.png")
        
        print(fileItems)
        
        self.previewItems = fileItems.map { SBQLPreviewItem(previewItemURL: placeholderLocation, previewItemTitle: $0.title) }
        qlController.reloadData()

        downloadFiles { [weak self] itemsToPreview, downloadError in
            guard let self else { return }
            
            guard itemsToPreview.count > 0 else {
                self.completion?(.failure(downloadError!))
                qlController.dismiss(animated: false)
                return
            }

            self.previewItems = itemsToPreview.sorted(by: { firstItem, secondItem in
                guard let firstItemIndex = self.fileItems.firstIndex(where: { $0.url == firstItem.originalURL }),
                      let secondItemIndex = self.fileItems.firstIndex(where: { $0.url == secondItem.originalURL }) else {
                    return false
                }
                return firstItemIndex < secondItemIndex
            })
            self.completion?(.success(downloadError))
            qlController.reloadData()
        }
    }
}

extension SBQuickViewController {

    // swiftlint:disable function_body_length
    private func downloadFiles(_ completion: @escaping ([SBQLPreviewItem], SBQLError?) -> Void) {
        let taskGroup = DispatchGroup()

        var session = URLSession.shared
        if let customSession = configuration?.session {
            session = customSession
        }

        var itemsToPreview: [SBQLPreviewItem] = []
        var failedItems: [SBQLFileItem: Error] = [:]

        for item in fileItems {
            let fileInfo = self.getFileNameAndExtension(item.url)

            let fileExtension = (item.mediaType != nil && item.mediaType?.isEmpty == false) ?
            item.mediaType! :
            fileInfo.fileExtension
            let title = (item.title != nil && item.title?.isEmpty == false) ?
            item.title :
            fileInfo.fileName

            if item.url.isFileURL {
                itemsToPreview.append(
                    SBQLPreviewItem(
                        originalURL: item.url,
                        previewItemURL: item.url,
                        previewItemTitle: title
                    )
                )

                continue
            }

            let fileManager = FileManager.default
            var localFileDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            if let customLocalFileDir = configuration?.localFileDir {
                localFileDir = customLocalFileDir
            }
            let localFileUrl = localFileDir.appendingPathComponent("\(fileInfo.fileName).\(fileExtension)")

            if fileManager.fileExists(atPath: localFileUrl.path) {
//                do {
//                    try fileManager.removeItem(atPath: localFileUrl.path)
//                } catch {
                    itemsToPreview.append(
                        SBQLPreviewItem(
                            originalURL: item.url,
                            previewItemURL: localFileUrl,
                            previewItemTitle: title
                        )
                    )

                    continue
//                }
            }

            taskGroup.enter()

            var request = URLRequest(url: item.url)
//            if var customURLRequest = item.urlRequest {
//                customURLRequest.url = item.url
//                request = customURLRequest
//            }
            session.downloadTask(with: request) { location, _, error in
                guard let location, error == nil else {
                    failedItems[item] = error
                    taskGroup.leave()
                    return
                }

                do {
                    try FileManager.default.moveItem(at: location, to: localFileUrl)

                    itemsToPreview.append(
                        SBQLPreviewItem(
                            originalURL: item.url,
                            previewItemURL: localFileUrl,
                            previewItemTitle: title
                        )
                    )

                    taskGroup.leave()
                } catch let error {
                    print(error)
                    failedItems[item] = error
                    taskGroup.leave()
                }
            }.resume()
        }

        taskGroup.notify(queue: .main) {
            var downloadError: SBQLError?
            if failedItems.count > 0 {
                downloadError = SBQLError(type: .download(failedItems))
            }

            completion(
                itemsToPreview,
                downloadError
            )
        }
    }
    // swiftlint:enable function_body_length

    private func getFileNameAndExtension(_ fileURL: URL) -> (fileName: String, fileExtension: String) {
        let urlExtension = fileURL.pathExtension
        let fileExtension = urlExtension.isEmpty ? "file" : urlExtension
        let urlFileName = fileURL.lastPathComponent.replacingOccurrences(of: ".\(fileExtension)", with: "").addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        let fileName = urlFileName?.isEmpty == true ?
            UUID().uuidString :
            urlFileName!

        return (fileName, fileExtension)
    }
}
