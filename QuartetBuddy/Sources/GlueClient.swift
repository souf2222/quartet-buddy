import Foundation

/// Client connection to ApogeeGlue (see docs/protocol-notes.md).
final class GlueClient: NSObject, StreamDelegate {

    enum State {
        case disconnected
        case connecting
        case connected
    }

    struct SetPropertyEvent {
        var id: [UInt8]
        var tag: UInt8
        var value: Data
    }

    var onState: ((State) -> Void)?
    var onTree: (([String: Any]) -> Void)?          // parsed setEntireTree
    var onSetProperty: ((SetPropertyEvent) -> Void)?
    var onRawRecord: ((GlueProtocol.ParsedRecord) -> Void)?

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var inBuffer = Data()
    private let queue = DispatchQueue(label: "quartetbuddy.glue")
    private(set) var state: State = .disconnected

    // MARK: connection

    func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setState(.connecting)
            for port in GlueProtocol.candidatePorts {
                if let (inp, out) = self.openSocket(port: port) {
                    self.inputStream = inp
                    self.outputStream = out
                    inp.delegate = self
                    out.delegate = self
                    inp.schedule(in: .main, forMode: .default)
                    out.schedule(in: .main, forMode: .default)
                    inp.open()
                    out.open()
                    self.setState(.connected)
                    // hello: getEntireTree
                    self.send(GlueProtocol.encode(VTSRecord(type: VTSType.getEntireTree.rawValue,
                                                            flag: true,
                                                            data: Data())))
                    return
                }
            }
            self.setState(.disconnected)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.inputStream?.close()
            self.outputStream?.close()
            self.inputStream = nil
            self.outputStream = nil
            self.inBuffer.removeAll()
            self.setState(.disconnected)
        }
    }

    private func openSocket(port: UInt16) -> (InputStream, OutputStream)? {
        var inp: InputStream?
        var out: OutputStream?
        Stream.getStreamsToHost(withName: "127.0.0.1", port: Int(port), inputStream: &inp, outputStream: &out)
        guard let i = inp, let o = out else { return nil }
        // probe connect timeout is handled by the OS; on failure the streams error out later
        return (i, o)
    }

    private func setState(_ s: State) {
        state = s
        DispatchQueue.main.async { [weak self] in self?.onState?(s) }
    }

    // MARK: sending

    func send(_ record: VTSRecord) {
        send(GlueProtocol.encode(record))
    }

    func send(_ payload: Data) {
        queue.async { [weak self] in
            guard let self, let out = self.outputStream else { return }
            let frame = GlueProtocol.wrapJuce(payload)
            frame.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                _ = out.write(ptr.bindMemory(to: UInt8.self).baseAddress!, maxLength: frame.count)
            }
        }
    }

    /// Send a setProperty (double) for a known path-id.
    func setDouble(id: [UInt8], _ value: Double) {
        var v = Data()
        withUnsafeBytes(of: value.bitPattern) { v.append(contentsOf: $0) }
        send(VTSRecord(type: VTSType.setProperty.rawValue, flag: false,
                      data: GlueProtocol.setPropertyData(id: id, tag: .double, value: v)))
    }

    func setBool(id: [UInt8], _ value: Bool) {
        send(VTSRecord(type: VTSType.setProperty.rawValue, flag: false,
                      data: GlueProtocol.setPropertyData(id: id, tag: .bool, value: Data([value ? 1 : 0]))))
    }

    func setInt(id: [UInt8], _ value: Int32) {
        var v = Data()
        withUnsafeBytes(of: value) { v.append(contentsOf: $0) }
        send(VTSRecord(type: VTSType.setProperty.rawValue, flag: false,
                      data: GlueProtocol.setPropertyData(id: id, tag: .int32, value: v)))
    }

    func sendCommand(_ string: String) {
        var d = Data(string.utf8)
        d.append(0)
        send(VTSRecord(type: VTSType.command.rawValue, flag: true, data: d))
    }

    // MARK: receiving

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard let inp = inputStream, inp == aStream else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            while inp.hasBytesAvailable {
                let n = inp.read(&buf, maxLength: buf.count)
                if n > 0 {
                    inBuffer.append(buf, count: n)
                } else if n == 0 {
                    break
                } else {
                    disconnect()
                    return
                }
            }
            processBuffer()
        case .endEncountered, .errorOccurred:
            disconnect()
        default:
            break
        }
    }

    private func processBuffer() {
        while true {
            let frames = GlueProtocol.unwrapJuce(inBuffer)
            guard let first = frames.first else { break }
            let consumed = 8 + first.count
            if inBuffer.count >= consumed {
                inBuffer.removeFirst(consumed)
            } else {
                inBuffer.removeAll(keepingCapacity: true)
                break
            }
            handleFrame(first)
        }
    }

    private func handleFrame(_ payload: Data) {
        guard let (record, _) = GlueProtocol.decodeOne(payload) else { return }
        onRawRecord?(record)
        switch record.type {
        case VTSType.setEntireTree.rawValue:
            if let tree = parseTree(record.data) {
                DispatchQueue.main.async { [weak self] in self?.onTree?(tree) }
            }
        case VTSType.setProperty.rawValue:
            let d = record.data
            guard d.count >= 5 else { return }
            let tag = d[d.startIndex]
            let id = Array(d.dropFirst(1).prefix(4))
            let value = Data(d.dropFirst(5))
            DispatchQueue.main.async { [weak self] in
                self?.onSetProperty?(SetPropertyEvent(id: id, tag: tag, value: value))
            }
        default:
            break
        }
    }

    private func parseTree(_ data: Data) -> [String: Any]? {
        guard let raw = JuceStreamReader.decompress(data) else { return nil }
        let reader = JuceStreamReader(raw)
        do {
            return try reader.tree()
        } catch {
            return nil
        }
    }
}

// MARK: - Tree helpers

extension GlueClient {

    static func findNode(in node: [String: Any], type: String) -> [String: Any]? {
        if node["type"] as? String == type { return node }
        for c in node["children"] as? [[String: Any]] ?? [] {
            if let r = findNode(in: c, type: type) { return r }
        }
        return nil
    }

    static func doubleProp(_ node: [String: Any]?, _ name: String) -> Double? {
        (node?["props"] as? [String: Any])?[name] as? Double
    }

    static func intProp(_ node: [String: Any]?, _ name: String) -> Int? {
        (node?["props"] as? [String: Any])?[name] as? Int
    }
}
