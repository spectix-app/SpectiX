import Foundation

// MARK: - Folders currently open in a VSCode-family editor
//
// A window title only carries the FOLDER NAME, never the path, so every header has
// to resolve "TaskBeacon" back to /Users/…/Projects/TaskBeacon before it can be
// keyed by cwd (see AppController.openProjectsWithoutSessions for why cwd is the
// only usable identity). ProjectHistory answers that for projects Claude has been
// run in — but a window that has never seen a session is exactly the case a
// header-only group exists for, and ProjectHistory has never heard of it.
//
// The editor itself knows. `globalStorage/storage.json` holds a `backupWorkspaces`
// block that the backup service rewrites as windows open and close, so its `folders`
// list is the set of single-folder windows open RIGHT NOW:
//
//   "backupWorkspaces": { "workspaces": [], "emptyWindows": [],
//                         "folders": [ {"folderUri": "file:///Users/you/Projects/X"} ] }
//
// ★ Read `backupWorkspaces`, not the sibling `windowsState.openedWindows`: the latter
// is a shutdown-time snapshot and goes stale while the editor runs (measured: it was
// missing a window that had been open for hours).
//
// This is only ever a NAME→PATH dictionary. Whether a window is actually open stays
// the AX scan's call (vscodeWindowCache), so a stale storage.json can't invent a
// header for an editor that already quit.
//
// Not covered, deliberately: multi-root `.code-workspace` windows (`workspaces`,
// which would need a second file read and can hold relative paths) and folderless
// windows (`emptyWindows`, which have no cwd to key on at all). Both simply don't
// produce a header, same as today.
enum EditorWorkspaces {

    // All folders open across every installed editor. Order follows EditorApp so the
    // result is stable; duplicates (the same folder open in two editors) collapse.
    static func openFolders() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for editor in EditorApp.allCases {
            for path in cached(editor) where !seen.contains(path) {
                seen.insert(path)
                out.append(path)
            }
        }
        return out
    }

    // storage.json is ~100 KB and the scan runs every 2.5s, so parse it only when the
    // editor has actually rewritten it. One stat per editor per scan is the whole cost.
    private static var cache: [EditorApp: (mtime: Date, folders: [String])] = [:]

    private static func cached(_ editor: EditorApp) -> [String] {
        let path = storageFile(editor)
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
                  as? Date else {
            cache[editor] = nil                       // editor not installed / file gone
            return []
        }
        if let hit = cache[editor], hit.mtime == mtime { return hit.folders }
        let folders = parse(path)
        cache[editor] = (mtime, folders)
        return folders
    }

    private static func storageFile(_ editor: EditorApp) -> String {
        "\(NSHomeDirectory())/Library/Application Support/\(editor.appSupportName)"
            + "/User/globalStorage/storage.json"
    }

    private static func parse(_ path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backup = root["backupWorkspaces"] as? [String: Any],
              let folders = backup["folders"] as? [[String: Any]] else { return [] }
        return folders.compactMap { entry in
            // file:// URLs are percent-encoded (a folder with a space arrives as %20),
            // so decode through URL rather than trimming the scheme off the string.
            guard let uri = entry["folderUri"] as? String,
                  let url = URL(string: uri), url.isFileURL else { return nil }
            return url.path
        }
    }
}
