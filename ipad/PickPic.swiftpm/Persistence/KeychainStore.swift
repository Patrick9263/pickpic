import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case invalidStoredData
    case unexpectedStatus(OSStatus)
    
    var errorDescription: String? {
        switch self {
        case .invalidStoredData:
            return "The stored credential could not be read."
            
        case let .unexpectedStatus(status):
            let systemMessage =
            SecCopyErrorMessageString(status, nil) as String?
            
            return systemMessage
            ?? "Keychain operation failed with status \(status)."
        }
    }
}

enum KeychainStore {
    private static let service =
    "com.patricksmith.pickpic.cloudflare-access"
    
    static func string(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &item
        )
        
        if status == errSecItemNotFound {
            return nil
        }
        
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        
        guard
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainStoreError.invalidStoredData
        }
        
        return value
    }
    
    static func set(
        _ value: String,
        for account: String
    ) throws {
        let valueData = Data(value.utf8)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let update: [String: Any] = [
            kSecValueData as String: valueData
        ]
        
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            update as CFDictionary
        )
        
        if updateStatus == errSecSuccess {
            return
        }
        
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }
        
        var newItem = query
        newItem[kSecValueData as String] = valueData
        newItem[kSecAttrAccessible as String] =
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        
        let addStatus = SecItemAdd(
            newItem as CFDictionary,
            nil
        )
        
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }
}
