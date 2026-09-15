/// Identifies cached artwork produced only from the connected music library.
/// Missing or different versions must not reuse unprovenanced images or colours.
public nonisolated enum ArtworkPolicy {
    public static let version = 1

    /// Maximum bytes to download for a single cover image from the NAS.
    /// Bounds both the advertised Content-Length and actual received bytes.
    /// 12 MB covers high-resolution artwork while preventing memory exhaustion
    /// from maliciously large files.
    public static let maxArtworkDownloadBytes: Int64 = 12 * 1024 * 1024
}
