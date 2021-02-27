import Foundation
#if os(Linux)
import FoundationNetworking
#endif
public protocol ISentryClient {
    func capture(event: SentryEvent, scope: Scope?)
    func close()
}

enum SentryInitError: Error {
    case dsnNull
    case dsnInvalidUrl(dsn: String)
    case dsnInvalid(url: URL)
}

public struct SentryClient: ISentryClient {
    private let options: SentryOptions
    private let dsn: Dsn

    public init(options: SentryOptions) throws {
        self.options = options

        guard let dsnStr = options.dsn else {
            throw SentryInitError.dsnNull
        }
        guard let dsnUrl = URL(string: dsnStr) else {
            print("The DSN provided isn't a valid URL")
            throw SentryInitError.dsnInvalidUrl(dsn: dsnStr)
        }
        self.dsn = try Dsn(dsn: dsnUrl)
    }

    public func capture(event: SentryEvent, scope: Scope? = nil) {
        print("capturing event..")

        var preparedEvent = prepare(event: event, scope: scope)
        if let processors = scope?.eventProcessors {
            var processedEvent: SentryEvent? = preparedEvent
            for processor in processors {
                processedEvent = processor.process(event: &processedEvent!)
                if processedEvent == nil {
                    print("Processor '\(type(of: processor))' dropped the event")
                    return
                }
                preparedEvent = processedEvent!;
            }
        }
        if let beforeSend = self.options.beforeSend {
            if let beforeSendEvent = beforeSend(&preparedEvent) {
                preparedEvent = beforeSendEvent
            } else {
                print("dropped by beforeSend")
                return
            }
        }
        send(event: preparedEvent)
    }

    private func prepare(event: SentryEvent, scope: Scope?) -> SentryEvent {
        var preparedEvent = event
        if let scope = scope {
            if !scope.tags.isEmpty {
                if (preparedEvent.tags == nil) {
                    preparedEvent.tags = scope.tags
                } else {
                    for (key, value) in scope.tags {
                        if !preparedEvent.tags!.keys.contains(key) {
                            preparedEvent.tags![key] = value
                        }
                    }
                }
            }
        }
        return preparedEvent
    }

    private func send(event: SentryEvent) {
        let session = URLSession.shared
        var request = URLRequest(url: dsn.envelopeUrl)
        request.httpMethod = "POST"
        let timestamp = Int(Date().timeIntervalSince1970)
        let auth = "Sentry sentry_version=6,sentry_client=sentry.swift/0.0.1,sentry_key=\(self.dsn.publicKey),sentry_timestamp=\(timestamp)"
        print(auth)
        request.setValue(auth, forHTTPHeaderField: "X-Sentry-Auth")

        do {
            let header = try JSONSerialization.data(withJSONObject: headerPayload(event_id: event.id.uuidString), options: [])
            let payload = try JSONSerialization.data(withJSONObject: bodyPayload(event: event), options: [])
            let itemHeader = try JSONSerialization.data(withJSONObject: itemHeaderPayload(length: payload.count), options: [])
            
            var data = Data()
            data.append(header)
            data.append(Data("\n".utf8))
            data.append(itemHeader)
            data.append(Data("\n".utf8))
            data.append(payload)
            print(String(data: data, encoding: .utf8)!)
            let task = session.uploadTask(with: request, from: data) { 
                data,
                response,
                error in
                if (error != nil) {
                    print("err: \(String(describing:error))")
                }
                if let httpResponse = response as? HTTPURLResponse {
                    print(httpResponse.statusCode)
                }
#if DEBUG
                print("response: \(String(describing: response))")
#endif
            }

            task.resume()

        } catch {
            print("Failed capturing: \(error)")
        }
    }

    private func headerPayload(event_id: String) -> [String: Any] {
        return [
            "event_id": event_id
        ]
    }

    private func bodyPayload(event: SentryEvent) -> [String: Any?] {
        return [
            "message": event.message,
            "event_id": event.id.uuidString,
            "tags": event.tags
        ]
    }

    private func itemHeaderPayload(length: Int) -> [String: Any] {
        return [
            "type": "event",
            "length": length
        ]
    }

    public func close() {
        // TODO: Block while sessions open in the background:
        do {
            RunLoop.current.run(until: Date() + 2)
        }
        print("done")
    }
}

public extension ISentryClient {
    func capture(message: String, scope: Scope? = nil) {
        capture(event: SentryEvent(message: message), scope: scope)
    }
}

internal struct Dsn {
    public let envelopeUrl: URL
    public let publicKey: String

    public init(dsn: URL) throws {
        guard let publicKey = dsn.user?.components(separatedBy: [","])[0] else {
            throw SentryInitError.dsnInvalid(url: dsn)
        }
        self.publicKey = publicKey
        if let last = dsn.absoluteString.lastIndex(of: "/") {
            let project = String(dsn.absoluteString.suffix(from: dsn.absoluteString.index(last, offsetBy: 1)))

            if dsn.host != nil && dsn.scheme != nil && dsn.scheme!.starts(with: "http") {
                if let envelopeUrl = URL(string: "\(dsn.scheme!)://\(dsn.host!):\(dsn.port ?? (dsn.scheme == "https" ? 443 : 80))/api/\(project)/envelope/") {
                    self.envelopeUrl = envelopeUrl
                    return
                }
            }
        }

        throw SentryInitError.dsnInvalid(url: dsn)
    }
}
