import Foundation

struct ChatLauncherApplication:Decodable,Equatable,Identifiable {
    let appname:String
    let name:String
    let description:String
    let type:String
    let launch_url:String
    let badge:Int?
    var id:String {appname}
    var valid:Bool {!appname.isEmpty && appname.utf8.count <= 256 && name.utf8.count <= 1024 && description.utf8.count <= 8192 && launch_url.utf8.count <= 8192}
    /// Only open the credential-free, same-origin application route observed in
    /// this server's launcher. Federated/other routes stay visible but unavailable.
    func launchURL(baseURL:URL)->URL? {
        guard valid,type == "local",let url = URL(string:launch_url,relativeTo:baseURL)?.absoluteURL,
              let c = URLComponents(url:url,resolvingAgainstBaseURL:false),let b = URLComponents(url:baseURL,resolvingAgainstBaseURL:false),
              c.scheme?.lowercased() == "https",b.scheme?.lowercased() == "https",c.host?.lowercased() == b.host?.lowercased(),(c.port ?? 443) == (b.port ?? 443),c.user == nil,c.password == nil,c.fragment == nil,
              c.path.isEmpty || c.path == "/",let query = c.queryItems,query.count == 1,query[0].name == "launchApp",query[0].value == appname else {return nil}
        return url
    }
}
struct ChatLauncherSnapshot {
    let applications:[ChatLauncherApplication]
    let accountGeneration:Int
}
