import Foundation

enum LSPFramingError: Error, Equatable {
    case invalidHeader
    case messageTooLarge
}

struct LSPFramer {
    private static let separator = Data([13, 10, 13, 10])
    private static let maxHeaderBytes = 16 * 1024
    private static let maxMessageBytes = 64 * 1024 * 1024
    private var buffer = Data()
    private var bodyLength: Int?

    static func frame(_ body: Data) -> Data {
        var message = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        message.append(body)
        return message
    }

    mutating func append(_ chunk: Data, receive: (Data) throws -> Void) throws {
        buffer.append(chunk)
        while true {
            if bodyLength == nil {
                guard let separator = buffer.range(of: Self.separator) else {
                    if buffer.count > Self.maxHeaderBytes { throw LSPFramingError.invalidHeader }
                    return
                }
                let header = buffer[..<separator.lowerBound]
                guard header.count <= Self.maxHeaderBytes,
                      let text = String(data: header, encoding: .ascii)
                else { throw LSPFramingError.invalidHeader }
                for line in text.components(separatedBy: "\r\n") {
                    let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2 else { throw LSPFramingError.invalidHeader }
                    if pair[0].lowercased() == "content-length" {
                        let value = pair[1].trimmingCharacters(in: .whitespaces)
                        guard bodyLength == nil, let length = Int(value), length > 0
                        else { throw LSPFramingError.invalidHeader }
                        guard length <= Self.maxMessageBytes else { throw LSPFramingError.messageTooLarge }
                        bodyLength = length
                    }
                }
                guard bodyLength != nil else { throw LSPFramingError.invalidHeader }
                buffer.removeFirst(header.count + Self.separator.count)
            }

            guard let length = bodyLength, buffer.count >= length else { return }
            let body = buffer.prefix(length)
            buffer.removeFirst(length)
            bodyLength = nil
            try receive(body)
        }
    }
}
