import Foundation

enum ToolEmojiMap {
    static func symbol(for toolName: String) -> String {
        let name = toolName.lowercased()
        if name.contains("terminal") || name.contains("ssh") || name.contains("execute") || name.contains("bash") {
            return "terminal"
        }
        if name.contains("read_file") || name.contains("write_file") || name.contains("patch") || name.contains("edit") {
            return "doc.text"
        }
        if name.contains("search_files") || name.contains("grep") || name.contains("glob") || name.contains("find") {
            return "magnifyingglass"
        }
        if name.contains("web_search") || name.contains("search") {
            return "magnifyingglass.circle"
        }
        if name.contains("browser") || name.contains("safari") || name.contains("web") {
            return "safari"
        }
        if name.contains("code") || name.contains("python") || name.contains("js") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if name.contains("file") || name.contains("dir") || name.contains("folder") {
            return "folder"
        }
        if name.contains("git") {
            return "arrow.triangle.branch"
        }
        return "wrench.and.screwdriver"
    }
}
