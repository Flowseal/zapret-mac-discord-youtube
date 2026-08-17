import Foundation

struct Strategy: Identifiable, Hashable {
    let id: String
    let name: String
}

enum IPSetMode: String, CaseIterable, Identifiable {
    case none
    case loaded
    case any

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .loaded: "Loaded"
        case .any: "Any"
        }
    }

    var subtitle: String {
        switch self {
        case .none: "Без дополнительного обхода по IP"
        case .loaded: "Использует ipset-all.txt"
        case .any: "IP-профили для всех IPv4, кроме исключений"
        }
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

struct GitHubReleaseAsset: Decodable {
    let name: String
    let downloadURL: URL
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case digest
    }
}
