/// Vector spaces are intentionally explicit because vectors produced by
/// different model families must never be compared with each other.
enum EmbeddingSpace { bertText, mobileClip, clap }

enum EmbeddingModality { text, image, audio }
