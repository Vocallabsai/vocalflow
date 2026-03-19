import Foundation

class KeychainService {
    func store(key: String, value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    func retrieve(key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    func delete(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
