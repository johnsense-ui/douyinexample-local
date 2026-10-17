import Foundation
import UIKit

/// 本地视频库客户端
/// - 自动在几个候选地址里探活（换网络也能连上）
/// - 分页拉 /api/videos，映射成 VideoModel
final class FeedAPI {

    static let shared = FeedAPI()

    private let savedKey = "dk.libraryBase"
    private let candidates = [
        "http://172.29.8.196:6688",
        "http://172.20.10.3:6688",
        "http://100.78.220.84:6688"
    ]

    private(set) var base: String = ""
    private var offset = 0
    private var total = Int.max
    private var loading = false

    var canLoadMore: Bool { offset < total }

    // MARK: - 找到服务器

    func resolveBase(completion: @escaping (Bool) -> Void) {
        var list: [String] = []
        if let saved = UserDefaults.standard.string(forKey: savedKey), !saved.isEmpty {
            list.append(saved)
        }
        for c in candidates where !list.contains(c) { list.append(c) }

        DispatchQueue.global(qos: .userInitiated).async {
            for candidate in list {
                if self.probe(candidate) {
                    self.base = candidate
                    UserDefaults.standard.set(candidate, forKey: self.savedKey)
                    print("[FeedAPI] 使用服务器 \(candidate)")
                    DispatchQueue.main.async { completion(true) }
                    return
                }
            }
            print("[FeedAPI] 全部候选地址都不通")
            DispatchQueue.main.async { completion(false) }
        }
    }

    private func probe(_ base: String) -> Bool {
        guard let url = URL(string: base + "/api/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        var ok = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            ok = (error == nil && code >= 200 && code < 400)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 4)
        return ok
    }

    // MARK: - 拉列表

    func loadPage(completion: @escaping ([VideoModel]) -> Void) {
        guard !loading, canLoadMore, !base.isEmpty else {
            completion([])
            return
        }
        let urlString = "\(base)/api/videos?limit=15&offset=\(offset)&sort=newest"
        guard let url = URL(string: urlString) else {
            completion([])
            return
        }

        loading = true
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }

            var models: [VideoModel] = []
            if let data = data,
               let resp = try? JSONDecoder().decode(LibraryResponse.self, from: data) {
                self.total = resp.total
                self.offset += resp.items.count
                models = resp.items.compactMap { $0.toVideoModel(base: self.base) }
            } else if let error = error {
                print("[FeedAPI] 拉取失败 \(error.localizedDescription)")
            }

            self.loading = false
            DispatchQueue.main.async { completion(models) }
        }.resume()
    }

    // MARK: - 服务端结构

    private struct LibraryResponse: Decodable {
        let total: Int
        let items: [LibraryItem]
    }

    private struct LibraryItem: Decodable {
        let id: Int
        let title: String?
        let caption: String?
        let authorName: String?
        let digg: Int?
        let width: Int?
        let height: Int?
        let duration: Double?

        func toVideoModel(base: String) -> VideoModel? {
            guard let stream = URL(string: "\(base)/api/stream/\(id)") else { return nil }
            let poster = URL(string: "\(base)/api/poster/\(id)")

            let text = (caption?.isEmpty == false ? caption! : (title ?? ""))
            let author = authorName ?? ""
            let title = author.isEmpty ? text : "\(text)   @\(author)"

            var ratio: Double?
            if let w = width, let h = height, w > 0 {
                ratio = Double(w) / Double(h)
            }

            return VideoModel(id: String(id),
                              title: title,
                              coverURL: poster,
                              videoURL: stream,
                              aspectRatio: ratio)
        }
    }
}
