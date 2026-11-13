import Foundation

/// An authenticated DSM session flag, bound to the exact canonical login name.
/// Unknown, malformed and unauthenticated responses never become a positive grant.
struct ChatAdministratorStatus: Equatable {
    let username: String
    let isAdministrator: Bool
}

extension ChatAPIClient {
    func administratorStatus(expectedUsername: String) async throws -> ChatAdministratorStatus {
        guard !expectedUsername.isEmpty else { throw ChatAPIError.invalidResponse }
        try Task.checkCancellation()
        let api = "SYNO.Core.Desktop.Initdata"
        var request = try requestForCall(api: api, method: "get_user_service", version: 1)
        guard let originalURL = request.url, var url = URLComponents(url: originalURL, resolvingAgainstBaseURL: false),
              let body = request.httpBody, let encoded = String(data: body, encoding: .utf8) else { throw ChatAPIError.invalidResponse }
        var form = URLComponents(); form.percentEncodedQuery = encoded
        guard let fields = form.queryItems, fields.count == 3,
              Set(fields.map(\.name)) == Set(["api", "method", "version"]),
              fields.first(where: { $0.name == "api" })?.value == api,
              fields.first(where: { $0.name == "method" })?.value == "get_user_service",
              fields.first(where: { $0.name == "version" })?.value == "1" else { throw ChatAPIError.invalidResponse }
        // Retain the authenticated query from the normal request builder; move
        // only its routing fields into the GET query. No launch_app or writes.
        url.queryItems = (url.queryItems ?? []) + fields
        guard let destination = url.url else { throw ChatAPIError.invalidResponse }
        request.url = destination; request.httpMethod = "GET"
        request.httpBody = nil; request.httpBodyStream = nil
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        request.setValue(nil, forHTTPHeaderField: "Content-Length")
        struct Result: Decodable {
            struct SessionFields: Decodable {
                let user: String
                let isLogined: Bool
                let is_admin: Bool
            }
            let Session: SessionFields
        }
        let result: Result = try await perform(request)
        try Task.checkCancellation()
        guard result.Session.isLogined, result.Session.user == expectedUsername else { throw ChatAPIError.invalidResponse }
        return .init(username: result.Session.user, isAdministrator: result.Session.is_admin)
    }
}
