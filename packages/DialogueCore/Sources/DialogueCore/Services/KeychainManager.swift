import Foundation
import Security

/// Manages secure storage of API keys in the macOS Keychain.
/// Uses raw Security framework APIs (no third-party dependencies).
public final class KeychainManager {
    nonisolated(unsafe) public static let shared = KeychainManager()
    
    private let service = "bot.djinn.app.dialog.ai"
    private let account = "api-key"
    
    private init() {}
    
    // MARK: - Save
    
    public func saveAPIKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        
        // Delete existing item first (update = delete + add)
        try? deleteAPIKey()
        
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
    
    // MARK: - Read
    
    public func getAPIKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.readFailed(status)
        }
    }
    
    // MARK: - Delete
    
    public func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
    
    // MARK: - Convenience
    
    public var hasAPIKey: Bool {
        (try? getAPIKey()) != nil
    }
    
    // MARK: - Voice Embedding Storage
    
    /// Save a voice embedding (raw binary data) for a named speaker profile.
    /// The account field encodes the profile type: "voice-<identifier>".
    public func saveVoiceEmbedding(_ data: Data, identifier: String) throws {
        let voiceAccount = "voice-\(identifier)"
        
        // Delete existing item first (update = delete + add)
        try? deleteVoiceEmbedding(identifier: identifier)
        
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: voiceAccount,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
    
    /// Read a voice embedding by identifier.
    public func getVoiceEmbedding(identifier: String) throws -> Data? {
        let voiceAccount = "voice-\(identifier)"
        
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: voiceAccount,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.decodingFailed
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.readFailed(status)
        }
    }
    
    /// Delete a voice embedding by identifier.
    public func deleteVoiceEmbedding(identifier: String) throws {
        let voiceAccount = "voice-\(identifier)"
        
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: voiceAccount,
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
    
    /// List all voice embedding identifiers stored in the Keychain.
    public func allVoiceEmbeddingIdentifiers() -> [String] {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String:  kSecMatchLimitAll,
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("voice-") else { return nil }
            return String(account.dropFirst("voice-".count))
        }
    }
}

// MARK: - Errors

public enum KeychainError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    
    public var errorDescription: String? {
        switch self {
        case .encodingFailed:      return "Failed to encode API key"
        case .decodingFailed:      return "Failed to decode API key from Keychain"
        case .saveFailed(let s):   return "Keychain save failed (status: \(s))"
        case .readFailed(let s):   return "Keychain read failed (status: \(s))"
        case .deleteFailed(let s): return "Keychain delete failed (status: \(s))"
        }
    }
}
