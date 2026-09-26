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

    /// Returns a new ToolRegistry with the given tool registered.
    /// If a tool with the same name already exists, it is replaced.
    public func registering(_ tool: IvyTool) -> ToolRegistry {
        var map = toolsByName
        map[tool.name] = tool
        return ToolRegistry(tools: Array(map.values))
    }

    /// Returns a new ToolRegistry with the given tools registered.
    /// If tools with conflicting names exist, the newer tool takes precedence.
    public func registering(contentsOf newTools: [IvyTool]) -> ToolRegistry {
        var map = toolsByName
        for tool in newTools {
            map[tool.name] = tool
        }
        return ToolRegistry(tools: Array(map.values))
    }
}
