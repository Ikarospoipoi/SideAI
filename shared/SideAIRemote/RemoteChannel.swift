import Foundation

@MainActor public final class RemoteChannel: NSObject, URLSessionTaskDelegate {
  public var onMessage: ((RemoteValue) -> Void)?
  public var onReady: (() -> Void)?
  public var onPeer: (() -> Void)?
  public var onStatus: ((String, Bool) -> Void)?
  private var socket: URLSessionWebSocketTask?
  private var session: URLSession?
  private var loop: Task<Void, Never>?
  private var ping: Task<Void, Never>?
  private var outgoing: Task<Void, Never>?
  private var generation = UUID()
  private var cipher: RemoteCipher?
  public private(set) var connected = false
  public override init() { super.init() }
  nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
  public func start(_ pairing: RemotePairing, role: String) {
    stop(); let generation = self.generation
    cipher = RemoteCipher(pairing: pairing, role: role)
    loop = Task { [weak self] in
      var delay: UInt64 = 1
      while !Task.isCancelled {
        guard let self, self.generation == generation else { return }
        do {
          try pairing.validate()
          let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.timeoutIntervalForRequest = 20
          let session = URLSession(configuration: config, delegate: self, delegateQueue: nil); self.session = session
          let ws = session.webSocketTask(with: try RemotePairing.endpoint(pairing.relay)); ws.maximumMessageSize = 2_000_000; self.socket = ws
          self.onStatus?("正在连接中继…", false); ws.resume()
          let join: RemoteValue = .object(["join": .bool(true), "room": .string(pairing.room), "role": .string(role), "token": .string(pairing.relayToken(role)), "phoneHash": .string(pairing.phoneHash)])
          try await ws.send(.string(String(decoding: JSONEncoder().encode(join), as: UTF8.self)))
          self.ping = Task { [weak self] in
            while !Task.isCancelled {
              try? await Task.sleep(nanoseconds: 15_000_000_000)
              guard !Task.isCancelled, self?.generation == generation else { return }
              do { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in ws.sendPing { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } } } } catch { ws.cancel(with: .goingAway, reason: nil); return }
            }
          }
          while !Task.isCancelled {
            let message = try await ws.receive()
            guard self.generation == generation else { return }
            let text: String
            switch message { case .string(let s): text = s; case .data(let d): text = String(decoding: d, as: UTF8.self); @unknown default: continue }
            if let control = try? JSONDecoder().decode(RemoteValue.self, from: Data(text.utf8)), control["joined"].bool {
              delay = 1; self.connected = true; self.onStatus?("中继已连接，等待电脑与手机握手…", true); self.onReady?()
            } else if let control = try? JSONDecoder().decode(RemoteValue.self, from: Data(text.utf8)), control["peer"].bool {
              self.onPeer?()
            } else if let value = try? self.cipher?.open(text) { self.onMessage?(value) }
          }
        } catch { }
        guard self.generation == generation, !Task.isCancelled else { return }
        self.connected = false; self.onStatus?("连接中断，正在重连…", false)
        self.ping?.cancel(); self.socket?.cancel(with: .goingAway, reason: nil); self.session?.invalidateAndCancel()
        try? await Task.sleep(nanoseconds: delay * 1_000_000_000); delay = min(delay * 2, 15)
      }
    }
  }
  public func send(_ value: RemoteValue) {
    let previous = outgoing, generation = generation
    outgoing = Task { [weak self] in
      await previous?.value
      guard !Task.isCancelled, let self, self.generation == generation, self.connected, let ws = self.socket, let cipher = self.cipher else { return }
      do { try await ws.send(.string(cipher.seal(value))) }
      catch { ws.cancel(with: .goingAway, reason: nil) }
    }
  }
  public func stop() {
    generation = UUID(); loop?.cancel(); loop = nil; ping?.cancel(); ping = nil; outgoing?.cancel(); outgoing = nil
    socket?.cancel(with: .goingAway, reason: nil); socket = nil; session?.invalidateAndCancel(); session = nil; connected = false; cipher = nil
  }
}
