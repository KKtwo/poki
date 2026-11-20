import SwiftUI
import UIKit
import XCTest
@testable import Poki

/// Fork-only review evidence. Hosts the production pages, without the app's launch curtain or
/// first-run flow. Run on the signed, disposable Simulator used by scripts/app-tests.sh.
@MainActor
final class PR480MergePageEvidenceTests: XCTestCase {
    func testMergedSettingsAndDestinationsRender() async throws {
        try XCTSkipUnless(AppModel.onSimulator, "Review evidence uses a disposable iPhone Simulator, never an owner's phone")
        try XCTSkipUnless(Bundle.main.preferredLocalizations.first == "en", "Launch with -AppleLanguages (en)")

        let defaults = UserDefaults.standard
        let keys = ["pokiDetailsSample", "pokiSettingsEnd", "pokiLatest", "pokiSigningDays",
                    "pokiSignedIn", "pokiAppleID", "pokiAppleName", "pokiAppleTeams", "pokiAppleState",
                    AppLocalization.key]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let language = AppLocalization.shared.preference
        let effectiveLanguage = SharedContainer.defaults.object(forKey: "effectiveUILanguage")
        defer {
            AppLocalization.shared.preference = language
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            if let effectiveLanguage { SharedContainer.defaults.set(effectiveLanguage, forKey: "effectiveUILanguage") }
            else { SharedContainer.defaults.removeObject(forKey: "effectiveUILanguage") }
        }
        AppLocalization.shared.preference = "en"
        defaults.set(true, forKey: "pokiDetailsSample")
        defaults.set(false, forKey: "pokiSettingsEnd")
        defaults.set("same", forKey: "pokiLatest")
        defaults.set(7.0, forKey: "pokiSigningDays")
        defaults.set(true, forKey: "pokiSignedIn")
        defaults.set("pr480-fixture@example.invalid", forKey: "pokiAppleID")
        defaults.set("Review Fixture", forKey: "pokiAppleName")
        defaults.set(1, forKey: "pokiAppleTeams")
        defaults.removeObject(forKey: "pokiAppleState")

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }, "The signed test host must be in the foreground")
        let covered = scene.windows.map { ($0, $0.accessibilityElementsHidden) }
        let originalKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.overrideUserInterfaceStyle = .light
        covered.forEach { $0.0.accessibilityElementsHidden = true }
        defer {
            window.isHidden = true
            window.rootViewController = nil
            covered.forEach { $0.0.accessibilityElementsHidden = $0.1 }
            originalKeyWindow?.makeKey()
        }

        // Existing Simulator-only signing hooks supply a known account and release locally.
        // lookUp only reads the synthetic release; checkLatest would also consider preparation.
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        await app.signer.reload()
        let foundRelease = await app.signer.lookUp()
        XCTAssertTrue(foundRelease)
        XCTAssertEqual(app.signer.status?.apple_id, "pr480-fixture@example.invalid")
        XCTAssertFalse(app.signer.needsCode)

        // Settings needs a chat environment, not an owner's saved conversation or a model account.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PR480PageChat-\(UUID().uuidString)")
        let suite = "PR480MergePageEvidenceTests.\(UUID().uuidString)"
        let chatDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            chatDefaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let chat = ChatModel(app: app, kind: .handoff,
                             store: SessionStore(folder: folder, defaults: chatDefaults))
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PR480MergePageEvidence", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try await capture("details-top", view: PokiDetailsView(openSetup: {}, path: .constant(NavigationPath())),
                          requires: ["Settings", "Daily Tasks", "Screen History"],
                          app: app, chat: chat, window: window, output: output)

        // The production screenshot hook scrolls its actual List to the last row. Readiness below
        // waits for the bottom rows to enter the viewport, rather than assuming a sleep is enough.
        defaults.set(true, forKey: "pokiSettingsEnd")
        try await capture("details-end", view: PokiDetailsView(openSetup: {}, path: .constant(NavigationPath())),
                          requires: ["Settings", "Signing & Updates", "Advanced"],
                          app: app, chat: chat, window: window, output: output)
        defaults.set(false, forKey: "pokiSettingsEnd")

        try await capture("updates", view: NavigationStack { SigningUpdatesPage().settingsPage() },
                          requires: ["Signing & Updates", "Version", "Latest Version", "Apple Account", "pr480-fixture@example.invalid"],
                          app: app, chat: chat, window: window, output: output)

        // Show only the settings page: no stored-text query, unlocking, toggle, delete, or navigation
        // through HistoryGate. Its production disclosure is part of the target-ready condition.
        try await capture("screenHistory", view: NavigationStack { ScreenHistorySettingsView().settingsPage() },
                          requires: ["Screen History", "View History", "Excluded Apps",
                                     "When Poki or a connected agent queries history",
                                     "relevant text may be sent to the selected AI provider or connected agent."],
                          app: app, chat: chat, window: window, output: output)
    }

    private func capture<V: View>(_ name: String, view: V, requires targets: [String],
                                  app: AppModel, chat: ChatModel, window: UIWindow, output: URL) async throws {
        // A new host gives each production page its own navigation and scroll state.
        window.rootViewController = UIHostingController(rootView: view
            .environment(app).environment(chat).environment(\.locale, AppLocalization.locale))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        CATransaction.flush()

        var source = ""
        var failure = ""
        var missing = targets
        var consecutiveReady = 0
        let deadline = CACurrentMediaTime() + 30
        repeat {
            let snapshot = await Task.detached { () -> (String, String) in
                var code: NSString?
                let xml = PKInProcess.shared().sourceXML(nil, code: &code) ?? ""
                return (xml, code.map { $0 as String } ?? "")
            }.value
            source = snapshot.0
            failure = snapshot.1
            if let page = try? PR480PageElements(source) {
                missing = targets.filter { !page.containsVisible($0, in: window.frame) }
            } else {
                missing = targets
            }
            consecutiveReady = missing.isEmpty ? consecutiveReady + 1 : 0
            if consecutiveReady >= 2 { break }
            try await Task.sleep(for: .milliseconds(200))
        } while CACurrentMediaTime() < deadline

        // Preserve the actual last tree even when authorization or content readiness fails.
        try source.write(to: output.appendingPathComponent("\(name).xml"), atomically: true, encoding: .utf8)
        _ = try XCTUnwrap(consecutiveReady >= 2 ? true : nil,
                          "\(name) did not show target content in the viewport; missing=\(missing), sourceXML code=\(failure)")
        let picture = await Task.detached { () -> (Data?, String) in
            var code: NSString?
            let image = PKInProcess.shared().screenshot(&code)
            return (image, code.map { $0 as String } ?? "")
        }.value
        try XCTUnwrap(picture.0, "\(name): screenshot failed: \(picture.1)")
            .write(to: output.appendingPathComponent("\(name).png"))
    }
}

/// A target counts only while its accessibility frame is on this screen, not an offscreen List
/// row retained in the tree. Container names alone are not evidence of a rendered destination.
private final class PR480PageElements: NSObject, XMLParserDelegate {
    private struct Element {
        let words: [String]
        let frame: CGRect
    }
    private var elements: [Element] = []

    init(_ source: String) throws {
        super.init()
        let parser = XMLParser(data: Data(source.utf8))
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "PR480MergePageEvidenceTests", code: 1)
        }
    }

    func containsVisible(_ target: String, in viewport: CGRect) -> Bool {
        elements.contains { element in
            !element.frame.isEmpty && viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) &&
            element.words.contains { $0 == target || $0.contains(target) }
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard !["XCUIElementTypeApplication", "XCUIElementTypeWindow", "XCUIElementTypeImage"].contains(elementName),
              attributes["visible"] != "false",
              let x = attributes["x"].flatMap(Double.init), let y = attributes["y"].flatMap(Double.init),
              let width = attributes["width"].flatMap(Double.init), let height = attributes["height"].flatMap(Double.init) else { return }
        let words = ["label", "value"].compactMap { attributes[$0] }.filter { !$0.isEmpty }
        elements.append(Element(words: words, frame: CGRect(x: x, y: y, width: width, height: height)))
    }
}
