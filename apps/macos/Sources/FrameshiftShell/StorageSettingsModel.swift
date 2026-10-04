import Foundation
import Observation

public struct LibraryStorage: Codable, Equatable, Sendable {
  public static let mebibyte = 1024 * 1024
  public static let maximumLimit = 1024 * 1024 * 1024 * 1024
  public let objectByteLimit: Int
  public let revision: String
  public let activeBytes: Int
  public let trashBytes: Int
  public let totalBytes: Int
  public let objectCount: Int
  public let remainingBytes: Int
  public let overBudget: Bool

  public init(
    objectByteLimit: Int, revision: String, activeBytes: Int = 0, trashBytes: Int = 0,
    objectCount: Int = 0
  ) {
    self.objectByteLimit = objectByteLimit
    self.revision = revision
    self.activeBytes = activeBytes
    self.trashBytes = trashBytes
    let (total, overflow) = activeBytes.addingReportingOverflow(trashBytes)
    totalBytes = total
    self.objectCount = objectCount
    remainingBytes =
      !overflow && activeBytes >= 0 && trashBytes >= 0 && objectByteLimit >= 0
      ? max(0, objectByteLimit - total) : 0
    overBudget = totalBytes > objectByteLimit
  }

  public func validate() throws {
    let (total, overflow) = activeBytes.addingReportingOverflow(trashBytes)
    guard validLibraryDigest(revision),
      (Self.mebibyte...Self.maximumLimit).contains(objectByteLimit),
      activeBytes >= 0, trashBytes >= 0, objectCount >= 0, !overflow,
      totalBytes == total, remainingBytes == max(0, objectByteLimit - total),
      overBudget == (total > objectByteLimit)
    else { throw CoreClientError.protocolFailure }
  }
}

@MainActor
@Observable
public final class StorageSettingsModel {
  public private(set) var storage: LibraryStorage?
  public private(set) var draftMebibytes = ""
  public private(set) var isBusy = false
  public private(set) var isStale = false
  public private(set) var message: String?
  private var baseRevision: String?
  private var baseDraft = ""
  private var requiresReview = false
  private let client: any CoreClient

  public init(client: any CoreClient) { self.client = client }

  public func edit(_ value: String) { draftMebibytes = value }

  public var draftByteLimit: Int? {
    guard !draftMebibytes.isEmpty, draftMebibytes.utf8.count <= 7,
      draftMebibytes.utf8.allSatisfy({ (48...57).contains($0) }),
      let value = Int(draftMebibytes), (1...1_048_576).contains(value)
    else { return nil }
    return value * LibraryStorage.mebibyte
  }

  public var hasChanges: Bool { draftMebibytes != baseDraft }
  public var canSave: Bool {
    !isBusy && !isStale && baseRevision != nil && draftByteLimit != nil && hasChanges
  }

  public func refresh(discardDraft: Bool = false) async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      let next = try await client.storage()
      try next.validate()
      let preserve = baseRevision != nil && (hasChanges || requiresReview) && !discardDraft
      storage = next
      if preserve {
        isStale = requiresReview || baseRevision != next.revision
      } else {
        accept(next)
      }
      message = isStale ? "Storage settings changed. Reload and review your limit." : nil
    } catch {
      isStale = true
      message = "Storage accounting is unavailable. Refresh to try again."
    }
  }

  public func save() async {
    guard canSave, let revision = baseRevision, let limit = draftByteLimit else { return }
    let submitted = draftMebibytes
    isBusy = true
    defer { isBusy = false }
    do {
      let response = try await client.send(
        CoreCommand(kind: .updateStorage, storageRevision: revision, objectByteLimit: limit))
      guard let committed = response.updatedStorage else {
        message = "The command was already applied. Reload and review Storage settings."
        isStale = true
        requiresReview = true
        return
      }
      try committed.validate()
      guard committed.objectByteLimit == limit else { throw CoreClientError.protocolFailure }
      storage = committed
      baseRevision = committed.revision
      baseDraft = String(limit / LibraryStorage.mebibyte)
      isStale = false
      requiresReview = false
      if draftMebibytes == submitted { draftMebibytes = String(limit / LibraryStorage.mebibyte) }
      message = "Storage budget saved."
    } catch CoreClientError.storageRevisionConflict {
      isStale = true
      requiresReview = true
      message = "Storage settings changed. Reload and review your limit."
    } catch CoreClientError.commandOutcomeUnknown {
      isStale = true
      requiresReview = true
      message = "The core could not confirm this save. Reload and review before saving again."
    } catch {
      isStale = true
      requiresReview = true
      message = "Storage budget could not be saved. Refresh and review it."
    }
  }

  private func accept(_ next: LibraryStorage) {
    baseRevision = next.revision
    draftMebibytes = String(next.objectByteLimit / LibraryStorage.mebibyte)
    // A non-MiB limit remains exact until the user explicitly chooses a MiB draft.
    if next.objectByteLimit % LibraryStorage.mebibyte != 0 { draftMebibytes = "" }
    baseDraft = draftMebibytes
    isStale = false
    requiresReview = false
  }
}
