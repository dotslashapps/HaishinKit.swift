import Foundation
import HaishinKit
import libsrt
import Logboard

final actor SRTSocket {
    static let payloadSize: Int = 1316

    enum Error: Swift.Error {
        case notConnected
        case illegalState(message: String)
    }

    enum Status: Int, CustomDebugStringConvertible {
        case unknown, `init`, opened, listening, connecting, connected, broken, closing, closed, nonexist

        var debugDescription: String {
            switch self {
            case .unknown: return "unknown"
            case .`init`: return "init"
            case .opened: return "opened"
            case .listening: return "listening"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .broken: return "broken"
            case .closing: return "closing"
            case .closed: return "closed"
            case .nonexist: return "nonexist"
            }
        }

        init?(_ status: SRT_SOCKSTATUS) {
            self.init(rawValue: Int(status.rawValue))
            defer { logger.trace(debugDescription) }
        }
    }

    var status: Status {
        .init(srt_getsockstate(socket)) ?? .unknown
    }

    private(set) var isRunning = false
    private var perf: CBytePerfMon = .init()
    private var socket: SRTSOCKET = SRT_INVALID_SOCK
    private var outputs: AsyncStream<Data>.Continuation?

    private var connected: Bool {
        status == .connected
    }

    private var windowSizeC: Int32 = 1024 * 4
    private lazy var incomingBuffer: Data = .init(count: Int(windowSizeC))

    init() {
        socket = srt_create_socket()
    }

    init(socket: SRTSOCKET, options: [SRTSocketOption]) async throws {
        self.socket = socket
        guard configure(options, restriction: .post) else {
            throw makeSocketError()
        }
        if incomingBuffer.count < windowSizeC {
            incomingBuffer = .init(count: Int(windowSizeC))
        }
    }

    var statusUpdates: AsyncStream<Status> {
        AsyncStream { continuation in
            Task.detached {
                while self.status != .closed {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // Check every 2 seconds
                    continuation.yield(self.status)
                }
                continuation.finish()
            }
        }
    }

    func open(_ url: SRTSocketURL) async throws {
        if socket == SRT_INVALID_SOCK {
            throw makeSocketError()
        }
        guard configure(url.options, restriction: .pre) else {
            throw makeSocketError()
        }

        let status: Int32 = try {
            switch url.mode {
            case .caller:
                guard var remote = url.remote else { return SRT_ERROR }
                var remoteaddr = remote.makeSockaddr()
                return srt_connect(socket, &remoteaddr, Int32(remote.size))
            case .listener:
                guard var local = url.local else { return SRT_ERROR }
                var localaddr = local.makeSockaddr()
                let status = srt_bind(socket, &localaddr, Int32(local.size))
                guard status != SRT_ERROR else { throw makeSocketError() }
                return srt_listen(socket, 1)
            case .rendezvous:
                guard var remote = url.remote, var local = url.local else { return SRT_ERROR }
                var remoteaddr = remote.makeSockaddr()
                var localaddr = local.makeSockaddr()
                return srt_rendezvous(socket, &remoteaddr, Int32(remote.size), &localaddr, Int32(local.size))
            }
        }()

        guard status != SRT_ERROR else {
            throw makeSocketError()
        }

        switch url.mode {
        case .listener:
            break
        default:
            guard configure(url.options, restriction: .post) else {
                throw makeSocketError()
            }
            if incomingBuffer.count < windowSizeC {
                incomingBuffer = .init(count: Int(windowSizeC))
            }
        }

        await startRunning()
    }

    func reconnect(_ uri: URL?) async {
        await stopRunning() // Clean up previous connection
        self.socket = srt_create_socket() 
    do {
        guard let srtURL = uri.flatMap(SRTSocketURL.init) else {
        throw Error.unsupportedUri(uri)
    }
    try await open(srtURL) // ✅ Now passing the correct type    } catch {
        logger.error("Reconnect failed: \(error)")
        }
    }

    func send(_ data: Data) throws {
        guard connected else {
            throw Error.notConnected
        }
        for chunk in data.chunk(Self.payloadSize) {
            outputs?.yield(chunk)
        }
    }

    private func makeSocketError() -> SRTError {
        let errorCode = srt_getlasterror(nil) // Capture actual error code
        let errorMessage = String(cString: srt_getlasterror_str())

        defer { logger.error("[SRT Error \(errorCode)]: \(errorMessage)") }

        if socket != SRT_INVALID_SOCK {
            srt_close(socket)
            socket = SRT_INVALID_SOCK
        }

        return .illegalState(message: "[\(errorCode)] \(errorMessage)")
    }

    private func configure(_ options: [SRTSocketOption], restriction: SRTSocketOption.Restriction) -> Bool {
        var failures: [String] = []
        for option in options where option.name.restriction == restriction {
            do {
                try option.setSockflag(socket)
            } catch {
                failures.append(option.name.rawValue)
            }
        }
        guard failures.isEmpty else {
            logger.error(failures)
            return false
        }
        return true
    }

    private func sendmsg(_ data: Data) -> Int32 {
        return data.withUnsafeBytes { pointer in
            guard let buffer = pointer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return SRT_ERROR
            }
            return srt_sendmsg(socket, buffer, Int32(data.count), -1, 0)
        }
    }

    private func recvmsg() -> Int32 {
        return incomingBuffer.withUnsafeMutableBytes { pointer in
            guard let buffer = pointer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return SRT_ERROR
            }
            return srt_recvmsg(socket, buffer, windowSizeC)
        }
    }
}

extension SRTSocket: AsyncRunner {
    func startRunning() async {
        guard !isRunning else { return }
        let stream = AsyncStream<Data> { continuation in
            self.outputs = continuation
        }

        Task {
            for await data in stream {
                let result = sendmsg(data)
                if result == -1 {
                    await stopRunning()
                }
            }
        }

        isRunning = true
    }

    func stopRunning() async {
        guard isRunning else { return }
        srt_close(socket)
        socket = SRT_INVALID_SOCK
        outputs = nil
        isRunning = false
    }
}
