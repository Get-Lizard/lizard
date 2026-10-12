import Foundation
import Testing
@testable import LizardCore

@Suite struct AppReleaseTests {
    @Test(arguments: [("0.1.2", "0.1.1", true), ("0.1.10", "0.1.9", true), ("1.0", "0.9.9", true), ("0.1.1", "0.1.1", false),
                      ("1.0", "1.0.0", false), ("0.1.0", "0.1.1", false), ("0.2.0-beta", "0.1.9", true)])
    func comparesVersions(candidate: String, current: String, newer: Bool) {
        #expect(AppRelease.isNewer(candidate, than: current) == newer)
    }

    @Test func parsesTheLatestRelease() throws {
        let json = #"""
            {"tag_name":"v0.1.2","draft":false,"prerelease":false,"html_url":"https://github.com/Get-Lizard/lizard/releases/tag/v0.1.2",
             "body":"Updates","assets":[{"name":"Lizard-0.1.2.dmg","browser_download_url":"https://github.com/x/Lizard-0.1.2.dmg"}]}
            """#
        let release = try #require(AppRelease.parse(Data(json.utf8)))
        #expect(release.version == "0.1.2")
        #expect(release.dmgURL?.lastPathComponent == "Lizard-0.1.2.dmg")
        #expect(AppRelease.parse(Data(#"{"tag_name":"v9","prerelease":true,"html_url":"https://x.test"}"#.utf8)) == nil)
    }
}
