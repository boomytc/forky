import XCTest

@MainActor
final class ForkyUITests: XCTestCase {
    private var fixture: URL!
    private var home: URL!
    private var app: XCUIApplication!
    private var remoteURL: URL!
    private var peerURL: URL!

    private func prepare(rich: Bool = false, modified: Bool = true, extraFiles: Bool = false,
                         remote: Bool = false, publish: Bool = true, openRepository: Bool = true,
                         slowFetch: Bool = false) throws {
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
        if remote {
            remoteURL = directory.appendingPathComponent("server.git")
            try git(["init", "--bare", "--initial-branch=main", remoteURL.path], at: directory)
            if publish {
                try git(["remote", "add", "origin", remoteURL.path])
                try git(["push", "--set-upstream", "origin", "main"])
                peerURL = directory.appendingPathComponent("peer")
                try git(["clone", "--no-hardlinks", remoteURL.path, peerURL.path], at: directory)
                try git(["config", "user.name", "Peer UI"], at: peerURL)
                try git(["config", "user.email", "peer@example.invalid"], at: peerURL)
                try git(["config", "commit.gpgSign", "false"], at: peerURL)
                try git(["config", "core.hooksPath", "/dev/null"], at: peerURL)
                if slowFetch {
                    let wrapper = directory.appendingPathComponent("slow-upload-pack")
                    let real = URL(fileURLWithPath: try git(["--exec-path"]).trimmingCharacters(in: .newlines)).appendingPathComponent("git-upload-pack").path
                    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: real))
                    let quoted = "'" + real.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    try Data(("#!/bin/sh\n/bin/sleep 8\nexec " + quoted + " \"$@\"\n").utf8).write(to: wrapper)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
                    // Sandbox-created scripts are not executable by another app via shebang.
                    // Read this owned fixture through the system interpreter; do not change OS security settings.
                    let scriptPath = "'" + wrapper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    try git(["config", "remote.origin.uploadpack", "/bin/sh " + scriptPath])
                }
            }
        }
        app = XCUIApplication()
        app.launchEnvironment["FORKY_UI_TEST_PARENT"] = directory.path
        app.launchEnvironment["FORKY_UI_TEST_SOURCE"] = remoteURL?.path ?? fixture.path
        let application = app!
        addTeardownBlock { await MainActor.run { application.terminate() } }
        app.launchArguments = (openRepository ? ["--repository", fixture.path] : []) + ["--ui-testing"]
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

    func testFetchPullPushAndActivity() throws {
        try prepare(rich: true, modified: false, remote: true)
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["fetchRemote"], timeout: 15)
        try Data("Incoming UI change\n".utf8).write(to: peerURL.appendingPathComponent("incoming.txt"))
        try git(["add", "--", "incoming.txt"], at: peerURL)
        try git(["commit", "-m", "Incoming UI change"], at: peerURL)
        try git(["push", "origin", "main"], at: peerURL)
        app.buttons["fetchRemote"].click()
        confirmRemote()
        waitFor(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "↓1", "↓1"),
                object: app.staticTexts["trackingStatus"], timeout: 15)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("incoming.txt").path))
        app.buttons["pullRemote"].click()
        confirmRemote()
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"], timeout: 15)
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("incoming.txt"), encoding: .utf8), "Incoming UI change\n")
        try git(["commit", "--allow-empty", "-m", "Outgoing UI change"])
        app.buttons["refreshRepository"].click()
        waitFor(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "↑1", "↑1"), object: app.staticTexts["trackingStatus"])
        app.buttons["pushRemote"].click()
        confirmRemote()
        waitFor(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "↑0", "↑0"), object: app.staticTexts["trackingStatus"], timeout: 15)
        XCTAssertEqual(try git(["rev-parse", "main"], at: remoteURL), try git(["rev-parse", "HEAD"]))
        app.staticTexts["All Commits"].firstMatch.click()
        XCTAssertTrue(app.tables["commitTable"].waitForExistence(timeout: 10))
        capture("Forky — remote workflow")
        app.buttons["showActivity"].click()
        XCTAssertTrue(app.staticTexts["Fetch · origin"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Pull · origin"].exists)
        XCTAssertTrue(app.staticTexts["Push · origin"].exists)
        capture("Forky — activity")
        app.buttons["activityDone"].click()
    }

    func testAddRemoteAndFirstPublish() throws {
        try prepare(modified: false, remote: true, publish: false)
        let add = app.buttons["addRemote"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.click()
        XCTAssertTrue(app.textFields["remoteURL"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["remoteURL"].value as? String, remoteURL.path)
        confirmRemote()
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["pushRemote"])
        app.buttons["pushRemote"].click()
        XCTAssertTrue(app.textFields["pushDestination"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["pushDestination"].value as? String, "main")
        confirmRemote()
        XCTAssertTrue(app.staticTexts["trackingStatus"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(try git(["config", "branch.main.remote"]).trimmingCharacters(in: .newlines), "origin")
        XCTAssertEqual(try git(["config", "branch.main.merge"]).trimmingCharacters(in: .newlines), "refs/heads/main")
        XCTAssertEqual(try git(["rev-parse", "main"], at: remoteURL), try git(["rev-parse", "HEAD"]))
    }

    func testCloneAndOpen() throws {
        try prepare(modified: false, remote: true, openRepository: false)
        XCTAssertTrue(app.buttons["welcomeClone"].waitForExistence(timeout: 10))
        app.buttons["welcomeClone"].click()
        let field = app.textFields["cloneSource"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, remoteURL.path)
        typeUppercase("CLONED", into: app.textFields["creationName"])
        let confirm = app.windows.buttons["creationConfirm"]
        waitFor(NSPredicate(format: "enabled == true"), object: confirm)
        confirm.click()
        XCTAssertTrue(app.staticTexts["CLONED"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"])
        let clone = fixture.deletingLastPathComponent().appendingPathComponent("CLONED")
        XCTAssertEqual(try git(["rev-parse", "HEAD"], at: clone), try git(["rev-parse", "main"], at: remoteURL))
        XCTAssertTrue(app.staticTexts["trackingStatus"].exists)
    }

    func testCreateAndOpenRepository() throws {
        try prepare(modified: false, openRepository: false)
        XCTAssertTrue(app.buttons["welcomeCreate"].waitForExistence(timeout: 10))
        app.buttons["welcomeCreate"].click()
        XCTAssertTrue(app.textFields["creationName"].waitForExistence(timeout: 5))
        typeUppercase("CREATED", into: app.textFields["creationName"])
        let confirm = app.windows.buttons["creationConfirm"]
        waitFor(NSPredicate(format: "enabled == true"), object: confirm)
        confirm.click()
        XCTAssertTrue(app.staticTexts["CREATED"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let created = fixture.deletingLastPathComponent().appendingPathComponent("CREATED")
        XCTAssertEqual(try git(["symbolic-ref", "--short", "HEAD"], at: created).trimmingCharacters(in: .newlines), "main")
        XCTAssertEqual(try git(["status", "--porcelain"], at: created), "")
    }

    func testStashSavePreviewApplyAndDrop() throws {
        try prepare()
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["stashChanges"], timeout: 15)
        app.buttons["stashChanges"].click()
        let message = app.textFields["stashMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        typeUppercase("REVIEWED", into: message)
        confirmStash()
        XCTAssertTrue(app.staticTexts["Your working tree is clean."].waitForExistence(timeout: 15))
        app.staticTexts["Stashes"].firstMatch.click()
        let apply = app.buttons["applyStash"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.textViews["diffText"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews["diffText"].value as? String)?.contains("A visible change") == true)
        capture("Forky — stash preview")
        apply.click(); confirmStash()
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"])
        XCTAssertTrue(try String(contentsOf: fixture.appendingPathComponent("README.md"), encoding: .utf8).contains("A visible change"))
        XCTAssertFalse(try git(["stash", "list"]).isEmpty)
        app.buttons["dropStash"].click(); confirmStash()
        XCTAssertTrue(app.staticTexts["A safe place for unfinished work"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(try git(["stash", "list"]), "")
        XCTAssertTrue(try String(contentsOf: fixture.appendingPathComponent("README.md"), encoding: .utf8).contains("A visible change"))
    }

    func testCancelFetchStillReconcilesAndReenablesWrites() throws {
        try prepare(remote: true, slowFetch: true)
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["fetchRemote"], timeout: 15)
        app.buttons["fetchRemote"].click(); confirmRemote()
        let cancel = app.buttons["cancelOperation"]
        let hasCancel = cancel.waitForExistence(timeout: 5)
        if !hasCancel { print("FETCH FAILURE DETAILS", app.sheets.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? $0.label }) }
        XCTAssertTrue(hasCancel, app.debugDescription)
        cancel.click()
        let ok = app.windows.buttons["OK"].firstMatch
        XCTAssertTrue(ok.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Operation cancelled — review state"].firstMatch.exists, app.debugDescription)
        ok.click()
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["stage:README.md"], timeout: 15)
        XCTAssertTrue(try String(contentsOf: fixture.appendingPathComponent("README.md"), encoding: .utf8).contains("A visible change"))
        app.buttons["showActivity"].click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Cancellation completed", "Cancellation completed")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["activityDone"].click()
    }

    func testCheckoutRemoteAndCreateBranchAtSelectedCommit() throws {
        try prepare(modified: false, remote: true)
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["fetchRemote"], timeout: 15)
        try git(["switch", "-c", "feature/server"], at: peerURL)
        try git(["commit", "--allow-empty", "-m", "Server feature"], at: peerURL)
        try git(["push", "origin", "feature/server"], at: peerURL)
        app.buttons["fetchRemote"].click(); confirmRemote()
        let reference = app.staticTexts["origin/feature/server"].firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 15), app.debugDescription)
        reference.rightClick()
        app.menuItems["Checkout as Tracking Branch…"].click()
        XCTAssertTrue(app.textFields["branchName"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["branchName"].value as? String, "feature/server")
        app.windows.buttons["checkoutBranchConfirm"].click()
        waitFor(NSPredicate(format: "value == %@ OR label == %@", "feature/server", "feature/server"),
                object: app.staticTexts["currentBranch"], timeout: 15)
        XCTAssertEqual(try git(["config", "branch.feature/server.remote"]).trimmingCharacters(in: .newlines), "origin")
        XCTAssertEqual(try git(["config", "branch.feature/server.merge"]).trimmingCharacters(in: .newlines), "refs/heads/feature/server")
        app.staticTexts["All Commits"].firstMatch.click()
        let root = app.tables["commitTable"].staticTexts["Create UI fixture"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        root.click()
        let menu = app.descendants(matching: .any).matching(identifier: "commitActions").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        app.menuItems["Create Branch Here…"].click()
        XCTAssertTrue(app.textFields["branchName"].waitForExistence(timeout: 5))
        typeUppercase("HISTORIC", into: app.textFields["branchName"])
        app.windows.buttons["createBranchConfirm"].click()
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"])
        XCTAssertEqual(try git(["rev-parse", "HISTORIC"]), try git(["rev-list", "--max-parents=0", "HEAD"]))
        XCTAssertEqual(try git(["branch", "--show-current"]).trimmingCharacters(in: .newlines), "feature/server")
    }

    private func confirmRemote() {
        let button = app.windows.buttons["remoteConfirm"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        waitFor(NSPredicate(format: "enabled == true"), object: button)
        button.click()
    }

    private func confirmStash() {
        let button = app.windows.buttons["stashConfirm"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        waitFor(NSPredicate(format: "enabled == true"), object: button)
        button.click()
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

    private var gitExecutable: String {
        ProcessInfo.processInfo.environment["FORKY_TEST_GIT_EXECUTABLE"] ?? "/usr/bin/git"
    }

    @discardableResult
    private func git(_ arguments: [String], at directory: URL? = nil) throws -> String {
        let process = Process()
        // The macOS UI test runner is sandboxed; /usr/bin/git is an xcrun shim.
        // Xcode expands this scheme variable to its real Git executable.
        process.executableURL = URL(fileURLWithPath: gitExecutable)
        process.arguments = ["-C", (directory ?? fixture).path] + arguments
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
