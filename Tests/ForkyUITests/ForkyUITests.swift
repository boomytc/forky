import XCTest

@MainActor
final class ForkyUITests: XCTestCase {
    private var fixture: URL!
    private var home: URL!
    private var app: XCUIApplication!

    private func prepare(rich: Bool = false, modified: Bool = true, extraFiles: Bool = false) throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Forky-UI-\(UUID())")
        fixture = directory.appendingPathComponent("Orbit")
        home = directory.appendingPathComponent("isolated-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Forky UI"])
        try git(["config", "user.email", "ui@example.invalid"])
        try git(["config", "commit.gpgSign", "false"])
        try git(["config", "core.hooksPath", "/dev/null"])
        try Data("# Forky UI fixture\n".utf8).write(to: fixture.appendingPathComponent("README.md"))
        try git(["add", "--", "README.md"])
        try git(["commit", "-m", "Create UI fixture"])
        if rich {
            try git(["switch", "-c", "feature/sidebar"])
            try Data("struct Sidebar {}\n".utf8).write(to: fixture.appendingPathComponent("Sidebar.swift"))
            try git(["add", "--", "Sidebar.swift"]); try git(["commit", "-m", "Add sidebar interactions"])
            try git(["switch", "main"])
            try Data("struct Graph {}\n".utf8).write(to: fixture.appendingPathComponent("Graph.swift"))
            try git(["add", "--", "Graph.swift"]); try git(["commit", "-m", "Render connected commit lanes"])
            try git(["merge", "--no-ff", "feature/sidebar", "-m", "Merge feature/sidebar"])
            try git(["tag", "-a", "v0.2.0", "-m", "Native workflow milestone"])
            for subject in ["8686: improve review", "Keep selection while refreshing", "Polish branch navigation"] {
                try git(["commit", "--allow-empty", "-m", subject])
            }
            try git(["switch", "-c", "feature/split-diff"])
            try Data("let split = true\n".utf8).write(to: fixture.appendingPathComponent("Diff.swift"))
            try git(["add", "--", "Diff.swift"]); try git(["commit", "-m", "Compare changes side by side"])
            try git(["switch", "main"])
            try git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        }
        if modified {
            try Data("# Forky UI fixture\nA visible change\n".utf8).write(to: fixture.appendingPathComponent("README.md"))
        }
        if extraFiles {
            for name in ["keep-a.txt", "keep-b.txt", "leave.txt"] {
                try Data(name.utf8).write(to: fixture.appendingPathComponent(name))
            }
        }
        app = XCUIApplication()
        let application = app!
        addTeardownBlock { await MainActor.run { application.terminate() } }
        app.launchArguments = ["--repository", fixture.path, "--ui-testing"]
        app.launch()
    }

    func testOpenDiffStageAndCommit() throws {
        try prepare()
        let stage = app.buttons["stage:README.md"]
        XCTAssertTrue(stage.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.textViews["diffText"].waitForExistence(timeout: 10))
        stage.click()
        let unstage = app.buttons["unstage:README.md"]
        XCTAssertTrue(unstage.waitForExistence(timeout: 10))
        let message = app.textViews["commitMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.click()
        // A literal ASCII token avoids input-source-specific space conversion.
        message.typeText("FORKYUITEST")
        // Finish marked-text composition before checking the SwiftUI binding.
        // Do not change the user's keyboard source or clipboard for automation.
        message.typeKey(.return, modifierFlags: [])
        XCTAssertEqual((message.value as? String)?.trimmingCharacters(in: .newlines), "FORKYUITEST", app.debugDescription)
        let commit = app.buttons["commitStaged"]
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: commit)
        waitForExpectations(timeout: 5)
        commit.click()
        let clean = app.staticTexts["Your working tree is clean."]
        XCTAssertTrue(clean.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .newlines), "FORKYUITEST")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Forky — clean after commit"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHistoryAndUnstage() throws {
        try prepare()
        let stage = app.buttons["stage:README.md"]
        XCTAssertTrue(stage.waitForExistence(timeout: 15))
        stage.click()
        let unstage = app.buttons["unstage:README.md"]
        XCTAssertTrue(unstage.waitForExistence(timeout: 10))
        unstage.click()
        XCTAssertTrue(stage.waitForExistence(timeout: 10))
        app.staticTexts["All Commits"].firstMatch.click()
        XCTAssertTrue(app.tables["commitTable"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Create UI fixture"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["diffText"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Forky — native commit history"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testGraphTagsSearchAndSplitDiff() throws {
        try prepare(rich: true)
        XCTAssertTrue(app.textViews["diffText"].waitForExistence(timeout: 15))
        clickSegment("Split")
        let newText = app.textViews["diffTextNew"]
        XCTAssertTrue(newText.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue((newText.value as? String)?.contains("+A visible change") == true)
        XCTAssertFalse((app.textViews["diffText"].value as? String)?.contains("+A visible change") == true)
        capture("Forky — split diff")
        app.staticTexts["All Commits"].firstMatch.click()
        let table = app.tables["commitTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let merge = table.staticTexts["Merge feature/sidebar"].firstMatch
        XCTAssertTrue(merge.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(table.staticTexts["◇ v0.2.0"].firstMatch.exists, app.debugDescription)
        merge.click()
        clickSegment("Commit")
        XCTAssertTrue(app.scrollViews["commitSummary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Changes are compared with the first parent."].exists)
        capture("Forky — graph and commit summary")
        clickSegment("Changes")
        let search = app.textFields["historySearch"]
        search.click(); search.typeText("8686"); search.typeKey(.return, modifierFlags: [])
        let root = table.staticTexts["Create UI fixture"].firstMatch
        waitFor(NSPredicate(format: "exists == false"), object: root)
        XCTAssertEqual(search.value as? String, "8686")
        XCTAssertTrue(table.staticTexts["8686: improve review"].firstMatch.exists, app.debugDescription)
        XCTAssertEqual(table.tableRows.count, 1)
        app.buttons["historySearch:clear"].click()
        XCTAssertTrue(root.waitForExistence(timeout: 10))
    }

    func testAlphabeticSearchDoesNotInvokeBranchCommands() throws {
        try prepare(rich: true)
        XCTAssertTrue(app.buttons["stage:README.md"].waitForExistence(timeout: 15))
        app.staticTexts["All Commits"].firstMatch.click()
        let search = app.textFields["historySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        typeUppercase("CREATE", into: search)
        XCTAssertFalse(app.textFields["branchName"].exists, app.debugDescription)
        XCTAssertEqual(search.value as? String, "CREATE", app.debugDescription)
        let table = app.tables["commitTable"]
        waitFor(NSPredicate(format: "exists == false"), object: table.staticTexts["Merge feature/sidebar"].firstMatch)
        XCTAssertTrue(table.staticTexts["Create UI fixture"].firstMatch.exists)
        XCTAssertEqual(table.tableRows.count, 1)
        app.buttons["historySearch:clear"].click()
        typeUppercase("NEEDLE", into: search)
        XCTAssertFalse(app.textFields["branchName"].exists, app.debugDescription)
        XCTAssertEqual(search.value as? String, "NEEDLE", app.debugDescription)
        XCTAssertTrue(app.staticTexts["No matching commits"].waitForExistence(timeout: 10))
    }

    func testCreateAndCheckoutBranch() throws {
        try prepare(modified: false)
        XCTAssertTrue(app.buttons["newBranch"].waitForExistence(timeout: 15))
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"])
        app.buttons["newBranch"].click()
        let field = app.textFields["branchName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        typeUppercase("UIFEATURE", into: field)
        XCTAssertEqual(field.value as? String, "UIFEATURE")
        let create = app.windows.buttons["createBranchConfirm"]
        waitFor(NSPredicate(format: "enabled == true"), object: create)
        create.click()
        let branch = app.staticTexts["UIFEATURE"].firstMatch
        XCTAssertTrue(branch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(try git(["branch", "--show-current"]).trimmingCharacters(in: .newlines), "main")
        branch.rightClick()
        app.menuItems["Checkout Branch…"].click()
        let checkout = app.windows.buttons["checkoutBranchConfirm"]
        XCTAssertTrue(checkout.waitForExistence(timeout: 5))
        waitFor(NSPredicate(format: "enabled == true"), object: checkout)
        checkout.click()
        waitFor(NSPredicate(format: "value == %@ OR label == %@", "UIFEATURE", "UIFEATURE"),
                object: app.staticTexts["currentBranch"])
        XCTAssertEqual(try git(["branch", "--show-current"]).trimmingCharacters(in: .newlines), "UIFEATURE")
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
    }

    func testBatchStagingHonorsFileFilter() throws {
        try prepare(extraFiles: true)
        XCTAssertTrue(app.buttons["stage:README.md"].waitForExistence(timeout: 15))
        let filter = app.textFields["fileFilter"]
        typeUppercase("KEEP", into: filter)
        XCTAssertEqual(filter.value as? String, "KEEP")
        XCTAssertTrue(app.buttons["stage:keep-a.txt"].waitForExistence(timeout: 8))
        waitFor(NSPredicate(format: "exists == false"), object: app.buttons["stage:README.md"])
        app.buttons["stageAll"].click()
        confirmBatch("Stage 2 Files")
        XCTAssertTrue(app.buttons["unstage:keep-a.txt"].waitForExistence(timeout: 10), app.debugDescription)
        let paths = try git(["diff", "--cached", "--name-only", "-z"]).split(separator: "\0").map(String.init)
        XCTAssertEqual(Set(paths), Set(["keep-a.txt", "keep-b.txt"]))
        app.buttons["unstageAll"].click()
        confirmBatch("Unstage 2 Files")
        XCTAssertTrue(app.buttons["stage:keep-a.txt"].waitForExistence(timeout: 10))
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "")
        app.buttons["fileFilter:clear"].click()
        XCTAssertTrue(app.buttons["stage:README.md"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["stage:leave.txt"].exists)
        for name in ["keep-a.txt", "keep-b.txt", "leave.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.appendingPathComponent(name).path))
        }
    }

    private func waitFor(_ predicate: NSPredicate, object: Any, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, app.debugDescription, file: file, line: line)
    }

    private func typeUppercase(_ value: String, into element: XCUIElement) {
        element.click()
        // Explicit Shift, never Command: avoid typeText's input-source translation.
        for key in value.lowercased() { element.typeKey(String(key), modifierFlags: .shift) }
        element.typeKey(.return, modifierFlags: [])
    }

    private func clickSegment(_ title: String) {
        let radio = app.radioButtons[title].firstMatch
        if radio.exists { radio.click() } else { app.buttons[title].firstMatch.click() }
    }

    private func confirmBatch(_ title: String) {
        // Scope native alerts to windows: Touch Bar mirrors are not clickable.
        let button = app.windows.buttons[title].firstMatch
        if button.waitForExistence(timeout: 2) { button.click() }
        else {
            let item = app.menuItems[title].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
            item.click()
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let process = Process()
        // The macOS UI test runner is sandboxed; /usr/bin/git is an xcrun shim.
        // Xcode expands this scheme variable to its real Git executable.
        let gitPath = ProcessInfo.processInfo.environment["FORKY_TEST_GIT_EXECUTABLE"] ?? "/usr/bin/git"
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", fixture.path] + arguments
        process.environment = ["HOME": home.path, "XDG_CONFIG_HOME": home.path, "PATH": "/usr/bin:/bin", "GIT_TERMINAL_PROMPT": "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ForkyUIFixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
