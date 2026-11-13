#if DEBUG
import Foundation

/// Read the same authoritative session flag used by DSM. Never retains the
/// configuration body, authenticated URL, account name or session credentials.
enum ChatAdministratorContractProbe {
    static func run(receipt: URL, verifyProduction: Bool = false) async -> Bool {
        var report: [String:Any] = ["scope":"Read-only administrator contract for a verified Peter account", "channel_writes":0]
        do {
            guard !FileManager.default.fileExists(atPath:receipt.path) else { return false }
            let account = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session:account.session)
            try await api.discover()
            let users = try await api.users(), channels = try await api.channels(), members = try await api.members(channelID:93)
            let target = try ChatPeterProbeTarget.resolve(username:account.username,users:users,channels:channels,members:members)
            report["owner_id"] = target.ownerID
            guard let canonicalName = users.first(where: { $0.user_id == target.ownerID })?.username, !canonicalName.isEmpty else { throw ChatAPIError.invalidResponse }
            if verifyProduction {
                let status = try await api.administratorStatus(expectedUsername: canonicalName)
                report["state"] = "production_identity_bound_contract_verified"
                report["is_administrator"] = status.isAdministrator
                report["canonical_username_exact_match"] = status.username == canonicalName
                report["strict_logged_in_validated"] = true
                try save(report,to:receipt)
                print("Production administrator reader verified; no account or channel changes.")
                return true
            }
            var request = try api.requestForCall(api:"SYNO.Core.Desktop.Initdata",method:"get_user_service",version:1)
            guard let body = request.httpBody, let fields = String(data:body,encoding:.utf8),
                  let url = request.url, var components = URLComponents(url:url,resolvingAgainstBaseURL:false) else { throw ChatAPIError.invalidResponse }
            components.percentEncodedQuery = (components.percentEncodedQuery.map { $0 + "&" } ?? "") + fields
            guard let url = components.url else { throw ChatAPIError.invalidResponse }
            request.url = url; request.httpMethod = "GET"; request.httpBody = nil
            request.setValue(nil,forHTTPHeaderField:"Content-Type")
            let data:ChatJSON = try await api.perform(request)
            guard case .object(let session) = data["Session"] else { throw ChatAPIError.invalidResponse }
            report["session_identity_field_names"] = session.keys.filter { $0.range(of:"admin|user|login|uid|name",options:[.regularExpression,.caseInsensitive]) != nil }.sorted()
            if case .bool(let value) = session["is_admin"] { report["strict_admin_flag"] = value }
            else { report["strict_admin_flag"] = "missing_or_not_boolean" }
            for key in ["user","username","login_name","login_user","user_name","account","user_id","uid"] {
                guard let value = session[key] else { continue }
                if case .string(let text) = value { report[key + "_matches_account_name"] = text == canonicalName }
                if case .integer(let number) = value { report[key + "_matches_owner_id"] = number == target.ownerID }
            }
            if case .bool(let value) = session["isLogined"] { report["strict_logged_in"] = value }
            else { report["strict_logged_in"] = "missing_or_not_boolean" }
            report["state"] = "read_only_session_flag_received"
            try save(report,to:receipt)
            print("Read-only DSM administrator flag received; no account or channel changes.")
            return true
        } catch {
            report["state"] = "unavailable_no_authority_granted"
            try? save(report,to:receipt)
            print("Read-only administrator contract unavailable; no authority granted and no account or channel changes.")
            return false
        }
    }
    private static func save(_ report:[String:Any],to file:URL) throws {
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:file,options:.withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}
#endif
