import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Deezer's preview links are signed and expire after a while, so the ones Crate saved with a batch
/// of suggestions stop playing. Deezer's public API hands out a fresh one for a track.
public struct Deezer: Sendable {
    let baseURL: URL
    let transport: HTTPTransport

    public init(baseURL: URL = URL(string: "https://api.deezer.com")!, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func previewURL(trackId: Int) async -> URL? {
        var req = URLRequest(url: baseURL.appendingPathComponent("track/\(trackId)"))
        req.timeoutInterval = 8
        struct Track: Decodable { let preview: String? }
        guard let response = try? await transport.send(req), response.1.statusCode == 200,
              let preview = (try? JSONDecoder().decode(Track.self, from: response.0))?.preview, !preview.isEmpty
        else { return nil }
        return URL(string: preview)
    }
}
