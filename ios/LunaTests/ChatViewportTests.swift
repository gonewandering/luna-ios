import XCTest
import SwiftUI
@testable import Luna

final class ChatViewportTests: XCTestCase {
    @MainActor func testSharedComposerOnHomeAgentListAndChat() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LunaStore(root: root, loadSavedState: false)
        await store.startDemo()
        let profile = try XCTUnwrap(store.profiles.first)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LunaRootView(store: store).tint(Palette.forest).preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for (name, path) in [("Home composer", [LunaRoute]()), ("Agent list composer", [.agent(profile.id)]),
                             ("Session composer", [.agent(profile.id), .session(SessionAddress(agentID: profile.id, sessionID: "demo-design"))])] {
            store.navigation = path
            try await Task.sleep(for: .milliseconds(650))
            window.layoutIfNeeded()
            let inputs = textInputs(in: window)
            XCTAssertTrue(inputs.contains { $0.accessibilityIdentifier == "message-input" || $0 is UITextView }, "Missing message composer on \(name)")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertFalse(store.voice.isActive)

            store.voice.state = .listening
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            XCTAssertFalse(textInputs(in: window).contains { $0 is UITextView || $0.accessibilityIdentifier == "message-input" },
                           "Message composer remained visible during voice on \(name)")
            if name == "Home composer" {
                let activeImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let activeAttachment = XCTAttachment(image: activeImage); activeAttachment.name = "Home voice hides composer"; activeAttachment.lifetime = .keepAlways; add(activeAttachment)
            }
            store.voice.state = .idle
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            XCTAssertTrue(textInputs(in: window).contains { $0 is UITextView || $0.accessibilityIdentifier == "message-input" },
                          "Message composer did not return after voice stopped on \(name)")
        }
        store.navigation = [.agent(profile.id)]
        store.lunaText.messages = [ChatMessage(id: "reply", role: "assistant", content: "I found two conversations about the dark interface. Which agent would you like to use?", createdAt: 1)]
        store.lunaText.draft = "Use Research demo"
        try await Task.sleep(for: .milliseconds(400))
        let editor = try XCTUnwrap(textInputs(in: window).first { $0 is UITextView })
        XCTAssertTrue(editor.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(450))
        let keyboardImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let keyboardAttachment = XCTAttachment(image: keyboardImage); keyboardAttachment.name = "Luna clarification and typed follow-up"; keyboardAttachment.lifetime = .keepAlways; add(keyboardAttachment)
        editor.resignFirstResponder()
        for runtime in store.runtimes.values { await runtime.disconnect() }
    }

    @MainActor func testUserAtBottomFollowsNewMessagesAndStreamingReplies() async throws {
        let store = AppStore(loadSavedState: false)
        let session = AgentSession(id: "viewport", title: "Chat viewport check", preview: "", source: "Test", updatedAt: 1, messageCount: 20)
        store.sessions = [session]
        store.messages[session.id] = (0..<20).map {
            ChatMessage(id: "m-\($0)", role: "user", content: "Earlier message \($0)\n" + String(repeating: "A line of conversation.\n", count: 3), createdAt: Double($0))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChatView(store: store, session: session) }.preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(400))
        let scroll = try XCTUnwrap(scrollViews(in: window).max { $0.contentSize.height < $1.contentSize.height })
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height * 2)
        await assertBottom(scroll, window: window)

        // A user who stays at the bottom keeps following new messages...
        store.messages[session.id]?.append(ChatMessage(id: "new", role: "user", content: "The latest incoming message", createdAt: 21))
        await assertBottom(scroll, window: window)

        // ...and a streaming reply that grows in place.
        store.runs["stream"] = AgentRun(id: "stream", sessionID: session.id, text: "Show a streaming reply", status: "running", output: "The reply is starting.", created: 22)
        await assertBottom(scroll, window: window)
        for index in 0..<3 {
            store.runs["stream"]?.output += "\n\n" + String(repeating: "Streaming paragraph \(index). ", count: 25)
            await assertBottom(scroll, window: window)
        }
        store.runs["stream"]?.output += "\n\nLatest streamed content is visible."
        await assertBottom(scroll, window: window)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "Chat follows streamed content when at bottom"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testUserScrolledUpIsNotMovedByResponseUpdatesOrReconciliation() async throws {
        let store = AppStore(loadSavedState: false)
        let session = AgentSession(id: "viewport", title: "Chat viewport check", preview: "", source: "Test", updatedAt: 1, messageCount: 20)
        store.sessions = [session]
        store.messages[session.id] = (0..<20).map {
            ChatMessage(id: "m-\($0)", role: "user", content: "Earlier message \($0)\n" + String(repeating: "A line of conversation.\n", count: 3), createdAt: Double($0))
        }
        // A run whose streamed answer is already on screen (rendered by a RunCard).
        store.runs["stream"] = AgentRun(id: "stream", sessionID: session.id, text: "A question", status: "running", output: "A partial streamed answer.", created: 22)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChatView(store: store, session: session) }.preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(400))
        let scroll = try XCTUnwrap(scrollViews(in: window).max { $0.contentSize.height < $1.contentSize.height })
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height * 2)

        // The user scrolls up to read earlier messages.
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        await settle(scroll, window: window)
        let restingOffset = scroll.contentOffset.y

        // 1) An incoming message must not yank the viewport down.
        store.messages[session.id]?.append(ChatMessage(id: "incoming", role: "assistant", content: "An unrelated new message", createdAt: 23))
        await settle(scroll, window: window)
        XCTAssertEqual(scroll.contentOffset.y, restingOffset, accuracy: 3, "An incoming message moved a scrolled-up user")

        // 2) The active run's streamed output growing must not move the user.
        store.runs["stream"]?.output += "\n\n" + String(repeating: "More streamed text. ", count: 40)
        await settle(scroll, window: window)
        XCTAssertEqual(scroll.contentOffset.y, restingOffset, accuracy: 3, "A growing stream moved a scrolled-up user")

        // 3) Reconciliation (run -> server message identity swap) must not move the user.
        store.messages[session.id]?.append(ChatMessage(id: "server-answer", role: "assistant", content: store.runs["stream"]!.output, createdAt: 24))
        store.runs["stream"]?.status = "completed"
        store.runs["stream"]?.historyReconciled = true
        await settle(scroll, window: window)
        XCTAssertEqual(scroll.contentOffset.y, restingOffset, accuracy: 3, "Reconciliation moved a scrolled-up user")
        XCTAssertTrue(ChatView.visibleRuns(sessionID: session.id, runs: store.runs.values).isEmpty, "Run should be reconciled out of the visible set")
    }

    @MainActor private func settle(_ scroll: UIScrollView, window: UIWindow) async {
        for _ in 0..<12 { window.layoutIfNeeded(); try? await Task.sleep(for: .milliseconds(40)) }
    }

    @MainActor private func assertBottom(_ scroll: UIScrollView, window: UIWindow, file: StaticString = #filePath, line: UInt = #line) async {
        // Allow SwiftUI's lazy content measurement to settle across layout passes.
        for _ in 0..<12 { window.layoutIfNeeded(); try? await Task.sleep(for: .milliseconds(40)) }
        let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 3, file: file, line: line)
    }
    @MainActor private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    @MainActor private func textInputs(in view: UIView) -> [UIView] {
        (view is UITextView || view is UITextField) ? [view] : view.subviews.flatMap { textInputs(in: $0) }
    }
}
