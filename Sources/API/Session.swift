import Foundation
import Security
import WebKit

/// The OAuth token lives in the keychain; a sideloaded build whose signing left the keychain
/// unusable falls back to UserDefaults inside the app's own sandbox.
enum Keychain {
    private static let service = "nimbus.soundcloud"
    private static let account = "oauth_token"
    private static let fallbackKey = "nimbus.token.fallback"

    static var token: String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8) {
            return s
        }
        return UserDefaults.standard.string(forKey: fallbackKey)
    }

    static func setToken(_ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(value, forKey: fallbackKey)
        }
    }
}

@MainActor
final class Session: ObservableObject {
    static let shared = Session()

    @Published private(set) var loggedIn = Keychain.token != nil
    @Published private(set) var me: SCUser?
    @Published private(set) var likedIds: Set<Int> = []
    @Published private(set) var followingIds: Set<Int> = []
    @Published var message: String?

    func login(token: String) async {
        Keychain.setToken(token)
        loggedIn = true
        await refresh()
    }

    func logout() {
        Keychain.setToken(nil)
        loggedIn = false
        me = nil
        likedIds = []
        followingIds = []
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    func refresh() async {
        guard loggedIn else { return }
        do {
            me = try await SCClient.shared.me()
            if let ids = try? await SCClient.shared.likedTrackIds() {
                likedIds = Set(ids)
            }
            if let ids = try? await SCClient.shared.followingIds() {
                followingIds = Set(ids)
            }
        } catch let e as SCError {
            if case .notLoggedIn = e {
                logout()
                message = "Сессия SoundCloud истекла, войди заново"
            }
        } catch {}
    }

    func isLiked(_ t: SCTrack) -> Bool { likedIds.contains(t.id) }

    func toggleLike(_ t: SCTrack) {
        guard let uid = me?.id else {
            message = "Войди в аккаунт, чтобы ставить лайки"
            return
        }
        let on = !likedIds.contains(t.id)
        if on { likedIds.insert(t.id) } else { likedIds.remove(t.id) }
        Task {
            do {
                try await SCClient.shared.setLike(trackId: t.id, userId: uid, on: on)
            } catch {
                if on { likedIds.remove(t.id) } else { likedIds.insert(t.id) }
                message = error.localizedDescription
            }
        }
    }

    func toggleFollow(_ u: SCUser) {
        guard loggedIn else {
            message = "Войди в аккаунт, чтобы подписываться"
            return
        }
        let on = !followingIds.contains(u.id)
        if on { followingIds.insert(u.id) } else { followingIds.remove(u.id) }
        Task {
            do {
                try await SCClient.shared.setFollow(userId: u.id, on: on)
            } catch {
                if on { followingIds.remove(u.id) } else { followingIds.insert(u.id) }
                message = error.localizedDescription
            }
        }
    }
}
