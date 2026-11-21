import Combine
import Foundation
import SwiftUI

enum VesperStringVault {
    static let novaAPIBaseURL: String = {
        guard let configured = Bundle.main.object(forInfoDictionaryKey: "NOVA_API_BASE_URL") as? String,
              let url = URL(string: configured), url.scheme?.lowercased() == "https", url.host != nil,
              !url.host!.hasSuffix(".example") else { return "" }
        return configured.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }()
    static var vesperDashClientSessionURL: String { novaAPIBaseURL }
    static var vesperDashPatchesURL: String { novaAPIBaseURL }
    static var vesperDashSettingsURL: String { novaAPIBaseURL }
    private static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { $0 ^ 0x5A }, as: UTF8.self)
    }
    static let vesperChannelURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 46, 116, 55, 63, 117, 12, 63, 41, 42, 63, 40, 31, 34, 46, 40, 63, 52, 59, 54])
    static let nullzthURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 46, 116, 55, 63, 117, 20, 47, 54, 54, 0, 46, 50])
    static let nullzthChannelURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 46, 116, 55, 63, 117, 113, 111, 18, 18, 59, 0, 47, 40, 18, 10, 27, 99, 50, 21, 13, 23, 98])
    static let tiktokURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 45, 45, 45, 116, 46, 51, 49, 46, 53, 49, 116, 57, 53, 55, 117, 26, 63, 54, 5, 48, 63, 60, 40, 35, 5, 5, 5, 101, 5, 40, 103, 107, 124, 5, 46, 103, 0, 14, 119, 99, 99, 49, 109, 43, 25, 35, 42, 31, 51, 108, 45])
    static let telegramBaseURL = decode([46, 46, 42, 42, 117, 117, 46, 55, 117])
}
struct VesperDashManifest: Decodable {
    let version: Int
    let global_paused: Bool
    let patches: [RemotePatch]
    let all_patches: [RemotePatch]?
    let package_passwords: [String]?
}

struct VesperReleasePolicy: Decodable {
    let latestBuild: Int
    let minimumBuild: Int
    let downloadURL: URL
    let updateMessage: String

    private enum CodingKeys: String, CodingKey {
        case latestBuild = "latest_build"
        case minimumBuild = "minimum_build"
        case downloadURL = "download_url"
        case updateMessage = "update_message"
    }

    var displayUpdateMessage: String {
        let value = updateMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "IPA UPDATED, PLEASE DOWNLOAD NEW VERSION" : String(value.prefix(240))
    }
}

struct RemotePatch: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let category: String?
    let game: String
    let bundle_id: String
    let target_path: String
    let target_paths: [String]?
    let filename: String
    let sha256: String
    let version: String
    let size: Int?
    let updated_at: Int?
    let download_url: String
    let image_url: String?
    let status_text: String?
    let sort_order: Int?
    let enabled: Bool
    let paused: Bool

    var normalizedCategory: String {
        let value = (category ?? "aim").lowercased()
        if value == "hologram" { return "weapons" }
        return ["aim", "esp", "body", "weapons", "skin"].contains(value) ? value : "aim"
    }

    var normalizedStatus: String {
        let value = status_text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "NO STATUS" : String(value.prefix(180))
    }

    var displayStatusText: String {
        let value = status_text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(value.prefix(180))
    }

    var normalizedOrder: Int {
        sort_order ?? 1000
    }

    var normalizedTargetPaths: [String] {
        let values = (target_paths ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values.isEmpty ? [target_path] : values
    }
}

struct ManifestHTTPError: LocalizedError {
    let statusCode: Int
    var errorDescription: String? { "API returned HTTP \(statusCode)" }
}

enum VesperDashRemoteSync {
    static let manifestURL = URL(string: VesperStringVault.vesperDashPatchesURL + "/patches")!

    static func fetchNOVAPackageManifest(sessionToken: String) async throws -> VesperDashManifest {
        var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "catalog", value: "nova")]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await fetchManifest(at: url, sessionToken: sessionToken)
    }

    static func fetchReleasePolicy() async throws -> VesperReleasePolicy {
        var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)!
        components.path = (URL(string: VesperStringVault.novaAPIBaseURL)?.path ?? "/api") + "/release-policy"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let policy = try JSONDecoder().decode(VesperReleasePolicy.self, from: data)
        guard policy.latestBuild >= 1,
              policy.minimumBuild >= 0,
              policy.minimumBuild <= policy.latestBuild,
              policy.downloadURL.scheme?.lowercased() == "https",
              policy.downloadURL.user == nil,
              policy.downloadURL.password == nil else {
            throw URLError(.cannotParseResponse)
        }
        return policy
    }

    static func downloadPackageFile(
        for remote: RemotePatch,
        sessionToken: String,
        using session: URLSession,
        into directory: URL
    ) async throws -> URL {
        guard let url = validDownloadURL(for: remote) else {
            throw PatchPackageError.remoteImportFailed
        }
        return try await downloadFile(at: url, sessionToken: sessionToken, using: session, into: directory)
    }

    static func downloadNOVAPackageFile(
        for remote: RemotePatch,
        sessionToken: String,
        using session: URLSession,
        into directory: URL
    ) async throws -> URL {
        guard let url = validNOVAPackageDownloadURL(for: remote) else {
            throw PatchPackageError.remoteImportFailed
        }
        return try await downloadFile(at: url, sessionToken: sessionToken, using: session, into: directory, requireOctetStream: true)
    }

    private static func downloadFile(
        at url: URL,
        sessionToken: String,
        using session: URLSession,
        into directory: URL,
        requireOctetStream: Bool = false
    ) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 180
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        let (temporaryURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw PatchPackageError.remoteImportFailed
        }
        if requireOctetStream {
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";", maxSplits: 1).first
            guard contentType == "application/octet-stream" else { throw PatchPackageError.remoteImportFailed }
        }
        let destination = directory.appendingPathComponent("\(UUID().uuidString).download")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    static func fetchManifest(sessionToken: String) async throws -> VesperDashManifest {
        try await fetchManifest(at: manifestURL, sessionToken: sessionToken)
    }

    private static func fetchManifest(at url: URL, sessionToken: String) async throws -> VesperDashManifest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            if (400..<500).contains(http.statusCode) && http.statusCode != 408 && http.statusCode != 429 {
                throw ManifestHTTPError(statusCode: http.statusCode)
            }
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(VesperDashManifest.self, from: data)
    }

    static func validDownloadURL(for patch: RemotePatch) -> URL? {
        guard let url = URL(string: patch.download_url, relativeTo: manifestURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == manifestURL.host?.lowercased(),
              url.user == nil, url.password == nil,
              patch.bundle_id == "com.dts.freefireth" || patch.bundle_id == "com.dts.freefiremax",
              patch.filename.lowercased().hasSuffix(".3105") else { return nil }
        return url
    }

    static func validNOVAPackageDownloadURL(for patch: RemotePatch) -> URL? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              patch.bundle_id == bundleID,
              patch.filename.lowercased().hasSuffix(".3105"),
              !patch.id.isEmpty,
              !patch.id.contains("/"), !patch.id.contains("\\"),
              let url = URL(string: patch.download_url, relativeTo: manifestURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == manifestURL.host?.lowercased(),
              url.user == nil, url.password == nil else { return nil }
        guard url.path == manifestURL.path + "/" + patch.id + "/download" else { return nil }
        return url
    }

    static func validImageURL(for patch: RemotePatch) -> URL? {
        guard let value = patch.image_url,
              let url = URL(string: value, relativeTo: manifestURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == manifestURL.host?.lowercased(),
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}


struct VesperAppSettings: Decodable {
    private enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case developerName = "developer_name"
        case developerSubtitle = "developer_subtitle"
        case channelName = "channel_name"
        case channelHandle = "channel_handle"
        case channelURL = "channel_url"
        case ownerName = "owner_name"
        case ownerHandle = "owner_handle"
        case ownerURL = "owner_url"
        case footerText = "footer_text"
    }

    let appName: String
    let developerName: String
    let developerSubtitle: String
    let channelName: String
    let channelHandle: String
    let channelURL: String
    let ownerName: String
    let ownerHandle: String
    let ownerURL: String
    let footerText: String

    static let fallback = VesperAppSettings(
        appName: "NOVA",
        developerName: "Yagami",
        developerSubtitle: "NOVA Developer",
        channelName: "NOVA Official Channel",
        channelHandle: "Discord",
        channelURL: "https://discord.gg/VqkjH4pJv",
        ownerName: "NOVA Owner",
        ownerHandle: "@Rybkx",
        ownerURL: "https://discord.gg/VqkjH4pJv",
        footerText: "NOVA • READY"
    )

    init(appName: String, developerName: String, developerSubtitle: String, channelName: String, channelHandle: String, channelURL: String, ownerName: String, ownerHandle: String, ownerURL: String, footerText: String) {
        self.appName = appName; self.developerName = developerName; self.developerSubtitle = developerSubtitle
        self.channelName = channelName; self.channelHandle = channelHandle; self.channelURL = channelURL
        self.ownerName = ownerName; self.ownerHandle = ownerHandle; self.ownerURL = ownerURL; self.footerText = footerText
    }

    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        let f = VesperAppSettings.fallback
        func currentValue(_ key: CodingKeys, fallback: String) throws -> String {
            let value = try d.decodeIfPresent(String.self, forKey: key) ?? fallback
            return value.lowercased().contains("vesper") ? fallback : value
        }
        appName = try currentValue(.appName, fallback: f.appName)
        developerName = try currentValue(.developerName, fallback: f.developerName)
        developerSubtitle = try currentValue(.developerSubtitle, fallback: f.developerSubtitle)
        channelName = try currentValue(.channelName, fallback: f.channelName)
        channelHandle = try currentValue(.channelHandle, fallback: f.channelHandle)
        channelURL = try currentValue(.channelURL, fallback: f.channelURL)
        ownerName = try currentValue(.ownerName, fallback: f.ownerName)
        ownerHandle = try currentValue(.ownerHandle, fallback: f.ownerHandle)
        ownerURL = try currentValue(.ownerURL, fallback: f.ownerURL)
        footerText = try currentValue(.footerText, fallback: f.footerText)
    }
}

extension VesperDashRemoteSync {
    static let settingsURL = URL(string: VesperStringVault.vesperDashSettingsURL + "/settings")!

    static func fetchAppSettings() async throws -> VesperAppSettings {
        let (data, response) = try await URLSession.shared.data(from: settingsURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(VesperAppSettings.self, from: data)
    }
}

struct NOVAStoredDocument: Identifiable, Equatable, Sendable {
    let id: String
    let filename: String
    let version: String
    let sha256: String
    let sizeBytes: Int
    let updatedAt: String?
    let isAvailable: Bool
    let statusText: String

    var isRecentlyUploaded: Bool {
        guard let updatedAt else { return false }
        let date = TimeInterval(updatedAt).map(Date.init(timeIntervalSince1970:))
            ?? ISO8601DateFormatter().date(from: updatedAt)
        guard let date else { return false }
        let age = Date().timeIntervalSince(date)
        return age >= 0 && age < 7 * 24 * 60 * 60
    }
}

@MainActor
final class NOVARemoteDocumentSyncStore: ObservableObject {
    @Published private(set) var files: [NOVAStoredDocument] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var hasError = false
    @Published private(set) var requiresActivation = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var globalPaused = false
    @Published private(set) var syncErrorDescription: String?
    @Published private(set) var appliedDocumentIDs: Set<String>
    @Published private(set) var operatingDocumentIDs = Set<String>()
    @Published private(set) var recoveryRequiredDocumentIDs = Set<String>()
    @Published private(set) var operationStatusKeys: [String: String] = [:]
    @Published private(set) var operationErrorDescriptions: [String: String] = [:]

    private struct ActiveRecord: Codable {
        let id: String
        let projectID: UUID
        let transactionID: UUID?
        let filename: String
        let sizeBytes: Int
        let updatedAt: String?
        let version: String
        let sha256: String

        private enum CodingKeys: String, CodingKey {
            case id, projectID, transactionID, filename, sizeBytes, updatedAt, version, sha256
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let stringID = try? values.decode(String.self, forKey: .id) {
                id = stringID
            } else {
                id = String(try values.decode(Int.self, forKey: .id))
            }
            projectID = try values.decode(UUID.self, forKey: .projectID)
            transactionID = try values.decodeIfPresent(UUID.self, forKey: .transactionID)
            filename = try values.decode(String.self, forKey: .filename)
            sizeBytes = try values.decode(Int.self, forKey: .sizeBytes)
            updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
            version = try values.decodeIfPresent(String.self, forKey: .version) ?? ""
            sha256 = try values.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        }

        init(id: String, projectID: UUID, transactionID: UUID?, filename: String, sizeBytes: Int, updatedAt: String?, version: String, sha256: String) {
            self.id = id
            self.projectID = projectID
            self.transactionID = transactionID
            self.filename = filename
            self.sizeBytes = sizeBytes
            self.updatedAt = updatedAt
            self.version = version
            self.sha256 = sha256
        }

        func matches(_ remote: RemotePatch) -> Bool {
            filename == remote.filename && sizeBytes == (remote.size ?? -1)
                && (updatedAt == remote.updated_at.map(String.init))
                && (version.isEmpty || version == remote.version)
                && (sha256.isEmpty || sha256.caseInsensitiveCompare(remote.sha256) == .orderedSame)
        }
    }

    private static let activeRecordsDefaultsKey = "NOVA.activeRemotePackages.v1"
    private let maximumFileBytes = 25 * 1024 * 1024
    private let managedDirectoryName = "NOVAReceivedFiles"
    private let fileManager = FileManager.default
    private var activeRecords: [String: ActiveRecord]
    private var remotePatchesByID: [String: RemotePatch] = [:]

    init() {
        let records = Self.loadActiveRecords()
        activeRecords = records
        appliedDocumentIDs = Set(records.values.compactMap { record in
            let exact = record.transactionID.flatMap {
                DevicePatchService.receipt(
                    projectID: record.projectID, transactionID: $0,
                    targetBundleID: Bundle.main.bundleIdentifier
                )
            }
            let receipt = record.transactionID == nil ? DevicePatchService.latestReceipt(
                projectID: record.projectID, targetBundleID: Bundle.main.bundleIdentifier
            ) : exact
            return receipt == nil ? nil : record.id
        })
        recoveryRequiredDocumentIDs = Set(records.values.compactMap { record in
            let exact = record.transactionID.flatMap {
                DevicePatchService.receipt(
                    projectID: record.projectID, transactionID: $0,
                    targetBundleID: Bundle.main.bundleIdentifier, includePrepared: true
                )
            }
            let applied = record.transactionID.flatMap {
                DevicePatchService.receipt(
                    projectID: record.projectID, transactionID: $0,
                    targetBundleID: Bundle.main.bundleIdentifier
                )
            }
            let preparedWithoutExactID = record.transactionID == nil && DevicePatchService.latestPreparedReceipt(
                projectID: record.projectID, targetBundleID: Bundle.main.bundleIdentifier
            ) != nil
            let unresolvedArtifacts = applied == nil && DevicePatchService.transactionArtifactsExist(
                projectID: record.projectID, transactionID: record.transactionID
            )
            return (exact != nil && applied == nil) || preparedWithoutExactID || unresolvedArtifacts ? record.id : nil
        })
    }

    func sync(sessionToken: String?) async {
        guard !isSyncing else { return }
        guard let sessionToken, !sessionToken.isEmpty else {
            requiresActivation = true
            return
        }

        isSyncing = true
        hasError = false
        requiresActivation = false
        syncErrorDescription = nil
        defer { isSyncing = false }

        do {
            let manifest = try await VesperDashRemoteSync.fetchNOVAPackageManifest(sessionToken: sessionToken)
            guard manifest.version == 9, let targetBundle = Bundle.main.bundleIdentifier else {
                throw URLError(.cannotParseResponse)
            }
            let remoteFiles = (manifest.all_patches ?? manifest.patches).filter {
                $0.bundle_id == targetBundle && $0.filename.lowercased().hasSuffix(".3105")
            }
            let directory = try managedDirectory(createIfNeeded: true)
            var remoteByID: [String: RemotePatch] = [:]
            for remote in remoteFiles {
                guard Self.isSafeIdentifier(remote.id), remoteByID[remote.id] == nil,
                      let size = remote.size, size > 0, size <= maximumFileBytes,
                      remote.sha256.count == 64,
                      remote.sha256.allSatisfy({ $0.isHexDigit }),
                      Self.isSafeFilename(remote.filename) else {
                    throw URLError(.cannotParseResponse)
                }
                remoteByID[remote.id] = remote
            }
            globalPaused = manifest.global_paused
            remotePatchesByID = remoteByID

            var expectedNames = Set<String>()
            var storedByID: [String: NOVAStoredDocument] = [:]
            for record in Array(activeRecords.values) {
                let remote = remoteByID[record.id]
                if let remote, record.matches(remote), Self.isAvailable(remote, globalPaused: manifest.global_paused) {
                    do {
                        try await reconcile(record)
                        operationStatusKeys.removeValue(forKey: record.id)
                        operationErrorDescriptions.removeValue(forKey: record.id)
                        if activeRecords[record.id] != nil {
                            expectedNames.insert(Self.localName(id: record.id, filename: record.filename))
                            storedByID[record.id] = Self.stored(remote, globalPaused: manifest.global_paused)
                        }
                    } catch {
                        operationStatusKeys[record.id] = Self.statusKey(for: error)
                        operationErrorDescriptions[record.id] = error.localizedDescription
                        recoveryRequiredDocumentIDs.insert(record.id)
                        expectedNames.insert(Self.localName(id: record.id, filename: record.filename))
                        storedByID[record.id] = Self.stored(remote, globalPaused: manifest.global_paused)
                    }
                } else {
                    do {
                        try await restore(record)
                        activeRecords.removeValue(forKey: record.id)
                        appliedDocumentIDs.remove(record.id)
                        recoveryRequiredDocumentIDs.remove(record.id)
                        operationStatusKeys.removeValue(forKey: record.id)
                        operationErrorDescriptions.removeValue(forKey: record.id)
                        persistActiveRecords()
                    } catch {
                        operationStatusKeys[record.id] = Self.statusKey(for: error)
                        operationErrorDescriptions[record.id] = error.localizedDescription
                        recoveryRequiredDocumentIDs.insert(record.id)
                        expectedNames.insert(Self.localName(id: record.id, filename: record.filename))
                        storedByID[record.id] = remote.map { Self.stored($0, globalPaused: manifest.global_paused) } ?? Self.stored(record)
                    }
                }
            }

            for remote in remoteFiles {
                let item = Self.stored(remote, globalPaused: manifest.global_paused)
                let localName = Self.localName(id: remote.id, filename: remote.filename)
                let destination = directory.appendingPathComponent(localName, isDirectory: false)
                if item.isAvailable {
                    if !(try hasValidCachedFile(at: destination, expectedSize: item.sizeBytes)) {
                        let data = try await download(remote, sessionToken: sessionToken)
                        guard data.count == item.sizeBytes, data.count <= maximumFileBytes,
                              VesperDashDigest.hex(data).caseInsensitiveCompare(remote.sha256) == .orderedSame else {
                            throw URLError(.cannotParseResponse)
                        }
                        try data.write(to: destination, options: .atomic)
                    }
                    expectedNames.insert(localName)
                }
                storedByID[remote.id] = item
            }

            try removeStaleManagedFiles(in: directory, retaining: expectedNames)
            operationStatusKeys = operationStatusKeys.filter { storedByID[$0.key] != nil }
            operationErrorDescriptions = operationErrorDescriptions.filter { storedByID[$0.key] != nil }
            files = storedByID.values.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
            lastSyncedAt = Date()
            hasError = !operationStatusKeys.isEmpty
            syncErrorDescription = nil
            requiresActivation = false
        } catch let error as ManifestHTTPError {
            hasError = true
            requiresActivation = error.statusCode == 401 || error.statusCode == 403
            syncErrorDescription = error.localizedDescription
        } catch {
            hasError = true
            syncErrorDescription = error.localizedDescription
        }
    }

    func setApplied(_ shouldApply: Bool, document: NOVAStoredDocument, sessionToken: String?) async -> Bool {
        let id = document.id
        guard !operatingDocumentIDs.contains(id), !recoveryRequiredDocumentIDs.contains(id) else { return false }
        if shouldApply == appliedDocumentIDs.contains(id) { return false }
        operatingDocumentIDs.insert(id)
        operationStatusKeys.removeValue(forKey: id)
        operationErrorDescriptions.removeValue(forKey: id)
        defer { operatingDocumentIDs.remove(id) }

        do {
            if shouldApply {
                guard let sessionToken, !sessionToken.isEmpty else { throw ManifestHTTPError(statusCode: 401) }
                try await apply(document, sessionToken: sessionToken)
                appliedDocumentIDs.insert(id)
                operationStatusKeys.removeValue(forKey: id)
                operationErrorDescriptions.removeValue(forKey: id)
            } else {
                guard let record = activeRecords[id] else {
                    appliedDocumentIDs.remove(id)
                    return false
                }
                try await restore(record)
                activeRecords.removeValue(forKey: id)
                persistActiveRecords()
                appliedDocumentIDs.remove(id)
                recoveryRequiredDocumentIDs.remove(id)
                operationStatusKeys.removeValue(forKey: id)
                operationErrorDescriptions.removeValue(forKey: id)
            }
            return true
        } catch {
            if let record = activeRecords[id] {
                let exact = record.transactionID.flatMap {
                    DevicePatchService.receipt(
                        projectID: record.projectID, transactionID: $0,
                        targetBundleID: Bundle.main.bundleIdentifier, includePrepared: true
                    )
                }
                let exactApplied = record.transactionID.flatMap {
                    DevicePatchService.receipt(
                        projectID: record.projectID, transactionID: $0,
                        targetBundleID: Bundle.main.bundleIdentifier
                    )
                }
                let applied = exactApplied != nil || (record.transactionID == nil && DevicePatchService.latestReceipt(
                    projectID: record.projectID, targetBundleID: Bundle.main.bundleIdentifier
                ) != nil)
                let prepared = (exact != nil && exactApplied == nil) || (record.transactionID == nil && DevicePatchService.latestPreparedReceipt(
                    projectID: record.projectID, targetBundleID: Bundle.main.bundleIdentifier
                ) != nil)
                if applied { appliedDocumentIDs.insert(id) }
                if prepared { recoveryRequiredDocumentIDs.insert(id) }
            }
            operationStatusKeys[id] = Self.statusKey(for: error)
            operationErrorDescriptions[id] = error.localizedDescription
            return false
        }
    }

    func deactivate() async {
        requiresActivation = true
        while isSyncing || !operatingDocumentIDs.isEmpty {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
        var keepNames = Set<String>()
        for record in Array(activeRecords.values) {
            do {
                try await restore(record)
                activeRecords.removeValue(forKey: record.id)
                appliedDocumentIDs.remove(record.id)
                recoveryRequiredDocumentIDs.remove(record.id)
                operationStatusKeys.removeValue(forKey: record.id)
                operationErrorDescriptions.removeValue(forKey: record.id)
            } catch {
                keepNames.insert(Self.localName(id: record.id, filename: record.filename))
                operationStatusKeys[record.id] = Self.statusKey(for: error)
                operationErrorDescriptions[record.id] = error.localizedDescription
            }
        }
        persistActiveRecords()
        files = activeRecords.values.map(Self.stored).sorted {
            $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
        }
        if let directory = try? managedDirectory(createIfNeeded: false) {
            try? removeStaleManagedFiles(in: directory, retaining: keepNames)
        }
        hasError = !activeRecords.isEmpty
        lastSyncedAt = nil
    }

    private func apply(_ document: NOVAStoredDocument, sessionToken: String) async throws {
        guard document.filename.lowercased().hasSuffix(".3105"),
              document.isAvailable,
              let remote = remotePatchesByID[document.id],
              remote.bundle_id == Bundle.main.bundleIdentifier,
              document.version == remote.version,
              document.sha256.caseInsensitiveCompare(remote.sha256) == .orderedSame else {
            throw PatchPackageError.remoteImportFailed
        }
        let data = try await download(remote, sessionToken: sessionToken)
        guard data.count == document.sizeBytes, data.count <= maximumFileBytes,
              VesperDashDigest.hex(data).caseInsensitiveCompare(remote.sha256) == .orderedSame else {
            throw PatchPackageError.sizeLimitExceeded
        }
        _ = try PatchPackageCodec.inspect(data)
        let decoded = try PatchPackageCodec.decode(data, password: nil)
        let project = decoded.project
        let target = Bundle.main.bundleIdentifier
        guard project.allBundleIdentifiers.count == 1,
              project.allBundleIdentifiers.first == target else {
            throw PatchPackageError.invalidBundleIdentifier
        }

        let record = ActiveRecord(
            id: remote.id, projectID: project.id, transactionID: nil, filename: remote.filename,
            sizeBytes: document.sizeBytes, updatedAt: Self.updatedAtToken(remote.updated_at),
            version: remote.version, sha256: remote.sha256
        )
        guard !activeRecords.values.contains(where: { $0.projectID == project.id && $0.id != remote.id }) else {
            throw PatchPackageError.duplicateTarget
        }
        activeRecords[remote.id] = record
        persistActiveRecords()
        do {
            let receipt = try await Task.detached(priority: .userInitiated) {
                try DevicePatchService.applyNOVAPackage(project: project)
            }.value
            activeRecords[remote.id] = ActiveRecord(
                id: remote.id, projectID: project.id, transactionID: receipt.id,
                filename: remote.filename, sizeBytes: document.sizeBytes,
                updatedAt: Self.updatedAtToken(remote.updated_at), version: remote.version, sha256: remote.sha256
            )
            persistActiveRecords()
        } catch {
            if let prepared = DevicePatchService.latestPreparedReceipt(
                projectID: project.id, targetBundleID: target
            ) {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try DevicePatchService.restoreNOVAPackage(receipt: prepared)
                    }.value
                    activeRecords.removeValue(forKey: remote.id)
                    persistActiveRecords()
                } catch {
                    recoveryRequiredDocumentIDs.insert(remote.id)
                }
            } else {
                activeRecords.removeValue(forKey: remote.id)
                persistActiveRecords()
            }
            throw error
        }
    }

    private func reconcile(_ record: ActiveRecord) async throws {
        if let applied = appliedReceipt(for: record) {
            guard try PatchTransaction.requiredBundleIdentifiers(for: applied) == [Bundle.main.bundleIdentifier].compactMap({ $0 }) else {
                throw PatchPackageError.invalidBundleIdentifier
            }
            appliedDocumentIDs.insert(record.id)
            recoveryRequiredDocumentIDs.remove(record.id)
            return
        }
        if let prepared = preparedReceipt(for: record) {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DevicePatchService.restoreNOVAPackage(receipt: prepared)
                }.value
                activeRecords.removeValue(forKey: record.id)
                appliedDocumentIDs.remove(record.id)
                recoveryRequiredDocumentIDs.remove(record.id)
                persistActiveRecords()
            } catch {
                recoveryRequiredDocumentIDs.insert(record.id)
                throw error
            }
            return
        }
        if DevicePatchService.transactionArtifactsExist(
            projectID: record.projectID, transactionID: record.transactionID
        ) {
            recoveryRequiredDocumentIDs.insert(record.id)
            throw PatchPackageError.restoreFailed
        }
        activeRecords.removeValue(forKey: record.id)
        appliedDocumentIDs.remove(record.id)
        recoveryRequiredDocumentIDs.remove(record.id)
        persistActiveRecords()
    }

    private func restore(_ record: ActiveRecord) async throws {
        if let receipt = outstandingReceipt(for: record) {
            try await Task.detached(priority: .userInitiated) {
                try DevicePatchService.restoreNOVAPackage(receipt: receipt)
            }.value
        } else if DevicePatchService.transactionArtifactsExist(
            projectID: record.projectID, transactionID: record.transactionID
        ) {
            throw PatchPackageError.restoreFailed
        }
    }

    private func appliedReceipt(for record: ActiveRecord) -> PatchTransactionReceipt? {
        if let transactionID = record.transactionID {
            return DevicePatchService.receipt(
                projectID: record.projectID, transactionID: transactionID,
                targetBundleID: Bundle.main.bundleIdentifier
            )
        }
        return DevicePatchService.latestReceipt(
            projectID: record.projectID, targetBundleID: Bundle.main.bundleIdentifier
        )
    }

    private func preparedReceipt(for record: ActiveRecord) -> PatchTransactionReceipt? {
        if let transactionID = record.transactionID {
            let any = DevicePatchService.receipt(
                projectID: record.projectID, transactionID: transactionID,
                targetBundleID: Bundle.main.bundleIdentifier, includePrepared: true
            )
            return appliedReceipt(for: record) == nil ? any : nil
        }
        return DevicePatchService.latestPreparedReceipt(
            projectID: record.projectID, targetBundleID: Bundle.main.bundleIdentifier
        )
    }

    private func outstandingReceipt(for record: ActiveRecord) -> PatchTransactionReceipt? {
        appliedReceipt(for: record) ?? preparedReceipt(for: record)
    }

    private func persistActiveRecords() {
        guard let data = try? JSONEncoder().encode(activeRecords) else { return }
        UserDefaults.standard.set(data, forKey: Self.activeRecordsDefaultsKey)
    }

    private static func loadActiveRecords() -> [String: ActiveRecord] {
        guard let data = UserDefaults.standard.data(forKey: activeRecordsDefaultsKey),
              let records = try? JSONDecoder().decode([String: ActiveRecord].self, from: data) else { return [:] }
        return records
    }

    private static func localName(id: String, filename: String) -> String { "\(id)__\(filename)" }

    private static func stored(_ record: ActiveRecord) -> NOVAStoredDocument {
        NOVAStoredDocument(
            id: record.id, filename: record.filename, version: record.version,
            sha256: record.sha256, sizeBytes: record.sizeBytes, updatedAt: record.updatedAt,
            isAvailable: false, statusText: ""
        )
    }

    private static func stored(_ remote: RemotePatch, globalPaused: Bool) -> NOVAStoredDocument {
        let available = isAvailable(remote, globalPaused: globalPaused)
        let status: String
        if globalPaused || remote.paused || !remote.enabled {
            status = remote.displayStatusText.isEmpty ? "Maintenance" : remote.displayStatusText
        } else {
            status = remote.displayStatusText.isEmpty ? "Available" : remote.displayStatusText
        }
        return NOVAStoredDocument(
            id: remote.id, filename: remote.filename, version: remote.version,
            sha256: remote.sha256, sizeBytes: remote.size ?? 0,
            updatedAt: updatedAtToken(remote.updated_at), isAvailable: available, statusText: status
        )
    }

    private static func isAvailable(_ remote: RemotePatch, globalPaused: Bool) -> Bool {
        !globalPaused && remote.enabled && !remote.paused
    }

    private static func updatedAtToken(_ timestamp: Int?) -> String? {
        guard let timestamp else { return nil }
        return String(timestamp)
    }

    private static func isSafeIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.utf8.count <= 128
            && identifier != "." && identifier != ".."
            && !identifier.contains("/") && !identifier.contains("\\")
            && !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func statusKey(for error: Error) -> String {
        if let packageError = error as? PatchPackageError {
            switch packageError {
            case .unsupportedFormat, .unsupportedVersion: return "nova.files.package_invalid"
            case .invalidBundleIdentifier: return "nova.files.wrong_target"
            case .invalidPasswordOrCorruptedPackage: return "nova.files.package_invalid"
            case .restoreFailed, .targetAppUnavailable(_), .missingTarget(_), .symbolicLinkUnsupported: return "nova.files.restore_failed"
            default: return "nova.files.apply_failed"
            }
        }
        if let httpError = error as? ManifestHTTPError, httpError.statusCode == 401 || httpError.statusCode == 403 {
            return "nova.files.auth_required"
        }
        return "nova.files.apply_failed"
    }

    private func download(_ remote: RemotePatch, sessionToken: String) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NOVA-package-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let fileURL = try await VesperDashRemoteSync.downloadNOVAPackageFile(
            for: remote, sessionToken: sessionToken, using: .shared, into: directory
        )
        return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    }

    private func apiBaseURL() throws -> URL {
        guard let url = URL(string: VesperStringVault.novaAPIBaseURL),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw URLError(.badURL) }
        return url
    }

    private func managedDirectory(createIfNeeded: Bool) throws -> URL {
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw URLError(.resourceUnavailable)
        }
        let root = applicationSupport.standardizedFileURL
        let directory = root.appendingPathComponent(managedDirectoryName, isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent() == root else { throw URLError(.badURL) }
        if createIfNeeded {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } else if !fileManager.fileExists(atPath: directory.path) {
            throw URLError(.fileDoesNotExist)
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw URLError(.cannotWriteToFile) }
        return directory
    }

    private func hasValidCachedFile(at url: URL, expectedSize: Int) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory != true, values.isSymbolicLink != true else { throw URLError(.cannotWriteToFile) }
        return values.fileSize == expectedSize
    }

    private func removeStaleManagedFiles(in directory: URL, retaining names: Set<String>) throws {
        let rootPath = directory.standardizedFileURL.path + "/"
        let children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
        for child in children {
            let childPath = child.standardizedFileURL.path
            guard childPath.hasPrefix(rootPath), Self.isManagedFilename(child.lastPathComponent) else { continue }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory != true, values.isSymbolicLink != true else { continue }
            if !names.contains(child.lastPathComponent) { try fileManager.removeItem(at: child) }
        }
    }

    private static func isManagedFilename(_ name: String) -> Bool {
        guard let separator = name.range(of: "__") else { return false }
        let identifier = String(name[..<separator.lowerBound])
        let filename = String(name[separator.upperBound...])
        return isSafeIdentifier(identifier) && isSafeFilename(filename)
    }

    private static func isSafeFilename(_ rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != "." && name != ".."
            && name.lengthOfBytes(using: .utf8) <= 255
            && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
@MainActor
struct NOVAReceivedDocumentsCard: View {
    let shouldSyncOnReentry: Bool
    let onApplied: () -> Void
    let onRestored: () -> Void

    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var licenseManager: LicenseManager
    @StateObject private var store = NOVARemoteDocumentSyncStore()
    @State private var pollingEnabled = false

    var body: some View {
        ZStack {
            NOVAStormBackdrop()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        NOVAChamferedShape(cut: 13)
                            .fill(LinearGradient(colors: [NOVAControlPalette.red, NOVAControlPalette.deepRed], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 56, height: 56)
                    .overlay(NOVAChamferedShape(cut: 13).stroke(.white.opacity(0.34), lineWidth: 1))
                    .shadow(color: NOVAControlPalette.red.opacity(0.38), radius: 10, x: 0, y: 4)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(appLanguage.text("nova.files.title"))
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .tracking(1.0)
                            .foregroundStyle(.white)
                        Text(appLanguage.text("nova.files.subtitle"))
                            .font(.system(size: 8, weight: .black, design: .rounded))
                            .tracking(1.25)
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Spacer(minLength: 2)
                    Button(action: syncNow) {
                        Image(systemName: store.isSyncing ? "hourglass" : "arrow.clockwise")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(NOVAChamferedShape(cut: 10).fill(NOVAControlPalette.red))
                            .overlay(NOVAChamferedShape(cut: 10).stroke(.white.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(appLanguage.text(store.isSyncing ? "nova.files.syncing" : "nova.files.sync")))
                    .disabled(store.isSyncing || !licenseManager.isActive)
                }

                HStack(spacing: 7) {
                    statusTile(icon: "shippingbox.fill", label: appLanguage.text("nova.files.tile.package"))
                    statusTile(icon: "iphone", label: appLanguage.text("nova.files.tile.target"))
                    statusTile(icon: "arrow.uturn.backward", label: appLanguage.text("nova.files.tile.restore"))
                }

                if let lastSyncedAt = store.lastSyncedAt {
                    Text(appLanguage.text("nova.files.last_sync", lastSyncedAt.formatted(date: .abbreviated, time: .shortened)))
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                }

                if !licenseManager.isActive || store.requiresActivation {
                    Label(appLanguage.text("nova.files.auth_required"), systemImage: "key.fill")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(NOVAControlPalette.red.opacity(0.94))
                } else if store.hasError {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(appLanguage.text("nova.files.sync_failed"), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(NOVAControlPalette.red.opacity(0.94))
                        if let detail = store.syncErrorDescription {
                            Text(detail)
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundStyle(NOVAControlPalette.red.opacity(0.82))
                                .lineLimit(2)
                        }
                    }
                }

                if store.files.isEmpty && !store.isSyncing {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(appLanguage.text("nova.files.none"))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                        Text(appLanguage.text("nova.files.none_detail"))
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(NOVAControlPalette.black.opacity(0.64))
                    .clipShape(NOVAChamferedShape(cut: 9))
                }

                ForEach(store.files) { file in
                    documentRow(file)
                }

                Rectangle()
                    .fill(LinearGradient(colors: [.clear, NOVAControlPalette.red.opacity(0.58), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .padding(.top, 1)
                Text(appLanguage.text("nova.files.apply_notice"))
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.54))
                Text(appLanguage.text("nova.files.maintenance_note"))
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NOVAControlPalette.panel)
        .clipShape(NOVAChamferedShape(cut: 18))
        .overlay(NOVAChamferedShape(cut: 18).stroke(.white.opacity(0.20), lineWidth: 1))
        .shadow(color: NOVAControlPalette.red.opacity(0.15), radius: 14, x: 0, y: 7)
        .onAppear {
            if shouldSyncOnReentry { syncNow() }
        }
        .onChange(of: shouldSyncOnReentry) { shouldSync in
            if shouldSync { syncNow() }
        }
        .onChange(of: licenseManager.clientSessionRevision) { _ in
            guard shouldSyncOnReentry, licenseManager.isActive else { return }
            syncNow()
        }
        .onChange(of: licenseManager.isActive) { isActive in
            if isActive && shouldSyncOnReentry {
                syncNow()
            } else if !isActive {
                pollingEnabled = false
                Task { await store.deactivate() }
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, shouldSyncOnReentry, licenseManager.isActive else { return }
            syncNow()
        }
        .task(id: shouldSyncOnReentry && pollingEnabled) {
            guard shouldSyncOnReentry && pollingEnabled else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard !Task.isCancelled else { return }
                guard shouldSyncOnReentry, licenseManager.isActive else { continue }
                await store.sync(sessionToken: licenseManager.clientSessionToken())
            }
        }
    }

    private func statusTile(icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(NOVAControlPalette.red)
            Text(label)
                .font(.system(size: 7, weight: .black, design: .rounded))
                .tracking(0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white.opacity(0.83))
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(NOVAControlPalette.black.opacity(0.74))
        .clipShape(NOVAChamferedShape(cut: 7))
        .overlay(NOVAChamferedShape(cut: 7).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func documentRow(_ file: NOVAStoredDocument) -> some View {
        let isApplied = store.appliedDocumentIDs.contains(file.id)
        let isBusy = store.operatingDocumentIDs.contains(file.id)
        let needsRecovery = store.recoveryRequiredDocumentIDs.contains(file.id)
        let statusKey = store.operationStatusKeys[file.id]
        let operationError = store.operationErrorDescriptions[file.id]

        return VStack(alignment: .leading, spacing: 8) {
            if file.isRecentlyUploaded {
                HStack(spacing: 6) {
                    Capsule().fill(NOVAControlPalette.red).frame(width: 18, height: 3)
                    Text(appLanguage.text("nova.files.recent"))
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(NOVAControlPalette.red)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .foregroundStyle(NOVAControlPalette.red)
                    .frame(width: 34, height: 34)
                    .background(NOVAControlPalette.black)
                    .clipShape(NOVAChamferedShape(cut: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.filename)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text("\(appLanguage.text("nova.files.version")) \(file.version) • \(file.statusText)")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(file.isAvailable ? NOVAControlPalette.green : NOVAControlPalette.amber)
                        .lineLimit(2)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.sizeBytes), countStyle: .file))
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                }
                Spacer(minLength: 4)
                Toggle(isOn: Binding(
                    get: { store.appliedDocumentIDs.contains(file.id) },
                    set: { desiredState in
                        Task {
                            let succeeded = await store.setApplied(
                                desiredState,
                                document: file,
                                sessionToken: licenseManager.clientSessionToken()
                            )
                            guard succeeded else { return }
                            if desiredState { onApplied() } else { onRestored() }
                        }
                    }
                )) {
                    Text(appLanguage.text("nova.files.toggle_hint"))
                }
                .labelsHidden()
                .tint(NOVAControlPalette.green)
                .accessibilityLabel(Text(appLanguage.text("nova.files.toggle_hint")))
                .disabled(isBusy || needsRecovery || store.isSyncing || (!file.isAvailable && !isApplied) || (!licenseManager.isActive && !isApplied))
            }
            let stateKey = statusKey ?? (needsRecovery ? "nova.files.recovery_required" : (isBusy ? "nova.files.processing" : (isApplied ? "nova.files.applied" : (file.isAvailable ? "nova.files.not_applied" : "nova.files.unavailable"))))
            let stateColor = statusKey != nil || needsRecovery ? NOVAControlPalette.red : (isApplied ? NOVAControlPalette.green : (file.isAvailable ? .white.opacity(0.55) : NOVAControlPalette.amber))
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(stateColor)
                    .frame(width: 3, height: 10)
                Text(appLanguage.text(stateKey))
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(stateColor)
                if let operationError, !operationError.isEmpty {
                    Text(operationError)
                        .font(.system(size: 7, weight: .medium, design: .rounded))
                        .foregroundStyle(NOVAControlPalette.red.opacity(0.9))
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(NOVAControlPalette.black.opacity(0.82))
        .clipShape(NOVAChamferedShape(cut: 10))
        .overlay(NOVAChamferedShape(cut: 10).stroke(
            needsRecovery || statusKey != nil ? NOVAControlPalette.red.opacity(0.72) : (isApplied ? NOVAControlPalette.green.opacity(0.58) : .white.opacity(0.13)),
            lineWidth: 1
        ))
    }

    private func syncNow() {
        guard licenseManager.isActive else { return }
        pollingEnabled = true
        Task { await store.sync(sessionToken: licenseManager.clientSessionToken()) }
    }
}

private enum NOVAControlPalette {
    static let red = Color(red: 0.94, green: 0.12, blue: 0.20)
    static let deepRed = Color(red: 0.36, green: 0.035, blue: 0.07)
    static let green = Color(red: 0.20, green: 0.88, blue: 0.49)
    static let amber = Color(red: 1.00, green: 0.69, blue: 0.20)
    static let black = Color(red: 0.025, green: 0.026, blue: 0.032)
    static let panel = Color(red: 0.045, green: 0.043, blue: 0.052)
}

private struct NOVAChamferedShape: Shape {
    var cut: CGFloat

    func path(in rect: CGRect) -> Path {
        let corner = min(cut, min(rect.width / 5, rect.height / 3))
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + corner, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + corner))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
            path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + corner, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - corner))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corner))
            path.closeSubpath()
        }
    }
}

private struct NOVAStormBackdrop: View {
    private let bolts: [[CGPoint]] = [
        [CGPoint(x: 0.06, y: 0.02), CGPoint(x: 0.13, y: 0.13), CGPoint(x: 0.10, y: 0.20), CGPoint(x: 0.21, y: 0.31)],
        [CGPoint(x: 0.70, y: 0.00), CGPoint(x: 0.64, y: 0.12), CGPoint(x: 0.72, y: 0.19), CGPoint(x: 0.60, y: 0.30)],
        [CGPoint(x: 0.94, y: 0.34), CGPoint(x: 0.86, y: 0.45), CGPoint(x: 0.92, y: 0.52), CGPoint(x: 0.82, y: 0.62)],
        [CGPoint(x: 0.20, y: 0.72), CGPoint(x: 0.27, y: 0.80), CGPoint(x: 0.19, y: 0.87), CGPoint(x: 0.29, y: 0.98)]
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RadialGradient(colors: [NOVAControlPalette.red.opacity(0.13), .clear], center: .topTrailing, startRadius: 4, endRadius: 230)
                Canvas { context, size in
                    for bolt in bolts {
                        let path = Path { line in
                            guard let first = bolt.first else { return }
                            line.move(to: CGPoint(x: size.width * first.x, y: size.height * first.y))
                            for point in bolt.dropFirst() {
                                line.addLine(to: CGPoint(x: size.width * point.x, y: size.height * point.y))
                            }
                        }
                        context.stroke(path, with: .color(.white.opacity(0.075)), lineWidth: 1)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
    }
}
