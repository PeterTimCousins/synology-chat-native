#if DEBUG
import CryptoKit
import Foundation

/// Foundation-only process proof. No application/window, account or Keychain
/// initialization occurs; this entry exits before normal app startup.
enum NativeLocalizationBundleProbe {
    static func run(output:URL)->Bool {
        do {
            let env = ProcessInfo.processInfo.environment
            guard env["PACKAGE_RESOURCE_BUNDLE_PATH"] == nil,env["PACKAGE_RESOURCE_BUNDLE_URL"] == nil,
                  Bundle.main.bundleURL.pathExtension == "app",let root = Bundle.main.resourceURL else { return false }
            let resources = NativeLocalizedStrings.resourceBundle
            let resourceParts = resources.bundleURL.resolvingSymlinksInPath().pathComponents
            guard resourceParts.starts(with:root.resolvingSymlinksInPath().pathComponents),
                  let moduleEnglish = resources.url(forResource:"en",withExtension:"lproj")?.appendingPathComponent("Localizable.strings"),
                  let mainEnglish = Bundle.main.url(forResource:"en",withExtension:"lproj")?.appendingPathComponent("Localizable.strings") else { return false }
            let moduleData = try Data(contentsOf:moduleEnglish),mainData = try Data(contentsOf:mainEnglish)
            let modulePlural = moduleEnglish.deletingLastPathComponent().appendingPathComponent("Localizable.stringsdict")
            let mainPlural = mainEnglish.deletingLastPathComponent().appendingPathComponent("Localizable.stringsdict")
            let modulePluralData = try Data(contentsOf:modulePlural),mainPluralData = try Data(contentsOf:mainPlural)
            guard moduleData == mainData,!moduleData.isEmpty,
                  modulePluralData == mainPluralData,!modulePluralData.isEmpty,
                  NativeLocalizedStrings.text("native.app.name",language:.english) == "Chat Native",
                  NativeLocalizedStrings.text("native.app.name",language:.english,bundle:.main) == "Chat Native",
                  NativeLocalizedStrings.text("native.app.name",language:.german,bundle:.main) == "Chat Native",
                  NativeLocalizedStrings.count("%lld replies",1,language:.english) == "1 reply",
                  NativeLocalizedStrings.count("%lld replies",2,language:.english) == "2 replies",
                  NativeLocalizedStrings.count("%lld replies",1,language:.russian,bundle:.main) == "1 reply",
                  NativeLocalizedStrings.count("%lld replies",2,language:.russian,bundle:.main) == "2 replies",
                  NativeLocalizedStrings.object("About %@","Chat Native",language:.english) == "About Chat Native",
                  NativeLocalizedStrings.object("Open “%@”?","100% %@ 日本語.txt",language:.english,bundle:.main) == "Open “100% %@ 日本語.txt”?",
                  NativeLocalizedStrings.objects("%@, %@","Peter 100% %@","2 unread 日本語",language:.english,bundle:.main) == "Peter 100% %@, 2 unread 日本語",
                  ChatSignInError.rejected(119).errorDescription == "Sign-in was rejected by the server (119).",
                  NativeMenuText(native:false,language:.german,bundle:nil).application("Quit %@",name:"Synology Chat Native") == "Quit Synology Chat Native" else { return false }
            let hash = SHA256.hash(data:mainData).map { String(format:"%02x",$0) }.joined()
            let pluralHash = SHA256.hash(data:mainPluralData).map { String(format:"%02x",$0) }.joined()
            let result:[String:Any] = ["synthetic_only":true,"app":Bundle.main.bundleURL.path,"module_bundle":resources.bundleURL.path,
                "module_within_packaged_resources":true,"catalog_sha256":hash,"main_module_bytes_equal":true,
                "packaged_localizations":Bundle.main.localizations.sorted(),"lookup_key":"native.app.name","main_value":"Chat Native","module_value":"Chat Native",
                "unshipped_target_fallback":"Chat Native","normal_startup_invoked":false,
                "plural_catalog_sha256":pluralHash,"plural_main_module_bytes_equal":true,
                "module_count_values":["1 reply","2 replies"],"unshipped_target_main_count_fallback":["1 reply","2 replies"],
                "object_template_name_verbatim":true,"two_object_template_values_verbatim":true,
                "auth_rejected_code_preserved":119,"wrapper_menu_without_resource_argument":true]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.withoutOverwriting)
            return true
        } catch { return false }
    }
}
#endif
