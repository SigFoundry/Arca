import Foundation
import LocalAuthentication
import Security

enum CredentialUnlockError: Error, LocalizedError {
    case unavailable
    case credentialMissing
    case invalidCredentialData
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return L10n.string("error.biometric.unavailable")
        case .credentialMissing:
            return L10n.string("error.biometric.missing")
        case .invalidCredentialData:
            return L10n.string("error.biometric.invalid")
        case .unexpectedStatus(let status):
            return L10n.format("error.biometric.status", status)
        }
    }
}

struct CredentialUnlockService {
    enum BiometricKind {
        case touchID
        case faceID
        case opticID
        case generic

        var buttonTitle: String {
            switch self {
            case .touchID:
                return L10n.string("locked.action.touch_id")
            case .faceID:
                return L10n.string("locked.action.face_id")
            case .opticID:
                return L10n.string("locked.action.optic_id")
            case .generic:
                return L10n.string("locked.action.biometric")
            }
        }
    }

    private let service = "com.sigcon-inc.apps.arca.biometric-unlock"
    private let account = "default-vault"

    func isRunningAsAppBundle() -> Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func biometricKind() -> BiometricKind? {
        var error: NSError?
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }

        switch context.biometryType {
        case .touchID:
            return .touchID
        case .faceID:
            return .faceID
        case .opticID:
            return .opticID
        default:
            return .generic
        }
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

    func store(password: String) throws {
        guard biometricKind() != nil else {
            throw CredentialUnlockError.unavailable
        }

        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &accessError
        ) else {
            throw accessError?.takeRetainedValue() as Error? ?? CredentialUnlockError.unavailable
        }

        let secret = Data(password.utf8)
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
            kSecValueData as String: secret
        ]

        SecItemDelete(baseQuery as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw mapStatus(status)
        }
    }

    func retrievePassword(prompt: String) throws -> String {
        guard biometricKind() != nil else {
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
                let password = String(data: data, encoding: .utf8)
            else {
                throw CredentialUnlockError.invalidCredentialData
            }
            return password
        case errSecItemNotFound:
            throw CredentialUnlockError.credentialMissing
        default:
            throw mapStatus(status)
        }
    }

    private func mapStatus(_ status: OSStatus) -> CredentialUnlockError {
        switch status {
        case errSecMissingEntitlement, errSecNotAvailable:
            return .unavailable
        default:
            return .unexpectedStatus(status)
        }
    }

    func setupMessage(hasStoredCredential: Bool) -> String {
        guard biometricKind() != nil else {
            return L10n.string("locked.biometric_unavailable_hint")
        }

        if hasStoredCredential {
            return L10n.string("locked.biometric_ready_hint")
        }

        if isRunningAsAppBundle() == false {
            return L10n.string("locked.biometric_bundle_hint")
        }

        return L10n.string("locked.biometric_hint")
    }
}
