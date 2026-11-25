import Foundation

/// Strict incremental parser for the HTTP/1.1 response used by the Cloudflare
/// download benchmark. It counts entity bytes only, never response headers or
/// chunk framing bytes.
struct HTTPDownloadResponseParser {
    static let maximumHeaderBytes = 20_000
    static let maximumBodyBytes = 34_000_000

    private(set) var isValid = true
    private(set) var headerComplete = false
    private(set) var payloadBytes = 0
    private(set) var chunkedComplete = false

    private var headerBuffer = Data()
    // Non-chunked responses are counted as a stream and never buffered in memory.
    // Only chunked framing needs a rolling body buffer.
    private var bodyBuffer = Data()
    private var receivedBodyBytes = 0
    private var contentLength: Int?
    private var chunked = false

    var hasReceivedBody: Bool { receivedBodyBytes > 0 || !bodyBuffer.isEmpty }
    private var chunkCursor = 0
    private var chunkPayloadBytes = 0
    private var pendingChunkBytes = 0

    @discardableResult
    mutating func append(_ data: Data) -> Bool {
        guard isValid, !data.isEmpty else { return isValid }

        if !headerComplete {
            headerBuffer.append(data)
            let delimiter = Data("\r\n\r\n".utf8)
            guard let boundary = headerBuffer.range(of: delimiter) else {
                if headerBuffer.count > Self.maximumHeaderBytes { isValid = false; return false }
                return true
            }
            guard boundary.lowerBound <= Self.maximumHeaderBytes else {
                isValid = false
                return false
            }
            let rawHeaders = Data(headerBuffer[..<boundary.lowerBound])
            let remainder = Data(headerBuffer[boundary.upperBound...])
            guard parseHeaders(rawHeaders) else {
                isValid = false
                return false
            }
            headerComplete = true
            headerBuffer.removeAll(keepingCapacity: false)
            if chunked {
                bodyBuffer.append(remainder)
            } else {
                receivedBodyBytes = remainder.count
            }
        } else if chunked {
            bodyBuffer.append(data)
        } else {
            receivedBodyBytes += data.count
        }

        if chunked {
            guard bodyBuffer.count <= Self.maximumBodyBytes else {
                isValid = false
                return false
            }
            updatePayloadCount()
        } else {
            guard receivedBodyBytes <= Self.maximumBodyBytes else {
                isValid = false
                return false
            }
            payloadBytes = contentLength.map { min(receivedBodyBytes, $0) } ?? receivedBodyBytes
        }
        return isValid
    }

    /// `validateCompleteResponse` is true only when the peer closed the response.
    /// A timed benchmark stop may accept a valid partial body; a completed HTTP
    /// response must satisfy its declared framing completely.
    mutating func finish(validateCompleteResponse: Bool) -> Bool {
        guard isValid, headerComplete else { return false }
        if validateCompleteResponse {
            if let contentLength, payloadBytes < contentLength { isValid = false }
            if chunked && !chunkedComplete { isValid = false }
        }
        return isValid && payloadBytes > 0
    }

    private mutating func parseHeaders(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return false }
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        guard (200..<300).contains(status) else { return false }

        var fields: [String: [String]] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return false }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return false }
            fields[name, default: []].append(value)
        }

        let hasCloudflareRay = fields["cf-ray", default: []].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let cloudflareServer = fields["server", default: []].contains { $0.lowercased().contains("cloudflare") }
        guard hasCloudflareRay || cloudflareServer else { return false }

        let encodings = fields["content-encoding", default: []]
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        guard encodings.isEmpty || encodings.allSatisfy({ $0 == "identity" }) else { return false }

        let transferTokens = fields["transfer-encoding", default: []]
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        guard transferTokens.isEmpty || transferTokens == ["chunked"] else { return false }
        chunked = transferTokens == ["chunked"]

        let lengths = fields["content-length", default: []]
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if !lengths.isEmpty {
            var parsed: [Int] = []
            for value in lengths {
                guard !value.isEmpty, value.allSatisfy({ $0.isNumber }),
                      let length = Int(value), length >= 0,
                      length <= Self.maximumBodyBytes else { return false }
                parsed.append(length)
            }
            guard Set(parsed).count == 1 else { return false }
            contentLength = parsed[0]
        }
        guard !(chunked && contentLength != nil) else { return false }
        return true
    }

    private mutating func updatePayloadCount() {
        if chunked {
            decodeChunkedIncrementally()
            payloadBytes = chunkPayloadBytes + pendingChunkBytes
        }
    }

    /// Consume only newly completed chunks. `chunkCursor` prevents rescanning and
    /// re-copying the already parsed body on every 64 KiB Network.framework read.
    private mutating func decodeChunkedIncrementally() {
        guard !chunkedComplete, isValid else { return }
        let crlfcrlf = Data("\r\n\r\n".utf8)

        while chunkCursor < bodyBuffer.count {
            var lineEnd: Int?
            for index in chunkCursor..<bodyBuffer.count where bodyBuffer[index] == 10 {
                lineEnd = index
                break
            }
            guard let lineEnd else { return } // incomplete chunk-size line
            guard lineEnd > chunkCursor, bodyBuffer[lineEnd - 1] == 13 else {
                isValid = false
                return
            }
            let sizeData = bodyBuffer.subdata(in: chunkCursor..<(lineEnd - 1))
            let sizeText = String(decoding: sizeData, as: UTF8.self)
                .split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            let cleanSize = sizeText.trimmingCharacters(in: .whitespaces)
            guard !cleanSize.isEmpty, cleanSize.allSatisfy({ $0.isHexDigit }),
                  let rawSize = UInt64(cleanSize, radix: 16), rawSize <= UInt64(Int.max) else {
                isValid = false
                return
            }
            let size = Int(rawSize)
            let dataStart = lineEnd + 1

            if size == 0 {
                pendingChunkBytes = 0
                // Empty trailer section is just CRLF; otherwise wait for CRLFCRLF.
                if bodyBuffer.count - dataStart >= 2 && bodyBuffer[dataStart] == 13 && bodyBuffer[dataStart + 1] == 10 {
                    chunkCursor = dataStart + 2
                    chunkedComplete = true
                    return
                }
                if let trailerEnd = bodyBuffer.range(of: crlfcrlf, in: dataStart..<bodyBuffer.count) {
                    chunkCursor = trailerEnd.upperBound
                    chunkedComplete = true
                    return
                }
                return // terminal chunk arrived, but trailer section is incomplete
            }

            let remaining = bodyBuffer.count - dataStart
            guard remaining >= 2, size <= remaining - 2 else {
                pendingChunkBytes = min(size, remaining)
                return // count available payload bytes even when this chunk is incomplete
            }
            guard bodyBuffer[dataStart + size] == 13, bodyBuffer[dataStart + size + 1] == 10 else {
                isValid = false
                return
            }
            let (nextCount, overflow) = chunkPayloadBytes.addingReportingOverflow(size)
            guard !overflow else { isValid = false; return }
            chunkPayloadBytes = nextCount
            pendingChunkBytes = 0
            chunkCursor = dataStart + size + 2
        }
    }

}
