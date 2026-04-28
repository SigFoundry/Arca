import Foundation
import LocalAuthentication
import Security

enum CredentialUnlockError: Error, LocalizedError {
    case unavailable
    case missingEntitlement
    case credentialMissing
    case invalidCredentialData
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return L10n.string("error.device_auth.unavailable")
        case .missingEntitlement:
            return L10n.string("error.device_auth.missing_entitlement")
        case .credentialMissing:
            return L10n.string("error.device_auth.missing")
        case .invalidCredentialData:
            return L10n.string("error.device_auth.invalid")
        case .unexpectedStatus(let status):
            return L10n.format("error.device_auth.status", status)
        }
    }
}

struct CredentialUnlockService {
    private let service = "com.sigcon-inc.apps.arca.device-auth-unlock"
    private let account = "default-vault"

    func isRunningAsAppBundle() -> Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func isDeviceAuthenticationAvailable() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func buttonTitle() -> String {
        L10n.string("locked.action.device_auth")
    }

    func hasStoredCredential() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func store(secret: String) throws {
        guard isDeviceAuthenticationAvailable() else {
            throw CredentialUnlockError.unavailable
        }

        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            throw accessError?.takeRetainedValue() as Error? ?? CredentialUnlockError.unavailable
        }

        let payload = Data(secret.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: accessControl,
            kSecValueData as String: payload
        ]

        SecItemDelete(baseQuery as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw mapStatus(status)
        }
    }

    func deleteStoredSecret() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    func retrieveSecret(prompt: String) throws -> String {
        guard isDeviceAuthenticationAvailable() else {
            throw CredentialUnlockError.unavailable
        }

        let context = LAContext()
        context.localizedReason = prompt

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard
                let data = item as? Data,
                let secret = String(data: data, encoding: .utf8)
            else {
                throw CredentialUnlockError.invalidCredentialData
            }
            return secret
        case errSecItemNotFound:
            throw CredentialUnlockError.credentialMissing
        default:
            throw mapStatus(status)
        }
    }

    private func mapStatus(_ status: OSStatus) -> CredentialUnlockError {
        switch status {
        case errSecMissingEntitlement:
            return .missingEntitlement
        case errSecNotAvailable:
            return .unavailable
        default:
            return .unexpectedStatus(status)
        }
    }

    func lockedScreenMessage(hasMasterPassword: Bool, hasDeviceAuthentication: Bool, hasStoredCredential: Bool) -> String {
        if hasMasterPassword && hasDeviceAuthentication {
            if isDeviceAuthenticationAvailable() == false {
                return L10n.string("locked.multiple_auth_master_only_hint")
            }
            if hasStoredCredential {
                return L10n.string("locked.multiple_auth_hint")
            }
            return L10n.string("locked.multiple_auth_master_only_hint")
        }

        if hasMasterPassword {
            return L10n.string("locked.master_password_hint")
        }

        if hasDeviceAuthentication {
            guard isDeviceAuthenticationAvailable() else {
                return L10n.string("locked.device_auth_unavailable_hint")
            }

            if hasStoredCredential {
                return L10n.string("locked.device_auth_ready_hint")
            }

            if isRunningAsAppBundle() == false {
                return L10n.string("locked.device_auth_bundle_hint")
            }

            return L10n.string("locked.device_auth_hint")
        }

        return L10n.string("locked.no_auth_methods_hint")
    }
}
