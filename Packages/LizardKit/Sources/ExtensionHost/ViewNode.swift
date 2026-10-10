import Foundation

/// One node of an extension's rendered UI (`List.Item`, `Action`, `MenuBarExtra.Item`…).
public struct ViewNode: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public let type: String
    public let props: [String: HostJSON]
    public let children: [ViewNode]
    public let text: String?

    public init(id: Int, type: String, props: [String: HostJSON] = [:], children: [ViewNode] = [], text: String? = nil) {
        self.id = id
        self.type = type
        self.props = props
        self.children = children
        self.text = text
    }

    enum CodingKeys: String, CodingKey { case id, type, props, children, text }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        props = (try? container.decodeIfPresent([String: HostJSON].self, forKey: .props)) ?? [:]
        children = (try? container.decodeIfPresent([ViewNode].self, forKey: .children)) ?? []
        text = try? container.decodeIfPresent(String.self, forKey: .text)
    }

    public subscript(prop: String) -> HostJSON? { props[prop] }
    public func string(_ prop: String) -> String? { props[prop]?.string }
    public func bool(_ prop: String) -> Bool? { props[prop]?.bool }
    public func callback(_ prop: String) -> String? { props[prop]?.callbackID }

    /// Children of a given type, looking through sections when asked.
    public func children(ofType type: String) -> [ViewNode] { children.filter { $0.type == type } }

    /// The content of a `slot:<name>` child (actions, detail, metadata, searchBarAccessory).
    public func slot(_ name: String) -> ViewNode? {
        children.first { $0.type == "slot:\(name)" }?.children.first
    }

    /// Children that aren't slots.
    public var content: [ViewNode] { children.filter { !$0.type.hasPrefix("slot:") } }

    /// First node of `type` in this subtree (depth-first).
    public func first(_ type: String) -> ViewNode? {
        if self.type == type { return self }
        for child in children {
            if let found = child.first(type) { return found }
        }
        return nil
    }

    /// All `Action` nodes under an ActionPanel, flattened (submenus kept as nodes).
    public var flattenedActions: [ViewNode] {
        var result: [ViewNode] = []
        for child in children {
            switch child.type {
            case "Action", "ActionPanel.Submenu": result.append(child)
            case "ActionPanel.Section", "ActionPanel": result += child.flattenedActions
            default: break
            }
        }
        return result
    }
}
