import Foundation
import LocalAuthentication
import Security

/// 仅用于把旧版本留在 macOS Keychain 中的 API Key 一次性迁回本地数据库。
public protocol ModelSourceAPIKeyStore: Sendable {
    func apiKey(for reference: String) throws -> String?
    func setAPIKey(_ apiKey: String, for reference: String) throws
    func removeAPIKey(for reference: String) throws
}

public enum ModelSourceAPIKeyStoreError: Error, Equatable, LocalizedError, Sendable {
    case readFailed(status: Int32)
    case writeFailed(status: Int32)
    case removeFailed(status: Int32)
    case invalidStoredValue

    public var errorDescription: String? {
        switch self {
        case let .readFailed(status):
            "Keychain 读取失败（\(status)）"
        case let .writeFailed(status):
            "Keychain 写入失败（\(status)）"
        case let .removeFailed(status):
            "Keychain 删除失败（\(status)）"
        case .invalidStoredValue:
            "Keychain 中的 API Key 格式无效"
        }
    }
}

public struct KeychainModelSourceAPIKeyStore: ModelSourceAPIKeyStore {
    public static let defaultService = "com.aitingji.model-source-api-key"

    private let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func apiKey(for reference: String) throws -> String? {
        var query = baseQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // 旧 Key 迁移不得弹出认证窗口；无法静默读取时由用户在模型配置中重新录入一次。
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let apiKey = String(data: data, encoding: .utf8)
            else {
                throw ModelSourceAPIKeyStoreError.invalidStoredValue
            }
            return apiKey
        case errSecItemNotFound:
            return nil
        default:
            throw ModelSourceAPIKeyStoreError.readFailed(status: status)
        }
    }

    public func setAPIKey(_ apiKey: String, for reference: String) throws {
        if apiKey.isEmpty {
            try removeAPIKey(for: reference)
            return
        }

        let query = baseQuery(reference: reference)
        let attributes = [kSecValueData as String: Data(apiKey.utf8)] as CFDictionary
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = Data(apiKey.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ModelSourceAPIKeyStoreError.writeFailed(status: addStatus)
            }
        default:
            throw ModelSourceAPIKeyStoreError.writeFailed(status: updateStatus)
        }
    }

    public func removeAPIKey(for reference: String) throws {
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ModelSourceAPIKeyStoreError.removeFailed(status: status)
        }
    }

    private func baseQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference
        ]
    }
}
