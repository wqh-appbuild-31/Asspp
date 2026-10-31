//
//  AuthenticationService.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Foundation
import Logging

extension AppStore {
    enum AuthenticationError: Error {
        case accountNotFound
    }

    @MainActor
    func authenticate(email: String, password: String, code: String, using session: ApplePackage.Authenticator) async throws -> UserAccount {
        logger.info("starting authentication for user")
        do {
            let appleAccount = try await session.authenticate(
                email: email,
                password: password,
                code: code,
            )
            let userAccount = try save(email: email, account: appleAccount)
            // [Asspp-ent] Phase 2b: warm up on-device kbsync generation for
            // the new account in the background (asset download included), so
            // its first attested download does not pay that cost. Best-effort
            // only — failure is non-fatal: generation is retried on demand at
            // download time, and imported blobs keep working.
            if let dsid = UInt64(userAccount.account.directoryServicesIdentifier), dsid != 0 {
                let guid = Configuration.deviceIdentifier
                Task.detached(priority: .utility) {
                    await KBSyncProvider.shared.pregenerateIfNeeded(guid: guid, dsid: dsid)
                }
            }
            logger.info("authentication successful for user")
            return userAccount
        } catch {
            logger.error("authentication failed for user: \(error.localizedDescription)")
            throw error
        }
    }

    @MainActor
    @discardableResult
    func rotate(id: UserAccount.ID) async throws -> UserAccount? {
        logger.info("starting account rotation for user id: \(id)")
        guard let account = accounts.first(where: { $0.id == id }) else {
            logger.error("account not found for rotation, id: \(id)")
            throw AuthenticationError.accountNotFound
        }
        do {
            let newAppleAccount = try await ApplePackage.Authenticator.authenticate(
                email: account.account.email,
                password: account.account.password,
                code: "",
                cookies: account.account.cookie,
            )
            let updatedAccount = try save(email: account.account.email, account: newAppleAccount)
            logger.info("account rotation successful for user id: \(id)")
            return updatedAccount
        } catch {
            logger.error("account rotation failed for user id: \(id): \(error.localizedDescription)")
            throw error
        }
    }
}
