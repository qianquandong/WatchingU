import Foundation
import Combine
import UIKit
import GoogleSignIn

/// Google handles interactive OAuth and Keychain token storage. No client secret is embedded.
@MainActor
final class DriveConnection: ObservableObject {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    @Published private(set) var accountLabel = "尚未连接 Google Drive"
    @Published private(set) var accountID: String?
    var configured: Bool {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String else { return false }
        return id.hasSuffix(".apps.googleusercontent.com") && !id.hasPrefix("configure")
    }
    init() {
        if configured, let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: id)
        }
    }
    private func update(_ user: GIDGoogleUser) throws {
        guard let id = user.userID, user.grantedScopes?.contains(Self.scope) == true else {
            throw CloudArchiveError.signInRequired
        }
        accountID = id; accountLabel = user.profile?.email ?? "Google Drive 已连接"
    }
    func restore() async throws {
        guard configured else { throw CloudArchiveError.setupRequired }
        let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
        try update(user)
    }
    func connect() async throws {
        guard configured else { throw CloudArchiveError.setupRequired }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow),
              var presenting = window.rootViewController else { throw CloudArchiveError.invalidResponse }
        while let next = presenting.presentedViewController { presenting = next }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting,
                                                             hint: nil, additionalScopes: [Self.scope])
        try update(result.user)
    }
    func access(expectedAccount: String? = nil) async throws -> (token: String, account: String) {
        if GIDSignIn.sharedInstance.currentUser == nil { try await restore() }
        guard let current = GIDSignIn.sharedInstance.currentUser else { throw CloudArchiveError.signInRequired }
        let user = try await current.refreshTokensIfNeeded()
        try update(user)
        guard let id = user.userID else { throw CloudArchiveError.signInRequired }
        if let expectedAccount = expectedAccount, expectedAccount != id { throw CloudArchiveError.accountChanged }
        return (user.accessToken.tokenString, id)
    }
    func signOut() {
        GIDSignIn.sharedInstance.signOut(); accountID = nil; accountLabel = "尚未连接 Google Drive"
    }
}

@MainActor
final class DriveAPI {
    let connection: DriveConnection
    init(connection: DriveConnection) { self.connection = connection }
    private let base = "https://www.googleapis.com/drive/v3/"
    static let fields = "id,size,sha256Checksum,trashed"
    private func call(_ url: URL, method: String = "GET", body: [String: Any]? = nil,
                      headers: [String: String] = [:], account: String) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let auth = try await connection.access(expectedAccount: account)
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 25
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        if let body = body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type") }
        for (key,value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data,response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudArchiveError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw CloudArchiveError.http(response.statusCode) }
        return (data,response)
    }
    private func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: base + path)!
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }
    func generateID(account: String) async throws -> String {
        struct IDs: Decodable { let ids: [String] }
        let (data,_) = try await call(url("files/generateIds", [.init(name: "count", value: "1"), .init(name: "space", value: "drive")]), account: account)
        guard let id = try JSONDecoder().decode(IDs.self, from: data).ids.first else { throw CloudArchiveError.invalidResponse }
        return id
    }
    func file(_ id: String, account: String) async throws -> DriveFile? {
        do {
            let (data,_) = try await call(url("files/"+id, [.init(name: "fields", value: Self.fields)]), account: account)
            return try JSONDecoder().decode(DriveFile.self, from: data)
        } catch CloudArchiveError.http(404) { return nil }
    }
    func folder(day: String?, account: String) async throws -> String {
        let root = try await findOrCreateFolder(key: "root-v1", name: "DayTape", parent: nil, account: account)
        guard let day = day else { return root }
        return try await findOrCreateFolder(key: "day-"+day, name: day, parent: root, account: account)
    }
    private func findOrCreateFolder(key: String, name: String, parent: String?, account: String) async throws -> String {
        struct Files: Decodable { let files: [Item]; struct Item: Decodable { let id: String } }
        var query = "trashed = false and mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='daytapeFolder' and value='\(key)' }"
        if let parent = parent { query += " and '\(parent)' in parents" }
        let (data,_) = try await call(url("files", [.init(name: "q", value: query), .init(name: "spaces", value: "drive"), .init(name: "fields", value: "files(id)")]), account: account)
        if let found = try JSONDecoder().decode(Files.self, from: data).files.first { return found.id }
        let id = try await generateID(account: account)
        var body: [String:Any] = ["id":id,"name":name,"mimeType":"application/vnd.google-apps.folder","appProperties":["daytapeFolder":key]]
        if let parent = parent { body["parents"] = [parent] }
        _ = try await call(url("files"), method: "POST", body: body, account: account)
        return id
    }
    func begin(_ artifact: UploadArtifact, job: ArchiveJob) async throws -> URL {
        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
        components.queryItems = [.init(name: "uploadType", value: "resumable"), .init(name: "fields", value: Self.fields)]
        let (_,response) = try await call(components.url!, method: "POST", body: [
            "id": artifact.fileID, "name": artifact.localName, "mimeType": artifact.mimeType,
            "parents": [job.folderID], "appProperties": ["daytapeClipID":job.clipID.uuidString]
        ], headers: ["X-Upload-Content-Type":artifact.mimeType,"X-Upload-Content-Length":String(artifact.byteCount)], account: job.accountID)
        guard let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location),
              url.scheme == "https", url.host == "www.googleapis.com" else { throw CloudArchiveError.invalidResponse }
        return url
    }
}
