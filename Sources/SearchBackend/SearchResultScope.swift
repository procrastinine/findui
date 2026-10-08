import Foundation

/// A durable NUL-separated file list, produced from the entire result store.
/// The compiler consumes it as a candidate source in both CLI and GUI searches.
package struct SearchResultScope: Codable, Hashable, Sendable {
    package var path: String
    package var name: String
    package var count: Int
    /// Command searches can select paths outside their working directory. A
    /// captured list then uses / as its admission root, while this remembers
    /// the folder to restore when the user leaves the saved list.
    package var previousFolderPath: String? = nil
    package func source() throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"), FileManager.default.isReadableFile(atPath: path) else {
            throw SearchServiceError.commandFailed("The saved result list is unavailable: \(path). Choose a folder or restore the list.")
        }
        return SearchPipelineCompiler.command("/bin/cat", [path])
    }
    package init(path: String, name: String, count: Int) {
        self.path = path
        self.name = name
        self.count = count
    }

}

extension SearchState {
    package func searchingResults(_ scope: SearchResultScope) -> SearchState {
        var state = self
        var scope = scope
        if nativeCommand != nil {
            scope.previousFolderPath = scopePath
            state.nativeCommand = nil; state.sourceCommand = nil
            state.mode = .everything; state.query = ""; state.syntax = .literal
            state.indexedFilter = .everything
            // Only paths in the durable manifest are candidates. Broad
            // admission preserves dotfiles, ignored files and other roots
            // selected by the original command without walking the disk.
            state.scopePath = "/"; state.refinements.additionalScopes = []
            state.includeHidden = true
            state.traversal = .init(excludedFolders: [])
            state.traversal.includeIgnored = true
            state.traversal.followSymlinks = true
            state.traversal.minimumDepth = 0
        } else if let previous = resultScope?.previousFolderPath {
            scope.previousFolderPath = previous
        }
        state.resultScope = scope; state.useIndex = false; state.refinements.source = .filesystem
        return state
    }

    package func clearingResultScope() -> SearchState {
        var state = self
        if let previous = resultScope?.previousFolderPath { state.scopePath = previous }
        state.resultScope = nil
        state.traversal.minimumDepth = max(1, state.traversal.minimumDepth)
        if let maximum = state.traversal.maximumDepth, maximum < state.traversal.minimumDepth {
            state.traversal.maximumDepth = state.traversal.minimumDepth
        }
        return state
    }
}
