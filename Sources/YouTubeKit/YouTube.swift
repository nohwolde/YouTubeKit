//
//  YouTube.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 04.09.21.
//

import Foundation
@preconcurrency import os.log

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
public class YouTube {
    
    private var _js: String?
    private var _jsURL: URL?
    
#if swift(>=5.10)
    nonisolated(unsafe) private static var __js: String? // caches js between calls
    nonisolated(unsafe) private static var __jsURL: URL?
    nonisolated(unsafe) private static var __iframePlayerURL: URL?
    nonisolated(unsafe) private static var __iframePlayerURLFetchedAt: Date?
#else
    private static var __js: String? // caches js between calls
    private static var __jsURL: URL?
    private static var __iframePlayerURL: URL?
    private static var __iframePlayerURLFetchedAt: Date?
#endif
#if swift(>=5.10)
    nonisolated(unsafe) private static var __ytcfg: Extraction.YtCfg?
    nonisolated(unsafe) private static var __ytcfgFetchedAt: Date?
#else
    private static var __ytcfg: Extraction.YtCfg?
    private static var __ytcfgFetchedAt: Date?
#endif
    private static let ytcfgLock = NSLock()
    /// ytcfg holds session-scoped values (visitorData, userAgent) — NOT per-video ones —
    /// so it can be fetched once and reused instead of costing a ~610 KB watch-page
    /// download per track.
    private static let ytcfgTTL: TimeInterval = 60 * 60

    private static let iframePlayerURLLock = NSLock()
    /// base.js is swapped roughly weekly; an hour is well inside that and any staleness
    /// is self-healing (a stale player fails the solve, which clears the JS cache and retries).
    private static let iframePlayerURLTTL: TimeInterval = 60 * 60
    
    private var _videoInfos: [InnerTube.VideoInfo]?
    
    private var _watchHTML: String?
    private var _embedHTML: String?
    private var playerConfigArgs: [String: Any]?
    private var _ageRestricted: Bool?
    private var _signatureTimestamp: Int?
    private var _ytcfg: Extraction.YtCfg?
    
    private var _fmtStreams: [Stream]?
    
    private var initialData: Data?

    /// Represents a property that provides metadata for a YouTube video.
    ///
    /// This property allows you to retrieve metadata for a YouTube video asynchronously.
    /// - Note: Currently doesn't respect `method` set. It always uses `.local`
    public var metadata: YouTubeMetadata? {
        get async throws {
            return .metadata(from: try await videoDetails)
        }
    }

    public let videoID: String
    
    var watchURL: URL {
        URL(string: "https://youtube.com/watch?v=\(videoID)")!
    }
    
    private var extendedWatchURL: URL {
        URL(string: "https://youtube.com/watch?v=\(videoID)&bpctr=9999999999&has_verified=1")!
    }
    
    var embedURL: URL {
        URL(string: "https://www.youtube.com/embed/\(videoID)")!
    }
    
    // stream monostate TODO
    
    private var author: String?
    private var title: String?
    private var publishDate: String?
    
    let useOAuth: Bool
    let allowOAuthCache: Bool
    
    let methods: [ExtractionMethod]
    
    private let log = OSLog(YouTube.self)
    
    /// - parameter methods: Methods used to extract streams from the video - ordered by priority (Default: `local` on iOS, macOS, tvOS, visionOS; `remote` on watchOS)
    public init(videoID: String, proxies: [String: URL] = [:], useOAuth: Bool = false, allowOAuthCache: Bool = false, methods: [ExtractionMethod] = .default) {
        self.videoID = videoID
        self.useOAuth = useOAuth
        self.allowOAuthCache = allowOAuthCache
        // TODO: install proxies if needed
        
        if methods.isEmpty {
#if canImport(JavaScriptCore)
            self.methods = [.local]
#else
            self.methods = [.remote]
#endif
        } else {
            self.methods = methods.removeDuplicates()
        }
    }
    
    /// - parameter methods: Methods used to extract streams from the video - ordered by priority (Default: `local` on iOS, macOS, tvOS, visionOS; `remote` on watchOS)
    public convenience init(url: URL, proxies: [String: URL] = [:], useOAuth: Bool = false, allowOAuthCache: Bool = false, methods: [ExtractionMethod] = .default) {
        let videoID = Extraction.extractVideoID(from: url.absoluteString) ?? ""
        self.init(videoID: videoID, proxies: proxies, useOAuth: useOAuth, allowOAuthCache: allowOAuthCache, methods: methods)
    }
    
    
    private var watchHTML: String {
        get async throws {
            if let cached = _watchHTML {
                return cached
            }
            var request = URLRequest(url: extendedWatchURL)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en", forHTTPHeaderField: "accept-language")
            request.httpShouldHandleCookies = false
            let (data, _) = try await URLSession.shared.data(for: request)
            _watchHTML = String(data: data, encoding: .utf8) ?? ""
            return _watchHTML!
        }
    }
    
    private var embedHTML: String {
        get async throws {
            if let cached = _embedHTML {
                return cached
            }
            var request = URLRequest(url: embedURL)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en", forHTTPHeaderField: "accept-language")
            request.httpShouldHandleCookies = false
            let (data, _) = try await URLSession.shared.data(for: request)
            _embedHTML = String(data: data, encoding: .utf8) ?? ""
            return _embedHTML!
        }
    }
    
    
    /// Playability as reported by InnerTube (`/player`), mapped onto the same shape the
    /// watch-page extractor returns. `nil` means InnerTube told us nothing useful and the
    /// caller should fall back.
    private func innerTubePlayabilityStatus() async throws -> (Extraction.InitialPlayerResponse.PlayabilityStatus.Status?, [String?])? {
        guard let infos = try? await videoInfos else { return nil }
        // Any client reporting OK means it's playable; only report a problem if we have one.
        let statuses = infos.compactMap { $0.playabilityStatus }
        guard !statuses.isEmpty else { return nil }
        if statuses.contains(where: { $0.status?.uppercased() == "OK" }) {
            return (.ok, [nil])
        }
        guard let first = statuses.first,
              let raw = first.status?.uppercased(),
              let mapped = Extraction.InitialPlayerResponse.PlayabilityStatus.Status(rawValue: raw) else {
            return nil
        }
        return (mapped, [first.reason])
    }

    /// check whether the video is available
    public func checkAvailability() async throws {
        // Prefer InnerTube's playabilityStatus over the watch page. It is the same
        // information from the same source YouTube's own clients use, and we fetch the
        // /player response anyway — whereas parsing it out of the watch page costs a
        // ~610 KB download PER TRACK (the dominant cost of a resolve on a phone).
        // Falls back to the watch page if InnerTube gives us nothing to judge by.
        let status: Extraction.InitialPlayerResponse.PlayabilityStatus.Status?
        let messages: [String?]
        if let fromInnerTube = try await innerTubePlayabilityStatus() {
            (status, messages) = fromInnerTube
        } else {
            (status, messages) = try Extraction.playabilityStatus(watchHTML: await watchHTML)
        }

        for reason in messages {
            switch status {
            case .unplayable:
                if reason?.starts(with: "Join this channel to get access to members-only content") ?? false { // TODO: original compared to tuple
                    throw YouTubeKitError.membersOnly
                }
            case .loginRequired:
                if reason.map({ $0.starts(with: "This is a private video") || $0.starts(with: "This video is private") }) ?? false { // TODO: original: reason == ["This is a private video. ", "Please sign in to verify that you may see it."] {
                    throw YouTubeKitError.videoPrivate
                }
            case .error:
                throw YouTubeKitError.videoUnavailable
            case .liveStream:
                let streamingData = try await videoInfos.map { $0.streamingData }
                if streamingData.allSatisfy({ $0?.hlsManifestUrl == nil }) {
                    throw YouTubeKitError.liveStreamError
                }
                continue
            case .ok, .none:
                continue
            }
        }
    }
    
    public var ageRestricted: Bool {
        get async throws {
            if let cached = _ageRestricted {
                return cached
            }
            
            _ageRestricted = try await Extraction.isAgeRestricted(watchHTML: watchHTML)
            return _ageRestricted!
        }
    }
    
    var jsURL: URL {
        get async throws {
            if let cached = _jsURL {
                return cached
            }

            // base.js is a SITE-WIDE asset, not per-video, so its URL can be found once
            // and reused for every video. `/iframe_api` publishes the current player id in
            // ~1 KB; deriving it from the watch page instead costs a ~610 KB download PER
            // TRACK (measured on an iPhone 15 over cellular: ~1100-2000 ms per track vs
            // ~47 ms for /iframe_api). That download dominated resolve time.
            if let fast = try? await Self.playerURLFromIframeAPI() {
                _jsURL = fast
                return fast
            }

            // Fallback: the original watch/embed-page derivation.
            if try await ageRestricted {
                _jsURL = try await URL(string: Extraction.jsURL(html: embedHTML))!
            } else {
                _jsURL = try await URL(string: Extraction.jsURL(html: watchHTML))!
            }
            return _jsURL!
        }
    }

    /// Current player JS URL, from `/iframe_api`. Cached process-wide (the player is
    /// site-wide, not per-video) with a short TTL.
    private static func playerURLFromIframeAPI() async throws -> URL {
        iframePlayerURLLock.lock()
        let cached = __iframePlayerURL
        let fetchedAt = __iframePlayerURLFetchedAt
        iframePlayerURLLock.unlock()
        if let cached, let fetchedAt, Date().timeIntervalSince(fetchedAt) < iframePlayerURLTTL {
            return cached
        }

        var request = URLRequest(url: URL(string: "https://www.youtube.com/iframe_api")!)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let js = String(data: data, encoding: .utf8) else {
            throw YouTubeKitError.extractError
        }
        // The body embeds the id as an escaped path: ...\/s\/player\/<id>\/www-widgetapi...
        guard let idRange = js.range(of: #"player\/[a-zA-Z0-9_-]+\/"#, options: .regularExpression) else {
            throw YouTubeKitError.regexMatchError
        }
        let playerID = js[idRange]
            .replacingOccurrences(of: #"player\/"#, with: "")
            .replacingOccurrences(of: #"\/"#, with: "")
        guard !playerID.isEmpty,
              let url = URL(string: "https://www.youtube.com/s/player/\(playerID)/player_ias.vflset/en_US/base.js") else {
            throw YouTubeKitError.extractError
        }

        iframePlayerURLLock.lock()
        __iframePlayerURL = url
        __iframePlayerURLFetchedAt = Date()
        iframePlayerURLLock.unlock()
        return url
    }
    
    var js: String {
        get async throws {
            if let cached = _js {
                return cached
            }
            
            let jsURL = try await jsURL
            
            if YouTube.__jsURL != jsURL {
                let (data, _) = try await URLSession.shared.data(from: jsURL)
                _js = String(data: data, encoding: .utf8) ?? ""
                YouTube.__js = _js
                YouTube.__jsURL = jsURL
            } else {
                _js = YouTube.__js
            }
            return _js!
        }
    }

    var signatureTimestamp: Int? {
        get async throws {
            if let cached = _signatureTimestamp {
                return cached
            }
            
            _signatureTimestamp = try await Extraction.extractSignatureTimestamp(fromJS: js)
            return _signatureTimestamp
        }
    }
    
    var ytcfg: Extraction.YtCfg {
        get async throws {
            if let cached = _ytcfg {
                return cached
            }
            
            Self.ytcfgLock.lock()
            let shared = Self.__ytcfg
            let sharedAt = Self.__ytcfgFetchedAt
            Self.ytcfgLock.unlock()
            if let shared, let sharedAt, Date().timeIntervalSince(sharedAt) < Self.ytcfgTTL {
                _ytcfg = shared
                return shared
            }

            let fetched = try await Extraction.extractYtCfg(from: watchHTML)
            Self.ytcfgLock.lock()
            Self.__ytcfg = fetched
            Self.__ytcfgFetchedAt = Date()
            Self.ytcfgLock.unlock()
            _ytcfg = fetched
            return fetched
        }
    }
    
    /// Interface to query both adaptive (DASH) and progressive streams.
    /// Returns a list of streams if they have been initialized.
    /// If the streams have not been initialized, finds all relevant streams and initializes them.
    public var streams: [Stream] {
        get async throws {
            try await checkAvailability()
            if let cached = _fmtStreams {
                return cached
            }
            
            let result = try await Task.retry(with: methods) { method in
                switch method {
#if canImport(JavaScriptCore)
                case .local:
                    let allStreamingData = try await self.streamingData
                    let videoInfos = try await self.videoInfos
                    
                    var streams = [Stream]()
                    var existingITags = Set<Int>()
                    
                    func process(streamingData: InnerTube.StreamingData, videoInfo: InnerTube.VideoInfo) async throws {
                        
                        var streamManifest = Extraction.applyDescrambler(streamData: streamingData)
                        
                        do {
                            try await Extraction.applySignature(streamManifest: &streamManifest, videoInfo: videoInfo, js: js)
                        } catch is CancellationError {
                            // Cancellation is not a stale-JS failure — propagate it
                            // immediately instead of clearing the cache and retrying.
                            throw CancellationError()
                        } catch {
                            // to force an update to the js file, we clear the cache and retry
                            _js = nil
                            _jsURL = nil
                            YouTube.__js = nil
                            YouTube.__jsURL = nil
                            try await Extraction.applySignature(streamManifest: &streamManifest, videoInfo: videoInfo, js: js)
                        }
                        
                        // filter out dubbed audio tracks
                        streamManifest = Extraction.filterOutDubbedAudio(streamManifest: streamManifest)
                        
                        let newStreams = streamManifest.compactMap { try? Stream(format: $0) }
                        
                        // make sure only one stream per itag exists
                        for stream in newStreams {
                            if existingITags.insert(stream.itag.itag).inserted {
                                streams.append(stream)
                            }
                        }
                    }
                    
                    for (streamingData, videoInfo) in zip(allStreamingData, videoInfos) {
                        try await process(streamingData: streamingData, videoInfo: videoInfo)
                    }
                    
                    // if no progressive (audio+video) tracks were found, try to do one more call to maybe get them
                    if !streams.contains(where: { $0.includesVideoAndAudioTrack }) {
                        if let videoInfo = try? await loadAdditionalVideoInfos(forClient: .mediaConnectFrontend), let streamingData = videoInfo.streamingData {
                            os_log("Found no progressive streams. Called mediaConnectFrontend client to get additional video infos", log: log, type: .info)
                            try await process(streamingData: streamingData, videoInfo: videoInfo)
                        }
                    }
                    
                    return streams
#endif
                    
                case .remote(let serverURL):
                    let remoteClient = RemoteYouTubeClient(serverURL: serverURL)
                    let remoteStreams = try await remoteClient.extractStreams(forVideoID: videoID)
                    
                    return remoteStreams.compactMap { try? Stream(remoteStream: $0) }
                }
            }
            
            _fmtStreams = result
            return result
        }
    }
    
    /// Returns a list of live streams - currently only HLS supported
    /// - Note: Currently doesn't respect `method` set. It always uses `.local`
    public var livestreams: [Livestream] {
        get async throws {
            var livestreams = [Livestream]()
            let hlsURLs = try await streamingData.compactMap { $0.hlsManifestUrl }.compactMap { URL(string: $0) }
            livestreams.append(contentsOf: hlsURLs.map { Livestream(url: $0, streamType: .hls) })
            return livestreams
        }
    }

    /// streaming data from video info
    var streamingData: [InnerTube.StreamingData] {
        get async throws {
            let streamingData = try await videoInfos.compactMap { $0.streamingData }
            if !streamingData.isEmpty {
                return streamingData
            } else {
                try await bypassAgeGate()
                let streamingData = try await videoInfos.compactMap { $0.streamingData }
                if !streamingData.isEmpty {
                    return streamingData
                } else {
                    throw YouTubeKitError.extractError
                }
            }
        }
    }

    /// Video details from video info.
    var videoDetails: [InnerTube.VideoInfo.VideoDetails] {
        get async throws {
            try await videoInfos.compactMap { $0.videoDetails }
        }
    }
    
    var videoInfos: [InnerTube.VideoInfo] {
        get async throws {
            if let cached = _videoInfos {
                return cached
            }
            
            // try extracting video infos from watch html directly as well
            let watchVideoInfoTask = Task<InnerTube.VideoInfo?, Never> { [log] in
                do {
                    return nil //try await Extraction.getVideoInfo(fromHTML: watchHTML)  // (temporarily disabled)
                } catch let error {
                    os_log("Couldn't extract video info from main watch html: %{public}@", log: log, type: .debug, error.localizedDescription)
                    return nil
                }
            }

            let signatureTimestamp = try await signatureTimestamp
            let ytcfg = try await ytcfg
            
            let innertubeClients: [InnerTube.ClientType] = [.androidVR, .webSafari, .web]
            
            let results: [Result<InnerTube.VideoInfo, Error>] = await innertubeClients.concurrentMap { [videoID, useOAuth, allowOAuthCache] client in
                let innertube = InnerTube(client: client, signatureTimestamp: signatureTimestamp, ytcfg: ytcfg, useOAuth: useOAuth, allowCache: allowOAuthCache)
                
                do {
                    let innertubeResponse = try await innertube.player(videoID: videoID)
                    return .success(innertubeResponse)
                } catch let error {
                    return .failure(error)
                }
            }
            
            var videoInfos = [InnerTube.VideoInfo]()
            var errors = [Error]()
            
            for result in results {
                switch result {
                case .success(let innertubeResponse):
                    videoInfos.append(innertubeResponse)
                case .failure(let error):
                    errors.append(error)
                }
            }
            
            // append potentially extracted video info (with least priority)
            if let watchVideoInfo = await watchVideoInfoTask.value {
                videoInfos.append(watchVideoInfo)
            }
            
            // remove video infos with incorrect videoID
            for (i, videoInfo) in videoInfos.enumerated() where videoInfo.videoDetails?.videoId != videoID {
                os_log("Skipping player response from client %{public}i. Got player response for %{public}@ instead of %{public}@", log: log, type: .info, i, videoInfo.videoDetails?.videoId ?? "nil", videoID)
            }
            videoInfos = videoInfos.filter { $0.videoDetails?.videoId == videoID }
            
            if videoInfos.isEmpty {
                throw errors.first ?? YouTubeKitError.extractError
            }
            
            _videoInfos = videoInfos
            return videoInfos
        }
    }
    
    private func loadAdditionalVideoInfos(forClient client: InnerTube.ClientType) async throws -> InnerTube.VideoInfo {
        let signatureTimestamp = try await signatureTimestamp
        let ytcfg = try await ytcfg
        let innertube = InnerTube(client: client, signatureTimestamp: signatureTimestamp, ytcfg: ytcfg, useOAuth: useOAuth, allowCache: allowOAuthCache)
        let videoInfo = try await innertube.player(videoID: videoID)
        
        // ignore if incorrect videoID
        if videoInfo.videoDetails?.videoId != videoID {
            os_log("Skipping player response from %{public}@ client. Got player response for %{public}@ instead of %{public}@", log: log, type: .info, client.rawValue, videoInfo.videoDetails?.videoId ?? "nil", videoID)
            throw YouTubeKitError.extractError
        }
        
        return videoInfo
    }
    
    private func bypassAgeGate() async throws {
        let signatureTimestamp = try await signatureTimestamp
        let ytcfg = try await ytcfg
        let innertube = InnerTube(client: .webCreator, signatureTimestamp: signatureTimestamp, ytcfg: ytcfg, useOAuth: useOAuth, allowCache: allowOAuthCache)
        let innertubeResponse = try await innertube.player(videoID: videoID)

        if innertubeResponse.playabilityStatus?.status == "UNPLAYABLE" || innertubeResponse.playabilityStatus?.status == "LOGIN_REQUIRED" {
            throw YouTubeKitError.videoAgeRestricted
        }

        if innertubeResponse.videoDetails?.videoId != videoID {
            os_log("Skipping player response from webCreator client. Got player response for %{public}@ instead of %{public}@", log: log, type: .info, innertubeResponse.videoDetails?.videoId ?? "nil", videoID)
            throw YouTubeKitError.extractError
        }

        _videoInfos = [innertubeResponse]
    }
    
    /// Interface to query both adaptive (DASH) and progressive streams.
    /*public var streams: StreamQuery {
        get async throws {
            //try await checkAvailability()
            return StreamQuery(fmtStreams: try await fmtStreams)
        }
    }*/
    
}
