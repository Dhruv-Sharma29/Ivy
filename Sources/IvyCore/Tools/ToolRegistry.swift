import Foundation

/// Registry of available Ivy tools.
/// Manages tool registration and exports declarations for Gemini requests.
public final class ToolRegistry: Sendable {
    private let toolsByName: [String: IvyTool]

    public init(tools: [IvyTool] = []) {
        var map: [String: IvyTool] = [:]
        for tool in tools {
            map[tool.name] = tool
        }
        self.toolsByName = map
    }

    /// Looks up a registered tool by its function name.
    public func tool(named name: String) -> IvyTool? {
        toolsByName[name]
    }

    /// All registered tools.
    public var allTools: [IvyTool] {
        Array(toolsByName.values)
    }

    /// Gemini tool declarations wrapping all registered tools.
    public var toolDeclarations: [ToolDeclarationWrapper] {
        let decls = toolsByName.values.map(\.declaration).sorted { $0.name < $1.name }
        guard !decls.isEmpty else { return [] }
        return [ToolDeclarationWrapper(functionDeclarations: decls)]
    }

    /// Creates a standard registry configured with default Phase 2A tools.
    public static func defaultRegistry(workspace: WorkspaceProtocol = SystemWorkspace()) -> ToolRegistry {
        ToolRegistry(tools: [
            OpenAppTool(workspace: workspace)
        ])
    }
}
