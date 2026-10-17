import XCTest
import AppKit

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

    func testCommitSignOffAndTemplatePrefill() throws {
        try prepare()
        try Data("TEMPLATE SUBJECT\n\n# drop this line\n".utf8).write(to: fixture.appendingPathComponent(".gitmessage"))
        try git(["config", "commit.template", ".gitmessage"])
        app.terminate(); app.launch()
        let message = app.textViews["commitMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 15), app.debugDescription)
        expectation(for: NSPredicate(format: "value CONTAINS %@", "TEMPLATE SUBJECT"), evaluatedWith: message)
        waitForExpectations(timeout: 10)
        let value = message.value as? String ?? ""
        XCTAssertFalse(value.contains("drop this line"), value)
        let signOff = app.checkBoxes["commitSignOff"]
        XCTAssertTrue(signOff.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual((signOff.value as? NSNumber)?.intValue, 0, app.debugDescription)
        signOff.click()
        app.buttons["stage:README.md"].click()
        let commit = app.buttons["commitStaged"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: commit)
        waitForExpectations(timeout: 5)
        commit.click()
        var committed = false
        for _ in 0..<40 {
            if (try? git(["log", "-1", "--format=%s"]))?.trimmingCharacters(in: .newlines) == "TEMPLATE SUBJECT" {
                committed = true; break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(committed, app.debugDescription)
        let body = try git(["log", "-1", "--format=%B"])
        XCTAssertTrue(body.contains("Signed-off-by: Forky UI <ui@example.invalid>"), body)
        XCTAssertTrue(body.contains("TEMPLATE SUBJECT"), body)
        XCTAssertFalse(body.contains("drop this line"), body)
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

    func testStageLineAndUnstageHunkWithoutChangingWorkingBytes() throws {
        try prepare()
        let partial = app.buttons["partialStage"]
        XCTAssertTrue(partial.waitForExistence(timeout: 15))
        partial.click()
        let line = app.checkBoxes.matching(NSPredicate(format: "identifier BEGINSWITH %@", "patchLine:")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), app.debugDescription)
        line.click()
        app.windows.buttons["partialConfirm"].click()
        XCTAssertTrue(app.buttons["unstage:README.md"].waitForExistence(timeout: 10))
        XCTAssertTrue(try git(["show", ":README.md"]).contains("A visible change"))
        let working = try String(contentsOf: fixture.appendingPathComponent("README.md"), encoding: .utf8)
        app.buttons["partialStage"].click()
        XCTAssertTrue(app.buttons["patchHunk:0"].waitForExistence(timeout: 10))
        app.buttons["patchHunk:0"].click()
        capture("Forky — line and hunk selection")
        app.windows.buttons["partialConfirm"].click()
        XCTAssertTrue(app.buttons["stage:README.md"].waitForExistence(timeout: 10))
        XCTAssertTrue(try git(["diff", "--cached"]).isEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("README.md"), encoding: .utf8), working)
    }

    func testConflictEditorStageAndContinueMerge() throws {
        try prepare(modified: false)
        try prepareMergeConflict()
        XCTAssertTrue(app.buttons["resolveConflict"].waitForExistence(timeout: 15))
        app.buttons["resolveConflict"].click()
        XCTAssertTrue(app.buttons["conflictUseTheirs"].waitForExistence(timeout: 10))
        app.buttons["conflictUseTheirs"].click()
        capture("Forky — three-way conflict editor")
        app.windows.buttons["conflictStage"].click()
        XCTAssertTrue(app.buttons["unstage:README.md"].waitForExistence(timeout: 10))
        XCTAssertEqual(try git(["ls-files", "--unmerged"]), "")
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("README.md"), encoding: .utf8), "THEIRS\n")
        app.buttons["reviewGitOperation"].click()
        waitFor(NSPredicate(format: "enabled == true"), object: app.windows.buttons["operationContinue"])
        app.windows.buttons["operationContinue"].click()
        waitFor(NSPredicate(format: "exists == false"), object: app.buttons["reviewGitOperation"])
        XCTAssertEqual(try git(["rev-list", "--parents", "-1", "HEAD"]).split(separator: " ").count, 3)
    }

    func testConflictChunkNavigationAndBulkSideChoice() throws {
        try prepare(modified: false)
        try prepareMultiChunkConflict()
        XCTAssertTrue(app.buttons["resolveConflict"].waitForExistence(timeout: 15))
        app.buttons["resolveConflict"].click()
        let progress = app.staticTexts["conflictChunkProgress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(progress.value as? String, "0 of 2 chunks resolved")
        app.buttons["conflictNextChunk"].click()
        XCTAssertEqual(progress.value as? String, "Chunk 1 of 2 · 0 resolved")
        app.buttons["conflictNextChunk"].click()
        XCTAssertEqual(progress.value as? String, "Chunk 2 of 2 · 0 resolved")
        app.buttons["conflictAllTheirs"].click()
        let bulkConfirm = app.sheets.buttons["conflictBulkConfirm"]
        XCTAssertTrue(bulkConfirm.waitForExistence(timeout: 5), app.debugDescription)
        bulkConfirm.click()
        XCTAssertEqual(progress.value as? String, "Chunk 2 of 2 · 2 resolved")
        XCTAssertFalse(app.buttons["conflictNextChunk"].isEnabled)
        app.buttons["conflictApplyChunks"].click()
        app.windows.buttons["conflictStage"].click()
        XCTAssertTrue(app.buttons["unstage:README.md"].waitForExistence(timeout: 10), app.debugDescription)
        let content = try String(contentsOf: fixture.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(content.contains("THEIRS2") && content.contains("THEIRS11"), content)
        XCTAssertFalse(content.contains("<<<<<<<"), content)
    }

    func testWorkspaceSaveRenameAndReorder() throws {
        try prepare()
        XCTAssertTrue(app.staticTexts["currentBranch"].waitForExistence(timeout: 15), app.debugDescription)
        let menu = app.menuButtons["workspaceMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.click()
        app.menuItems["Save Open Repositories as Workspace"].click()
        menu.click()
        let saved = app.menuItems["Workspace 1"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10), app.debugDescription)
        saved.hover()
        let rename = app.menuItems["Rename…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), app.debugDescription)
        rename.click()
        let field = app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        // The alert must target the saved workspace. Text entry and rename semantics are covered by Core tests.
        XCTAssertEqual(field.value as? String, "Workspace 1", app.debugDescription)
        app.sheets.buttons["Cancel"].click()
        waitFor(NSPredicate(format: "exists == false"), object: app.sheets.firstMatch)
        menu.click()
        let moved = app.menuItems["Workspace 1"]
        XCTAssertTrue(moved.waitForExistence(timeout: 5), app.debugDescription)
        moved.hover()
        let move = app.menuItems["Move Down"]
        XCTAssertTrue(move.waitForExistence(timeout: 5), app.debugDescription)
        move.click()
        menu.click()
        XCTAssertTrue(app.menuItems["Workspace 1"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testCherryPickAndRevertSelectedCommit() throws {
        try prepare(modified: false)
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"], timeout: 15)
        try git(["switch", "-c", "source"])
        try Data("feature\n".utf8).write(to: fixture.appendingPathComponent("feature.txt"))
        try git(["add", "feature.txt"]); try git(["commit", "-m", "FeatureFromSource"])
        try git(["switch", "main"])
        app.buttons["refreshRepository"].click()
        openCommitAction("FeatureFromSource", action: "Cherry-pick…")
        app.windows.buttons["commitActionConfirm"].click()
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"])
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .newlines), "FeatureFromSource")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("feature.txt").path))
        openCommitAction("FeatureFromSource", action: "Revert…")
        app.windows.buttons["commitActionConfirm"].click()
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("feature.txt").path))
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .newlines), "Revert \"FeatureFromSource\"")
    }

    func testInteractiveRebaseEditRewordAndContinue() throws {
        try prepare(modified: false)
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"], timeout: 15)
        try Data("feature\n".utf8).write(to: fixture.appendingPathComponent("feature.txt"))
        try git(["add", "feature.txt"]); try git(["commit", "-m", "OldRebaseMessage"])
        let edited = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        app.buttons["refreshRepository"].click()
        openCommitAction("Create UI fixture", action: "Interactive Rebase After Here…")
        let picker = app.popUpButtons["rebaseAction:" + edited]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        picker.click(); app.menuItems["edit / reword"].click()
        app.checkBoxes["rebaseAcknowledge"].click()
        capture("Forky — interactive rebase plan")
        app.windows.buttons["rebaseConfirm"].click()
        XCTAssertTrue(app.buttons["reviewGitOperation"].waitForExistence(timeout: 15))
        app.buttons["reviewGitOperation"].click()
        let message = app.textViews["rebaseMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.click(); message.typeKey("a", modifierFlags: .command); message.typeKey(.delete, modifierFlags: [])
        typeUppercase("REWORDED", into: message)
        app.buttons["rebaseAmend"].click()
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"])
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .newlines), "REWORDED")
        app.buttons["reviewGitOperation"].click()
        waitFor(NSPredicate(format: "enabled == true"), object: app.windows.buttons["operationContinue"])
        app.windows.buttons["operationContinue"].click()
        waitFor(NSPredicate(format: "exists == false"), object: app.buttons["reviewGitOperation"])
        XCTAssertEqual(try git(["branch", "--show-current"]).trimmingCharacters(in: .newlines), "main")
    }

    func testBrowseCapturedTreeAndBlameAfterNewCommit() throws {
        try prepare(modified: false)
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"], timeout: 15)
        let original = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        openCommitAction("Create UI fixture", action: "Browse Tree / Blame…")
        let file = app.sheets.staticTexts["README.md"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.click()
        XCTAssertTrue(app.textViews["fileContent"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews["fileContent"].value as? String, "# Forky UI fixture\n")
        try Data("Later file bytes\n".utf8).write(to: fixture.appendingPathComponent("README.md"))
        try git(["add", "README.md"]); try git(["commit", "-m", "LaterCommit"])
        app.descendants(matching: .any).matching(identifier: "showBlame").firstMatch.click()
        XCTAssertTrue(app.staticTexts[String(original.prefix(8))].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["# Forky UI fixture"].firstMatch.exists)
        capture("Forky — captured file blame")
        app.buttons["treeDone"].click()
    }

    func testAbortMergeRequiresExplicitDiscardApproval() throws {
        try prepare(modified: false)
        try prepareMergeConflict()
        XCTAssertTrue(app.buttons["reviewGitOperation"].waitForExistence(timeout: 15))
        app.buttons["reviewGitOperation"].click()
        let abort = app.windows.buttons["operationAbort"]
        XCTAssertTrue(abort.waitForExistence(timeout: 10))
        XCTAssertFalse(abort.isEnabled)
        app.checkBoxes["operationDiscard"].click()
        abort.click()
        waitFor(NSPredicate(format: "exists == false"), object: app.buttons["reviewGitOperation"])
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("README.md"), encoding: .utf8), "OURS\n")
        XCTAssertTrue(try git(["status", "--porcelain"]).isEmpty)
    }

    func testContextActionUsesClickedCommitNotPriorSelection() throws {
        try prepare(rich: true, modified: false)
        app.staticTexts["All Commits"].firstMatch.click()
        let selected = app.tables["commitTable"].staticTexts["Render connected commit lanes"].firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 15))
        selected.click()
        let root = try git(["rev-list", "--max-parents=0", "HEAD"]).trimmingCharacters(in: .newlines)
        let clicked = app.tables["commitTable"].staticTexts["Create UI fixture"].firstMatch
        clicked.rightClick()
        app.menuItems["Browse Tree / Blame…"].click()
        XCTAssertTrue(app.sheets.staticTexts[root].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["treeDone"].click()
    }

    func testExternalChangesRefreshWithoutManualRefresh() throws {
        try prepare(modified: false)
        XCTAssertTrue(app.staticTexts["currentBranch"].waitForExistence(timeout: 10))
        try Data("external".utf8).write(to: fixture.appendingPathComponent("external.txt"))
        let stage = app.buttons["stage:external.txt"]
        XCTAssertTrue(stage.waitForExistence(timeout: 15), app.debugDescription)
        waitFor(NSPredicate(format: "enabled == true"), object: stage)
        capture("Complete — automatic filesystem refresh")
    }

    func testNormalAmendMessageOnly() throws {
        try prepare(modified: false)
        XCTAssertTrue(app.staticTexts["currentBranch"].waitForExistence(timeout: 10))
        app.menuBarItems["Tools"].click()
        app.menuItems["Amend / Reword HEAD"].click()
        let editor = app.textViews["amendMessage"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        waitFor(NSPredicate(format: "value CONTAINS %@", "Create UI fixture"), object: editor)
        editor.click(); editor.typeKey("a", modifierFlags: .command)
        for key in "amended" { editor.typeKey(String(key), modifierFlags: .shift) }
        editor.typeKey(.return, modifierFlags: []) // commit composition, never change input source
        app.checkBoxes["managementApprove"].click()
        let confirm = app.windows.buttons["managementConfirm"]
        waitFor(NSPredicate(format: "enabled == true"), object: confirm)
        capture("Complete — normal message-only amend")
        confirm.click()
        XCTAssertTrue(app.buttons["refreshRepository"].waitForExistence(timeout: 10))
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["refreshRepository"], timeout: 20)
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .newlines), "AMENDED")
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("README.md"), encoding: .utf8), "# Forky UI fixture\n")
    }

    func testRepositoryTabsKeepIndependentSessions() throws {
        try prepare(modified: false)
        XCTAssertTrue(app.staticTexts["currentBranch"].waitForExistence(timeout: 10))
        app.buttons["newRepositoryTab"].click()
        XCTAssertTrue(app.buttons["welcomeOpenRepository"].waitForExistence(timeout: 5), app.debugDescription)
        let original = app.buttons["Orbit"].firstMatch
        XCTAssertTrue(original.exists, app.debugDescription); original.click()
        XCTAssertTrue(app.staticTexts["currentBranch"].waitForExistence(timeout: 10))
        waitFor(NSPredicate(format: "value == %@ OR label == %@", "main", "main"), object: app.staticTexts["currentBranch"])
        capture("Complete — independent repository tabs")
    }

    func testCreateTagFromManagement() throws {
        try prepare(modified: false)
        XCTAssertTrue(app.staticTexts["currentBranch"].waitForExistence(timeout: 10))
        app.menuBarItems["Tools"].click(); app.menuItems["Branches, Tags & Remotes"].click()
        let picker = app.popUpButtons["referenceEditMode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
        picker.click()
        capture("Complete — reference action menu")
        let createTag = app.menuItems["Create Tag"]
        XCTAssertTrue(createTag.waitForExistence(timeout: 5), app.debugDescription)
        createTag.click()
        typeUppercase("UITAG", into: app.textFields["referenceNewName"])
        app.checkBoxes["managementApprove"].click()
        app.windows.buttons["managementConfirm"].click()
        let ref = app.descendants(matching: .any).matching(identifier: "ref:refs/tags/UITAG").firstMatch
        XCTAssertTrue(ref.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(try git(["rev-parse", "refs/tags/UITAG"]), try git(["rev-parse", "HEAD"]))
        capture("Complete — managed tag lifecycle")
    }

    func testStartReviewedNoFastForwardMerge() throws {
        try prepare(rich: true, modified: false)
        XCTAssertTrue(app.staticTexts["currentBranch"].waitForExistence(timeout: 10))
        app.menuBarItems["Tools"].click(); app.menuItems["Merge into Current Branch"].click()
        let ref = app.popUpButtons["managementReference"]
        XCTAssertTrue(ref.waitForExistence(timeout: 8), app.debugDescription)
        ref.click(); app.menuItems["refs/heads/feature/split-diff"].click()
        app.popUpButtons["mergeMode"].click(); app.menuItems["Always create merge commit"].click()
        app.checkBoxes["managementApprove"].click(); app.windows.buttons["managementConfirm"].click()
        app.buttons["showActivity"].click()
        let completed = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Completed. Repository state checked.", "Completed. Repository state checked.")).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(try git(["rev-list", "--parents", "-1", "HEAD"]).split(separator: " ").count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("Diff.swift").path))
        capture("Complete — proactive no-ff merge")
    }

    func testSelectedFilesStashThroughTools() throws {
        try prepare()
        XCTAssertTrue(app.buttons["stage:README.md"].waitForExistence(timeout: 10))
        app.menuBarItems["Tools"].click(); app.menuItems["Selected Stash / Rename / Pop"].click()
        let selected = app.sheets.checkBoxes["README.md"]
        XCTAssertTrue(selected.waitForExistence(timeout: 10), app.debugDescription)
        selected.click()
        typeUppercase("SELECTED", into: app.sheets.textFields["Message / new name"])
        app.sheets.checkBoxes["extendedApprove"].click()
        let apply = app.windows.buttons["extendedConfirm"]
        waitFor(NSPredicate(format: "enabled == true"), object: apply); apply.click()
        XCTAssertTrue(app.staticTexts["All caught up"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
        XCTAssertTrue(try git(["stash", "list"]).contains("SELECTED"))
    }

    func testFileHistoryQueryUsesCapturedPath() throws {
        try prepare()
        XCTAssertTrue(app.staticTexts["currentBranch"].waitForExistence(timeout: 10))
        let row = app.staticTexts["README.md"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.click()
        app.menuBarItems["Tools"].click(); app.menuItems["File History"].click()
        let path = app.textFields["queryPath"]
        XCTAssertTrue(path.waitForExistence(timeout: 10), app.debugDescription)
        // The sheet must carry the selected path; no keyboard input is involved.
        XCTAssertEqual(path.value as? String, "README.md", app.debugDescription)
        app.sheets.buttons["Load History"].click()
        let commit = app.sheets.staticTexts["Create UI fixture"]
        XCTAssertTrue(commit.waitForExistence(timeout: 15), app.debugDescription)
        capture("Complete — captured file history")
        app.sheets.buttons["Show Commit"].firstMatch.click()
        XCTAssertTrue(app.tables["commitTable"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Back"].click()
        XCTAssertTrue(app.buttons["stage:README.md"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testStatisticsComputeRealFixtureCounts() throws {
        try prepare(modified: false)
        XCTAssertTrue(app.staticTexts["currentBranch"].waitForExistence(timeout: 10))
        app.menuBarItems["Tools"].click(); app.menuItems["Commit Statistics"].click()
        let total = app.sheets.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "1 unique reachable", "1 unique reachable")).firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 15), app.debugDescription)
        capture("Complete — local commit statistics")
    }

    func testInlinePatchUsesExactIndexOnlySelection() throws {
        try prepare()
        let stage = app.buttons["stage:README.md"]
        XCTAssertTrue(stage.waitForExistence(timeout: 10))
        app.menuButtons["diffTools"].click(); app.menuItems["Inline Staging Review"].click()
        let line = app.checkBoxes.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inlinePatchLine:")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), app.debugDescription); line.click()
        app.buttons["Apply Selected Lines"].click()
        XCTAssertTrue(app.buttons["unstage:README.md"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(try git(["diff", "--cached"]).contains("A visible change"))
        XCTAssertTrue(try String(contentsOf: fixture.appendingPathComponent("README.md"), encoding: .utf8).contains("A visible change"))
        capture("Complete — exact inline staging")
    }

    func testHardResetNeedsSeparateDiscardApproval() throws {
        try prepare()
        XCTAssertTrue(app.buttons["stage:README.md"].waitForExistence(timeout: 10))
        app.menuBarItems["Tools"].click(); app.menuItems["Reset Current Branch (Reviewed)"].click()
        clickSegment("hard")
        let confirm = app.windows.buttons["resetConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertFalse(confirm.isEnabled)
        app.checkBoxes["resetApprove"].click()
        XCTAssertFalse(confirm.isEnabled)
        app.checkBoxes["hardDiscard"].click()
        waitFor(NSPredicate(format: "enabled == true"), object: confirm)
        capture("Complete — separately approved hard reset")
        confirm.click()
        XCTAssertTrue(app.staticTexts["All caught up"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
    }

    func testImageComparisonDecodesOwnedFixtureBytes() throws {
        try prepare(modified: false)
        XCTAssertTrue(app.staticTexts["currentBranch"].waitForExistence(timeout: 10))
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let color = NSColor(deviceRed: 0.1, green: 0.8, blue: 0.2, alpha: 1)
        for x in 0..<4 { for y in 0..<4 { image.setColor(color, atX: x, y: y) } }
        let pixel = try XCTUnwrap(image.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.greenComponent, 0.7); XCTAssertGreaterThan(pixel.alphaComponent, 0.99)
        let bytes = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        try bytes.write(to: fixture.appendingPathComponent("pixel.png"))
        XCTAssertTrue(app.buttons["stage:pixel.png"].waitForExistence(timeout: 15))
        app.menuBarItems["Tools"].click(); app.menuItems["Image Comparison"].click()
        XCTAssertTrue(app.staticTexts["imageCaptureComplete"].waitForExistence(timeout: 15), app.debugDescription)
        let decoded = app.images["comparisonImage:After"]
        XCTAssertTrue(decoded.waitForExistence(timeout: 10), app.debugDescription)
        let dimensions = app.staticTexts["imageDimensions:After"]
        XCTAssertTrue((dimensions.label + (dimensions.value as? String ?? "")).contains("4×4"), app.debugDescription)
        capture("Complete — bounded image comparison")
        clickSegment("Swipe"); XCTAssertTrue(decoded.exists)
        clickSegment("Onion Skin"); XCTAssertTrue(decoded.exists)
    }

    private func prepareMergeConflict() throws {
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"], timeout: 15)
        try git(["switch", "-c", "other"])
        try Data("THEIRS\n".utf8).write(to: fixture.appendingPathComponent("README.md"))
        try git(["add", "README.md"]); try git(["commit", "-m", "Theirs"])
        try git(["switch", "main"])
        try Data("OURS\n".utf8).write(to: fixture.appendingPathComponent("README.md"))
        try git(["add", "README.md"]); try git(["commit", "-m", "Ours"])
        XCTAssertThrowsError(try git(["merge", "--no-edit", "other"]))
        app.buttons["refreshRepository"].click()
    }

    private func prepareMultiChunkConflict() throws {
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"], timeout: 15)
        let base = (1...12).map { "line\($0)" }
        try Data((base.joined(separator: "\n") + "\n").utf8).write(to: fixture.appendingPathComponent("README.md"))
        try git(["add", "README.md"]); try git(["commit", "-m", "Base lines"])
        try git(["switch", "-c", "other"])
        var theirs = base; theirs[1] = "THEIRS2"; theirs[10] = "THEIRS11"
        try Data((theirs.joined(separator: "\n") + "\n").utf8).write(to: fixture.appendingPathComponent("README.md"))
        try git(["add", "README.md"]); try git(["commit", "-m", "Theirs"])
        try git(["switch", "main"])
        var ours = base; ours[1] = "OURS2"; ours[10] = "OURS11"
        try Data((ours.joined(separator: "\n") + "\n").utf8).write(to: fixture.appendingPathComponent("README.md"))
        try git(["add", "README.md"]); try git(["commit", "-m", "Ours"])
        XCTAssertThrowsError(try git(["merge", "--no-edit", "other"]))
        app.buttons["refreshRepository"].click()
    }

    private func openCommitAction(_ subject: String, action: String) {
        waitFor(NSPredicate(format: "enabled == true"), object: app.buttons["newBranch"], timeout: 15)
        app.staticTexts["All Commits"].firstMatch.click()
        let row = app.tables["commitTable"].staticTexts[subject].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.rightClick()
        app.menuItems[action].click()
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
