import Foundation
import Network

/// Communicates with Pi coding agent instances.
///
/// Two-way bridge:
/// - Outbound: Writes transcribed text to Pi's inbox directory
/// - Inbound: Runs a TCP broker (port 18081) to receive speak commands
///   from the pi-talk extension (Loqui-compatible protocol)
final class PiBridge {
    
    /// Called when a speak command is received from pi-talk extension.
    var onSpeakRequest: ((SpeakRequest) -> Void)?
    
    /// Called when a stop command is received.
    var onStopRequest: (() -> Void)?
    
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "magpi.bridge")
    
    struct SpeakRequest {
        let text: String
        let voice: String?
        let sourceApp: String?
        let sessionId: String?
        let pid: Int?
    }
    
    init() {}
    
    deinit {
        stopBroker()
    }
    
    // MARK: - Outbound: Send text to Pi
    
    /// Send transcribed text to the most recent Pi session's inbox.
    func sendToPi(text: String) {
        let inboxBase = Constants.piInboxBase
        
        // Find the most recently modified Pi inbox directory
        guard let targetDir = findMostRecentPiInbox(at: inboxBase) else {
            print("Magpi: No Pi inbox found at \(inboxBase.path)")
            return
        }
        
        // Write message file
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "\(timestamp).json"
        let filePath = targetDir.appendingPathComponent(filename)
        
        let message: [String: Any] = [
            "text": text,
            "source": "magpi",
            "timestamp": timestamp,
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            try data.write(to: filePath)
            print("Magpi: Sent to Pi inbox: \(targetDir.lastPathComponent)/\(filename)")
        } catch {
            print("Magpi: Failed to write to Pi inbox: \(error)")
        }
    }
    
    private func findMostRecentPiInbox(at baseDir: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        
        // Each subdirectory is a PID — find the most recently modified one
        // that corresponds to a running process
        let pidDirs = entries
            .filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            .compactMap { url -> (url: URL, date: Date)? in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let date = attrs[.modificationDate] as? Date else { return nil }
                
                // Verify the process is still running
                if let pid = Int32(url.lastPathComponent) {
                    if kill(pid, 0) != 0 && errno == ESRCH {
                        return nil  // Process doesn't exist
                    }
                }
                
                return (url, date)
            }
            .sorted { $0.date > $1.date }
        
        return pidDirs.first?.url
    }
    
    // MARK: - Inbound: Broker (Loqui-compatible)
    
    /// Start the TCP broker on port 18081.
    func startBroker() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        
        let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: UInt16(Constants.brokerPort)))
        
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Magpi: Broker listening on \(Constants.brokerHost):\(Constants.brokerPort)")
            case .failed(let error):
                print("Magpi: Broker failed: \(error)")
            default:
                break
            }
        }
        
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleBrokerConnection(connection)
        }
        
        listener.start(queue: queue)
        self.listener = listener
    }
    
    /// Stop the broker.
    func stopBroker() {
        listener?.cancel()
        listener = nil
    }
    
    private func handleBrokerConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        
        // Read one NDJSON message
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data else {
                connection.cancel()
                return
            }
            
            let response = self.processBrokerMessage(data)
            
            // Send response
            let responseData = (response + "\n").data(using: .utf8) ?? Data()
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
    
    private func processBrokerMessage(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["type"] as? String else {
            return #"{"ok":false,"error":"invalid request"}"#
        }
        
        switch type {
        case "health":
            return #"{"ok":true}"#
            
        case "speak":
            guard let speakText = json["text"] as? String, !speakText.isEmpty else {
                return #"{"ok":false,"error":"missing text"}"#
            }
            
            let request = SpeakRequest(
                text: speakText,
                voice: json["voice"] as? String,
                sourceApp: json["sourceApp"] as? String,
                sessionId: json["sessionId"] as? String,
                pid: json["pid"] as? Int
            )
            
            DispatchQueue.main.async { [weak self] in
                self?.onSpeakRequest?(request)
            }
            
            return #"{"ok":true,"queued":1}"#
            
        case "stop":
            DispatchQueue.main.async { [weak self] in
                self?.onStopRequest?()
            }
            return #"{"ok":true}"#
            
        default:
            return #"{"ok":false,"error":"unknown command: \#(type)"}"#
        }
    }
}
