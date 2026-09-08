import Foundation

enum SyncStatus: Int, Codable {
    case idle
    case syncing
    case success
    case failed
}
