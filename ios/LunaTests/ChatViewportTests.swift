import XCTest
import SwiftUI
import Vision
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

        store.messages[session.id]?.append(ChatMessage(id: "server-prompt", role: "user", content: store.runs["stream"]!.text, createdAt: 22))
        store.messages[session.id]?.append(ChatMessage(id: "server-response", role: "assistant", content: store.runs["stream"]!.output, createdAt: 23))
        store.runs["stream"]?.status = "completed"
        store.runs["stream"]?.historyReconciled = true
        await assertBottom(scroll, window: window)
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

        // A voice/API submission is not a request to leave the history being read.
        store.runs["delegated"] = AgentRun(id: "delegated", sessionID: session.id, text: "Work submitted by Luna", status: "submitting", output: "", created: 25)
        await settle(scroll, window: window)
        XCTAssertEqual(scroll.contentOffset.y, restingOffset, accuracy: 3, "A delegated run moved a scrolled-up user")

        // Returning to the bottom resumes following, without sending another prompt.
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        await settle(scroll, window: window)
        store.runs["delegated"]?.output = String(repeating: "New streamed response.\n", count: 35)
        await assertBottom(scroll, window: window)

        // The composer inset must not make a reader 120pt up count as near-bottom.
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y - 120), animated: false)
        await settle(scroll, window: window)
        let nearBottomOffset = scroll.contentOffset.y
        store.runs["delegated"]?.output += String(repeating: "More response.\n", count: 15)
        await settle(scroll, window: window)
        XCTAssertEqual(scroll.contentOffset.y, nearBottomOffset, accuracy: 3, "The composer inset incorrectly resumed following")
    }

    @MainActor func testShortConversationDoesNotOverscrollWhenSubmitting() async throws {
        let store = AppStore(loadSavedState: false)
        let session = AgentSession(id: "short", title: "Short conversation", preview: "", source: "Test", updatedAt: 1, messageCount: 0)
        try await withChat(store: store, session: session) { scroll, window in
            await self.assertBottom(scroll, window: window)
            store.runs["request"] = AgentRun(id: "request", sessionID: session.id, text: "Hello", status: "submitting", output: "", created: 2)
            await self.assertBottom(scroll, window: window)
            store.runs["request"]?.status = "running"
            store.runs["request"]?.output = "Hello back."
            await self.assertBottom(scroll, window: window)
            XCTAssertLessThan(scroll.contentSize.height, scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom)
        }
    }

    @MainActor func testActivityStaysBetweenItsPromptAndTheNextQueuedPrompt() async throws {
        let store = AppStore(loadSavedState: false)
        let session = AgentSession(id: "activity", title: "Run ordering", preview: "", source: "Test", updatedAt: 1, messageCount: 0)
        store.runs["first"] = AgentRun(id: "first", sessionID: session.id, text: "First request", status: "running", output: "", created: 2)
        store.runs["second"] = AgentRun(id: "second", sessionID: session.id, text: "Queued request", status: "queued", output: "", created: 3)
        store.activity[session.id] = [Activity(id: "tool", title: "Search", detail: "Working", finished: false, failed: false, runID: "first")]
        try await withChat(store: store, session: session) { scroll, window in
            await self.settle(scroll, window: window)
            let image = self.snapshot(window)
            let prompt = try self.textBounds(containing: "First request", in: image)
            let activity = try self.textBounds(containing: "Agent activity", in: image)
            let nextPrompt = try self.textBounds(containing: "Queued request", in: image)
            XCTAssertGreaterThan(activity.minY, prompt.maxY)
            XCTAssertLessThan(activity.maxY, nextPrompt.minY)
            let attachment = XCTAttachment(image: image); attachment.name = "Activity follows its submitted prompt"; attachment.lifetime = .keepAlways; self.add(attachment)

            store.runs.removeValue(forKey: "second")
            store.runs["first"]?.status = "waiting_for_approval"
            store.runs["first"]?.output = "Response after tool"
            store.approvals["approval"] = PendingApproval(id: "approval", runID: "first", sessionID: session.id, description: "Approve this tool")
            await self.settle(scroll, window: window)
            let approvalImage = self.snapshot(window)
            let approval = try self.textBounds(containing: "Approve this tool", in: approvalImage)
            XCTAssertGreaterThan(approval.minY, try self.textBounds(containing: "Agent activity", in: approvalImage).maxY)
            XCTAssertLessThan(approval.maxY, try self.textBounds(containing: "Response after tool", in: approvalImage).minY)
        }
    }

    @MainActor func testBottomFollowsActivityApprovalsAndComposerSizeChanges() async throws {
        let store = AppStore(loadSavedState: false)
        let session = AgentSession(id: "layout", title: "Layout changes", preview: "", source: "Test", updatedAt: 1, messageCount: 20)
        store.messages[session.id] = (0..<20).map {
            ChatMessage(id: "m-\($0)", role: "user", content: String(repeating: "History line.\n", count: 1 + $0 % 7), createdAt: Double($0))
        }
        store.runs["request"] = AgentRun(id: "request", sessionID: session.id, text: "New request", status: "running", output: "", created: 21)
        try await withChat(store: store, session: session) { scroll, window in
            await self.assertBottom(scroll, window: window)
            store.activity[session.id] = [Activity(id: "tool", title: "Search", detail: "Working", finished: false, failed: false, runID: "request")]
            await self.assertBottom(scroll, window: window)
            store.approvals["approval"] = PendingApproval(id: "approval", runID: "request", sessionID: session.id, description: String(repeating: "Approval details.\n", count: 5))
            await self.assertBottom(scroll, window: window)
            store.drafts[session.id] = String(repeating: "Draft line\n", count: 5)
            await self.assertBottom(scroll, window: window)
            let editor = try XCTUnwrap(self.textInputs(in: window).first { $0 is UITextView })
            XCTAssertTrue(editor.becomeFirstResponder())
            await self.assertBottom(scroll, window: window)
            editor.resignFirstResponder()
            await self.assertBottom(scroll, window: window)
            store.drafts[session.id] = ""
            store.approvals = [:]
            store.runs["request"]?.output = String(repeating: "Streamed paragraph.\n\n", count: 35) + "Final visible line."
            await self.assertBottom(scroll, window: window)
            let image = self.snapshot(window)
            let lastLine = try self.textBounds(containing: "Final visible line", in: image)
            let visibleBottom = scroll.convert(CGPoint(x: 0, y: scroll.bounds.maxY - scroll.adjustedContentInset.bottom), to: window).y
            XCTAssertGreaterThanOrEqual(visibleBottom - lastLine.maxY, 0)
            XCTAssertLessThan(visibleBottom - lastLine.maxY, 40, "Blank space follows the last rendered response")
            let attachment = XCTAttachment(image: image); attachment.name = "Last response above composer without overscroll"; attachment.lifetime = .keepAlways; self.add(attachment)
            store.activity = [:]
            store.runs["request"]?.status = "completed"
            await self.assertBottom(scroll, window: window)
        }
    }

    @MainActor private func snapshot(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
    }

    private func textBounds(containing text: String, in image: UIImage, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
        let observation = try XCTUnwrap(request.results?.first {
            $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(text) == true
        }, "Missing rendered text: \(text)", file: file, line: line)
        let rect = observation.boundingBox
        return CGRect(x: rect.minX * image.size.width, y: (1 - rect.maxY) * image.size.height,
                      width: rect.width * image.size.width, height: rect.height * image.size.height)
    }

    @MainActor private func withChat(store: AppStore, session: AgentSession,
                                     check: (UIScrollView, UIWindow) async throws -> Void) async throws {
        store.sessions = [session]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChatView(store: store, session: session) }.preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(400))
        let scroll = try XCTUnwrap(scrollViews(in: window).max { $0.contentSize.height < $1.contentSize.height })
        try await check(scroll, window)
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
