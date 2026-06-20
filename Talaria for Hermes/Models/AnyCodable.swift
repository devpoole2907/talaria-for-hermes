import Foundation

struct AnyCodable: Codable, Hashable, @unchecked Sendable {
    let value: Any

    static let null = AnyCodable(NSNull())

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map(\.value)
        } else if let object = try? container.decode([String: AnyCodable].self) {
            self.value = object.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable: unsupported value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map(AnyCodable.init))
        case let object as [String: Any]:
            try container.encode(object.mapValues(AnyCodable.init))
        default:
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: encoder.codingPath, debugDescription: "AnyCodable: unsupported value")
            )
        }
    }

    func decoded<T: Decodable>(_ type: T.Type) -> T? {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }
    var doubleValue: Double? { value as? Double }
    var boolValue: Bool? { value as? Bool }
    var arrayValue: [Any]? { value as? [Any] }
    var dictionaryValue: [String: Any]? { value as? [String: Any] }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        lhs.jsonData == rhs.jsonData
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(jsonData)
    }

    private var jsonData: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}
