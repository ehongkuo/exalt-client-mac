import CryptoKit
import Foundation

extension GuardPaths {
    static func dylib(forApp bundle: URL) -> URL { resources(forApp: bundle).appendingPathComponent("ExaltGuard.dylib") }
    /// SHA-256 of the GameAssembly build the guard was checked against.
    static func buildHashFile(forApp bundle: URL) -> URL { resources(forApp: bundle).appendingPathComponent("game-build.sha256") }
}

/// Where DECA installs the launcher and the game.
struct GameInstall: Equatable {
    var launcher: URL
    var gameAssembly: URL

    static func standard(home: URL) -> GameInstall {
        GameInstall(
            launcher: URL(fileURLWithPath: "/Applications/RotMG Exalt Launcher/RotMG Exalt Launcher.app/Contents/MacOS/RotMG Exalt Launcher"),
            gameAssembly: home.appendingPathComponent(".local/share/RealmOfTheMadGod/Production/RotMGExalt.app/Contents/Frameworks/GameAssembly.dylib"))
    }
}

enum LaunchProblem: Error, Equatable {
    case launcherMissing, gameMissing, guardMissing, buildUnknown, gameUpdated, gameRunning, launcherRunning

    var message: String {
        switch self {
        case .launcherMissing: return "DECA's launcher was not found in /Applications."
        case .gameMissing: return "The game is not installed where the launcher puts it. Open DECA's launcher once to install it."
        case .guardMissing: return "The guard is missing from the app. Reinstall Exalt Client Mac."
        case .buildUnknown: return "The app is missing its game-build record, so the game cannot be checked. Reinstall Exalt Client Mac."
        case .gameUpdated: return "Exalt was updated since the guard was checked. The guard stays off until the new build is inspected."
        case .gameRunning: return "The game is already running. Quit it first; the guard can only start with a fresh launch."
        case .launcherRunning: return "DECA's launcher is already open. Quit it first so it starts with the guard."
        }
    }
}

/// How to start DECA's launcher with the guard, for this launch only.
struct LaunchPlan: Equatable {
    var executable: URL
    var environment: [String: String]

    static let gameProcess = "RotMGExalt"
    static let launcherProcess = "RotMG Exalt Launcher"

    /// Checks everything in order (cheap checks first). `actualHash` may be nil only if an
    /// earlier check fails; callers hash the 84 MB file after the cheap checks pass.
    static func make(install: GameInstall, dylib: URL, data: URL, settings: GuardSettings, expectedHash: String?,
                     actualHash: String?, running: [String], exists: (URL) -> Bool) -> Result<LaunchPlan, LaunchProblem> {
        if !exists(install.launcher) { return .failure(.launcherMissing) }
        if !exists(install.gameAssembly) { return .failure(.gameMissing) }
        if !exists(dylib) { return .failure(.guardMissing) }
        if running.contains(gameProcess) { return .failure(.gameRunning) }
        if running.contains(launcherProcess) { return .failure(.launcherRunning) }
        guard let expectedHash else { return .failure(.buildUnknown) }
        if actualHash != expectedHash { return .failure(.gameUpdated) }
        return .success(LaunchPlan(executable: install.launcher,
                                   environment: ["EXALT_GUARD": settings.text, "DYLD_INSERT_LIBRARIES": dylib.path,
                                                 "EXALT_GUARD_DIR": data.path]))
    }
}

enum FileHash {
    /// Lowercase hex SHA-256, read in 4 MB chunks.
    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func expected(from text: String) -> String? {
        let value = text.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
        return value?.isEmpty == false ? value : nil
    }
}

/// Starts the launcher detached; it and the game keep running if this app quits.
enum GameLauncher {
    static func start(_ plan: LaunchPlan) throws {
        let process = Process()
        process.executableURL = plan.executable
        process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
