/// The app's version, shared by the server (health, MCP `serverInfo`, provenance, Bonjour TXT), the CLI and the app
/// bundle. `Tools/release.sh` refuses to build when the Xcode project's MARKETING_VERSION disagrees.
public enum ServerVersion {
    public static let current = "0.9.0"
}
