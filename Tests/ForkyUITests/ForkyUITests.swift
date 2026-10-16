import XCTest

@MainActor
final class ForkyUITests: XCTestCase {
    private var fixture: URL!
    private var home: URL!
    private var app: XCUIApplication!

    private func prepare() throws {
        continueAfterFailure = false
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Forky-UI-\(UUID())")
        home = fixture.appendingPathComponent("isolated-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let directory = fixture!
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Forky UI"])
        try git(["config", "user.email", "ui@example.invalid"])
        try git(["config", "commit.gpgSign", "false"])
        try git(["config", "core.hooksPath", "/dev/null"])
        try Data("# Forky UI fixture\n".utf8).write(to: fixture.appendingPathComponent("README.md"))
        try git(["add", "--", "README.md"])
        try git(["commit", "-m", "Create UI fixture"])
        try Data("# Forky UI fixture\nA visible change\n".utf8).write(to: fixture.appendingPathComponent("README.md"))
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
        // Do not change the user\'s keyboard source or clipboard for automation.
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
