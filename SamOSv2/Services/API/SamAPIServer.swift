import Foundation
import Network

/// Lightweight HTTP server using Network.framework. No SPM dependencies.
final class SamAPIServer: @unchecked Sendable {
    private var listener: NWListener?
    private let port: UInt16
    private let handler: (APIRequest) async -> APIResponse
    private let queue = DispatchQueue(label: "com.sam.apiserver", qos: .userInitiated)
    private(set) var isRunning = false

    init(port: UInt16 = 8443, handler: @escaping (APIRequest) async -> APIResponse) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: port)!
        listener = try NWListener(using: params, on: nwPort)

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
                print("[SamAPI] Server listening on port \(self?.port ?? 0)")
            case .failed(let error):
                self?.isRunning = false
                print("[SamAPI] Server failed: \(error)")
            case .cancelled:
                self?.isRunning = false
                print("[SamAPI] Server stopped")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        accumulateHTTP(connection: connection, buffer: Data())
    }

    private static let headerTerminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n

    /// Accumulate data until we have the full HTTP request (headers + Content-Length body).
    private func accumulateHTTP(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            var accumulated = buffer
            if let data { accumulated.append(data) }

            // Find \r\n\r\n in raw bytes to split headers from body
            if let splitIndex = self.findHeaderEnd(in: accumulated) {
                let headerData = accumulated[0..<splitIndex]
                let bodyOffset = splitIndex + 4 // skip \r\n\r\n
                let bodyData = accumulated[bodyOffset...]

                let headerString = String(data: headerData, encoding: .utf8) ?? ""
                let contentLength = self.parseContentLength(headerString)

                if bodyData.count >= contentLength {
                    self.processRequest(accumulated, connection: connection)
                    return
                }
            }

            if isComplete || error != nil {
                self.processRequest(accumulated, connection: connection)
                return
            }

            self.accumulateHTTP(connection: connection, buffer: accumulated)
        }
    }

    /// Find the byte offset of \r\n\r\n in data.
    private func findHeaderEnd(in data: Data) -> Int? {
        let terminator = Self.headerTerminator
        guard data.count >= 4 else { return nil }
        for i in 0...(data.count - 4) {
            if data[i] == terminator[0] && data[i+1] == terminator[1] &&
               data[i+2] == terminator[2] && data[i+3] == terminator[3] {
                return i
            }
        }
        return nil
    }

    private func processRequest(_ data: Data, connection: NWConnection) {
        if let request = self.parseHTTPRequest(data) {
            Task {
                let response = await self.handler(request)
                let httpResponse = self.buildHTTPResponse(response)
                self.sendAndClose(httpResponse, on: connection)
            }
        } else {
            let errorResp = self.buildHTTPResponse(.error("Bad request", status: 400))
            sendAndClose(errorResp, on: connection)
        }
    }

    private func sendAndClose(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
            if let error {
                print("[SamAPI] Send error: \(error)")
            }
            // Give the kernel time to flush TCP buffers before closing
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                connection.cancel()
            }
        })
    }

    // MARK: - HTTP Parsing

    private func parseContentLength(_ headerSection: String) -> Int {
        for line in headerSection.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    private func parseHTTPRequest(_ data: Data) -> APIRequest? {
        guard let splitIndex = findHeaderEnd(in: data) else { return nil }

        let headerData = data[0..<splitIndex]
        let bodyOffset = splitIndex + 4
        let bodyData = bodyOffset < data.count ? Data(data[bodyOffset...]) : nil

        guard let headerSection = String(data: headerData, encoding: .utf8) else { return nil }
        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }

        // Parse request line: "POST /api/chat HTTP/1.1"
        let tokens = requestLine.split(separator: " ", maxSplits: 2)
        guard tokens.count >= 2 else { return nil }
        let method = String(tokens[0])
        let path = String(tokens[1])

        // Parse headers (case-preserving)
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let body: Data? = (bodyData?.isEmpty == false) ? bodyData : nil

        return APIRequest(method: method, path: path, headers: headers, body: body)
    }

    // MARK: - HTTP Response Building

    private func buildHTTPResponse(_ response: APIResponse) -> Data {
        var lines: [String] = []
        lines.append("HTTP/1.0 \(response.statusCode) \(httpStatusText(response.statusCode))")
        lines.append("Content-Type: \(response.contentType)")
        lines.append("Content-Length: \(response.body.count)")
        lines.append("Access-Control-Allow-Origin: *")
        lines.append("")

        let header = lines.joined(separator: "\r\n") + "\r\n"
        var result = header.data(using: .utf8) ?? Data()
        result.append(response.body)
        return result
    }

    private func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}
