import PassageAgentSupport
import Foundation
import Testing

@Suite("Agent skill installer")
struct AgentSkillInstallerTests {
    @Test("Each host resolves to its conventional skills directory")
    func defaultDirectories() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        #expect(AgentSkillPathResolver.defaultSkillsDirectory(for: .codex, homeDirectory: home).path == "/Users/example/.codex/skills")
        #expect(AgentSkillPathResolver.defaultSkillsDirectory(for: .claude, homeDirectory: home).path == "/Users/example/.claude/skills")
        #expect(AgentSkillPathResolver.defaultSkillsDirectory(for: .cursor, homeDirectory: home).path == "/Users/example/.cursor/skills")
    }

    @Test("Custom directories support home-relative and working-directory-relative paths")
    func customDirectoryResolution() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let working = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let homeRelative = try AgentSkillPathResolver.skillsDirectory(
            for: .codex,
            customPath: "~/agent-skills",
            homeDirectory: home,
            currentDirectory: working
        )
        let workingRelative = try AgentSkillPathResolver.skillsDirectory(
            for: .codex,
            customPath: "config/skills",
            homeDirectory: home,
            currentDirectory: working
        )

        #expect(homeRelative.path == "/Users/example/agent-skills")
        #expect(workingRelative.path == "/tmp/project/config/skills")
    }

    @Test("Packaged source discovery follows a symlinked CLI into the app bundle")
    func packagedSourceDiscovery() throws {
        let fixture = try Fixture()
        let resources = fixture.root.appendingPathComponent("Passage.app/Contents/Resources", isDirectory: true)
        let binary = resources.appendingPathComponent("bin/passage", isDirectory: false)
        let source = resources.appendingPathComponent("AgentSkill", isDirectory: true)
        try fixture.createSkill(at: source)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: binary.path, contents: Data()))

        let shim = fixture.root.appendingPathComponent("local/bin/passage", isDirectory: false)
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: binary)

        let located = try AgentSkillLocator.locate(
            executableURL: shim,
            currentDirectory: fixture.root
        )
        #expect(located.path == source.path)
    }

    @Test("Installation creates one link and repeating it is a successful no-op")
    func installIsIdempotent() throws {
        let fixture = try Fixture()
        let source = fixture.root.appendingPathComponent("bundle/AgentSkill", isDirectory: true)
        let skills = fixture.root.appendingPathComponent("home/.codex/skills", isDirectory: true)
        try fixture.createSkill(at: source)

        let first = try AgentSkillInstaller.install(host: .codex, source: source, skillsDirectory: skills)
        let second = try AgentSkillInstaller.install(host: .codex, source: source, skillsDirectory: skills)

        #expect(first.status == .installed)
        #expect(second.status == .alreadyInstalled)
        #expect(first.destination.path == skills.appendingPathComponent("passage-memory").path)
        let rawLink = try FileManager.default.destinationOfSymbolicLink(atPath: first.destination.path)
        #expect(URL(fileURLWithPath: rawLink).standardizedFileURL.path == source.standardizedFileURL.path)
    }

    @Test("An unrelated directory is preserved and reported as a conflict")
    func preservesExistingDirectory() throws {
        let fixture = try Fixture()
        let source = fixture.root.appendingPathComponent("bundle/AgentSkill", isDirectory: true)
        let destination = fixture.root.appendingPathComponent("skills/passage-memory", isDirectory: true)
        let sentinel = destination.appendingPathComponent("do-not-delete.txt")
        try fixture.createSkill(at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: sentinel.path, contents: Data("mine".utf8)))

        #expect(throws: AgentSkillInstallationError.self) {
            try AgentSkillInstaller.install(
                host: .codex,
                source: source,
                skillsDirectory: destination.deletingLastPathComponent()
            )
        }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("A foreign or dangling skill link is never replaced")
    func preservesForeignLink() throws {
        let fixture = try Fixture()
        let source = fixture.root.appendingPathComponent("bundle/AgentSkill", isDirectory: true)
        let skills = fixture.root.appendingPathComponent("skills", isDirectory: true)
        let destination = skills.appendingPathComponent("passage-memory")
        let foreignTarget = fixture.root.appendingPathComponent("missing-foreign-skill")
        try fixture.createSkill(at: source)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: foreignTarget)

        #expect(throws: AgentSkillInstallationError.self) {
            try AgentSkillInstaller.install(host: .cursor, source: source, skillsDirectory: skills)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == foreignTarget.path)
    }

    @Test("An invalid source fails before creating installation directories")
    func invalidSourceDoesNotMutateDestination() throws {
        let fixture = try Fixture()
        let source = fixture.root.appendingPathComponent("not-a-skill", isDirectory: true)
        let skills = fixture.root.appendingPathComponent("new/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        #expect(throws: AgentSkillInstallationError.self) {
            try AgentSkillInstaller.install(host: .claude, source: source, skillsDirectory: skills)
        }
        #expect(!FileManager.default.fileExists(atPath: skills.path))
    }
}

private final class Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func createSkill(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = """
            ---
            name: passage-memory
            description: Search local Passage history.
            ---

            # Passage memory
            """
        try contents.write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
