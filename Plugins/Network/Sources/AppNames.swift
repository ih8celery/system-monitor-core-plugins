import Darwin
import Foundation

/// Readable names for the Bandwidth list. nettop names a process by its executable, cut to 15
/// characters, so a tool whose binary is a version number shows as `2.1.296` and a long name is
/// cut short. Those two, and only those, take a name from the executable's path.
enum AppNames {
    /// nettop's name column holds this many characters at most: its own width, one short of the
    /// kernel's MAXCOMLEN (16).
    static let nettopNameLimit = 15
    private static let versionFolders: Set<String> = ["versions"]

    /// Digits and dots only, at least two numbers, like 2.1.300.
    static func looksLikeVersion(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// Whether nettop's name is worth a path lookup at all.
    static func needsPath(_ name: String) -> Bool {
        looksLikeVersion(name) || name.count >= nettopNameLimit
    }

    /// The name to show for a process nettop calls `name`, whose executable is at `path` (nil when
    /// it could not be read). Inside an app bundle, the outermost app's name; a cut name outside
    /// one, the whole file name; a version-numbered file outside one, the nearest folder above it
    /// that is neither a version nor a versions folder. Otherwise nettop's name stands.
    static func readable(_ name: String, path: String?) -> String {
        guard let path else { return name }
        let components = path.split(separator: "/").map(String.init)
        guard let file = components.last else { return name }
        let isCut = name.count >= nettopNameLimit && file.count > name.count && file.hasPrefix(name)
        let isVersion = looksLikeVersion(name) && file == name
        guard isCut || isVersion else { return name }
        if let app = components.first(where: { $0.hasSuffix(".app") && $0.count > ".app".count }) {
            return String(app.dropLast(".app".count))
        }
        if isCut { return file }
        let folder = components.dropLast().reversed().first {
            !looksLikeVersion($0) && !versionFolders.contains($0.lowercased())
        }
        return folder ?? name
    }
}

/// A process's executable path from the kernel, through libproc: no shell and no subprocess.
enum ProcessPath {
    /// PROC_PIDPATHINFO_MAXSIZE, which Swift does not import.
    private static let maximumSize = 4 * Int(MAXPATHLEN)

    /// Nil when the process has exited or belongs to a user this one may not inspect.
    static func executable(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: maximumSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
