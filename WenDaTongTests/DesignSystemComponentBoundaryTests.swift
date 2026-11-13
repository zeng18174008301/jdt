import Foundation
import PhotosUI
import UIKit
import SwiftUI // WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113
import UniformTypeIdentifiers
import XCTest
import IM4DesignSystem
@testable import WenDaTong

// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_BEGIN
@MainActor
final class DesignSystemComponentBoundaryTests: XCTestCase {
    // WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113_BEGIN
    func testSearchInputPublishesOnlyCommittedCompositionAndSubmitsOnce() async throws {
        var query = ""
        var changes: [String] = []
        var submissions: [String] = []
        let input = CommittedSearchInput(
            text: Binding(get: { query }, set: { query = $0; changes.append($0) }),
            placeholder: "搜索",
            onSubmit: { submissions.append(query) }
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: input.frame(height: 44))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        func findEditor(in view: UIView) -> UITextField? {
            (view as? UITextField) ?? view.subviews.lazy.compactMap(findEditor).first
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let editor = try XCTUnwrap(findEditor(in: host.view))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        editor.sendActions(for: .editingChanged)
        XCTAssertNotNil(editor.markedTextRange)
        XCTAssertEqual(changes, [])

        editor.setMarkedText("你好", selectedRange: NSRange(location: 2, length: 0))
        editor.sendActions(for: .editingChanged)
        XCTAssertEqual(changes, [])
        editor.unmarkText()
        editor.sendActions(for: .editingChanged)
        XCTAssertEqual(changes, ["你好"])
        XCTAssertEqual(editor.delegate?.textFieldShouldReturn?(editor), false)
        XCTAssertEqual(submissions, ["你好"])
        XCTAssertEqual(changes, ["你好"])
    }
    // WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113_END

    func testPhotoPickerPackageConfigurationBindsOriginalAppCoordinatorAndCancel() {
        var cancelled = 0
        var picked = 0
        let parent = WenDaTong.PhotoLibraryPickerCompat(
            selectionLimit: 9, filter: .images, prefersFileBackedItems: true,
            onCancel: { cancelled += 1 }, onPicked: { picked += $0.count }
        )
        let coordinator = WenDaTong.PhotoLibraryPickerCompat.Coordinator(parent: parent)
        var bound = false
        let picker = IM4DesignSystem.PhotoLibraryPickerPresentation.makeController(
            selectionLimit: parent.selectionLimit, filter: parent.filter
        ) { controller in
            bound = true
            controller.delegate = coordinator
        }
        XCTAssertTrue(bound)
        XCTAssertTrue(picker.delegate === coordinator)
        XCTAssertEqual(picker.configuration.selectionLimit, 9)
        XCTAssertEqual(picker.configuration.selection, .ordered)
        XCTAssertEqual(picker.configuration.preferredAssetRepresentationMode, .current)
        XCTAssertEqual(picker.configuration.filter, Optional(parent.filter))
        coordinator.picker(picker, didFinishPicking: [])
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(picked, 0)
    }

    func testPhotoPayloadKeepsAppStagingProtectionAndCleanupOwnership() throws {
        let manager = FileManager.default
        let source = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        let bytes = Data("GIF89a-boundary-fixture".utf8)
        try bytes.write(to: source)
        defer { try? manager.removeItem(at: source) }
        let staged = try PendingAttachmentFileStore.stageFile(from: source, preferredName: "picked.gif")
        defer { PendingAttachmentFileStore.removeManagedFile(at: staged.url) }
        let fileItem = WenDaTong.PhotoLibraryPickedItem(file: staged, contentTypes: [.gif])
        let dataItem = WenDaTong.PhotoLibraryPickedItem(data: bytes, contentTypes: [.gif])
        XCTAssertNil(fileItem.data)
        XCTAssertEqual(fileItem.fileURL, staged.url)
        XCTAssertEqual(fileItem.sizeBytes, Int64(bytes.count))
        XCTAssertEqual(fileItem.contentTypes, [.gif])
        XCTAssertEqual(dataItem.data, bytes)
        XCTAssertNil(dataItem.fileURL)
        XCTAssertEqual(dataItem.sizeBytes, Int64(bytes.count))
        XCTAssertNotEqual(dataItem.id, fileItem.id)
        XCTAssertEqual(try Data(contentsOf: source), bytes, "Staging must preserve the provider source")
        XCTAssertEqual(try Data(contentsOf: staged.url), bytes)
        let attributes = try manager.attributesOfItem(atPath: staged.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // WDT_IOS1_PHOTO_PROTECTION_SIMULATOR_READBACK_20261112_BEGIN
        #if targetEnvironment(simulator)
        // Missing metadata is recorded by testStagedPhotoProtectionMetadataWhenRuntimeReportsIt.
        if let protection = attributes[.protectionKey] {
            XCTAssertEqual(protection as? String, FileProtectionType.complete.rawValue)
        }
        #else
        XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
        #endif
        // WDT_IOS1_PHOTO_PROTECTION_SIMULATOR_READBACK_20261112_END
        let directory = try manager.attributesOfItem(atPath: staged.url.deletingLastPathComponent().path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        PendingAttachmentFileStore.removeManagedFile(at: source)
        XCTAssertTrue(manager.fileExists(atPath: source.path), "Unmanaged source must not be removed")
        PendingAttachmentFileStore.removeManagedFile(at: staged.url)
        XCTAssertFalse(manager.fileExists(atPath: staged.url.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testStagedPhotoProtectionMetadataWhenRuntimeReportsIt() throws {
        let manager = FileManager.default
        let source = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        try Data("GIF89a-protection-probe".utf8).write(to: source)
        defer { try? manager.removeItem(at: source) }
        // Probe Foundation directly, independently of the App staging or package.
        try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: source.path)
        let directAttributes = try manager.attributesOfItem(atPath: source.path)
        let rawProtection = directAttributes[.protectionKey]
        let capability = XCTAttachment(string: "direct protectionKey present=\(rawProtection != nil); type=\(rawProtection.map { String(reflecting: type(of: $0)) } ?? "missing"); value=\(rawProtection.map { String(describing: $0) } ?? "missing")")
        capability.name = "direct-Foundation-file-protection-capability"; capability.lifetime = .keepAlways; add(capability)
        #if targetEnvironment(simulator)
        guard directAttributes[.protectionKey] != nil else {
            throw XCTSkip("Simulator Foundation does not report protectionKey after a direct complete request; hardware protection metadata requires a real device")
        }
        #endif
        XCTAssertEqual(directAttributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
        let staged = try PendingAttachmentFileStore.stageFile(from: source, preferredName: "protected.gif")
        defer { PendingAttachmentFileStore.removeManagedFile(at: staged.url) }
        let attributes = try manager.attributesOfItem(atPath: staged.url.path)
        XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
    }
}
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_END
