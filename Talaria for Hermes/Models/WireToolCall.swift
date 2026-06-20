import Foundation

struct WireToolCall: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let callId: String?
    let type: String?
    let function: Function

    struct Function: Codable, Hashable, Sendable {
        let name: String
        let arguments: String

        init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }

        enum CodingKeys: String, CodingKey {
            case name
            case arguments
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeLossyStringIfPresent(forKey: .name) ?? "tool"
            arguments = try container.decodeLossyJSONStringIfPresent(forKey: .arguments) ?? ""
        }
    }

    init(id: String, callId: String?, type: String?, function: Function) {
        self.id = id
        self.callId = callId
        self.type = type
        self.function = function
    }

    enum CodingKeys: String, CodingKey {
        case id
        case callId
        case type
        case function
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCallID = try container.decodeLossyStringIfPresent(forKey: .callId)
        id = try container.decodeLossyStringIfPresent(forKey: .id)
            ?? decodedCallID
            ?? "call-\(UUID().uuidString)"
        callId = decodedCallID
        type = try container.decodeLossyStringIfPresent(forKey: .type)
        function = try container.decodeIfPresent(Function.self, forKey: .function) ?? Function(name: "tool", arguments: "")
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyStringIfPresent(forKey key: Key) throws -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return string
        }
        if let int = try? decodeIfPresent(Int.self, forKey: key) {
            return String(int)
        }
        if let double = try? decodeIfPresent(Double.self, forKey: key) {
            return String(double)
        }
        if let bool = try? decodeIfPresent(Bool.self, forKey: key) {
            return String(bool)
        }
        return nil
    }

    func decodeLossyJSONStringIfPresent(forKey key: Key) throws -> String? {
        if let string = try decodeLossyStringIfPresent(forKey: key) {
            return string
        }
        guard let value = try decodeIfPresent(AnyCodable.self, forKey: key),
              !(value.value is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: value.value, options: .sortedKeys)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
