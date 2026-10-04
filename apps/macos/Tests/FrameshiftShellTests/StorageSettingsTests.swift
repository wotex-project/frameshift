import Foundation
import FrameshiftShell
import Testing

@Suite("Native storage budget custody")
@MainActor
struct StorageSettingsTests {
  @Test("Refresh preserves a dirty draft; concurrent configuration requires explicit reload")
  func preservesDraft() async {
    let client = StorageClient()
    let model = StorageSettingsModel(client: client)
    await model.refresh()
    model.edit("32")
    await model.refresh()
    #expect(model.draftMebibytes == "32")
    #expect(model.canSave)
    await client.changeLimit()
    await model.refresh()
    #expect(model.draftMebibytes == "32")
    #expect(model.isStale)
    await model.save()
    #expect(await client.commands().isEmpty)
    await model.refresh(discardDraft: true)
    #expect(model.draftMebibytes == "24")
    #expect(!model.hasChanges)
  }

  @Test("Acknowledgement preserves edits typed during save and advances their base revision")
  func preservesNewEdits() async throws {
    let client = StorageClient(hold: true)
    let model = StorageSettingsModel(client: client)
    await model.refresh()
    model.edit("32")
    let save = Task { await model.save() }
    await client.waitForSave()
    model.edit("64")
    await client.completeSave()
    await save.value
    #expect(model.draftMebibytes == "64")
    #expect(model.storage?.objectByteLimit == 32 * LibraryStorage.mebibyte)
    #expect(model.canSave)
    await model.save()
    let commands = await client.commands()
    #expect(commands.count == 2)
    #expect(commands[0].storageRevision == digest(1))
    #expect(commands[1].storageRevision == digest(2))
    #expect(commands[1].objectByteLimit == 64 * LibraryStorage.mebibyte)
    #expect(!model.hasChanges)
  }

  @Test("Uncertain outcomes retain the draft and require review without mutation replay")
  func refusesUnknownReplay() async {
    let client = StorageClient(unknown: true, commitBeforeUnknown: false)
    let model = StorageSettingsModel(client: client)
    await model.refresh()
    model.edit("32")
    await model.save()
    #expect(model.isStale)
    #expect(model.draftMebibytes == "32")
    await model.save()
    #expect(await client.commands().count == 1)
    await model.refresh()
    #expect(model.isStale)
    await model.save()
    #expect(await client.commands().count == 1)
    await model.refresh(discardDraft: true)
    #expect(!model.isStale)
  }

  @Test("Finite whole-MiB input and inconsistent or overflowing accounting refuse")
  func validatesBoundaries() async throws {
    let model = StorageSettingsModel(client: StorageClient())
    await model.refresh()
    for text in ["", "0", "1048577", "-1", "1.5", "1e3", " 1", "١", "999999999"] {
      model.edit(text)
      #expect(model.draftByteLimit == nil)
      #expect(!model.canSave)
    }
    model.edit("1048576")
    #expect(model.draftByteLimit == LibraryStorage.maximumLimit)
    let json = """
      {"objectByteLimit":1048576,"revision":"\(digest(1))","activeBytes":9223372036854775807,
       "trashBytes":1,"totalBytes":0,"objectCount":1,"remainingBytes":0,"overBudget":true}
      """
    let overflow = try JSONDecoder().decode(LibraryStorage.self, from: Data(json.utf8))
    #expect(throws: CoreClientError.protocolFailure) { try overflow.validate() }
    let bad = json.replacingOccurrences(of: "9223372036854775807", with: "1")
    let inconsistent = try JSONDecoder().decode(LibraryStorage.self, from: Data(bad.utf8))
    #expect(throws: CoreClientError.protocolFailure) { try inconsistent.validate() }
    let precise = LibraryStorage(objectByteLimit: 1_048_577, revision: digest(3))
    try precise.validate()
  }
}

private func digest(_ value: Int) -> String { "sha256:" + String(format: "%064x", value) }

private actor StorageClient: CoreClient {
  private var current = LibraryStorage(
    objectByteLimit: 20 * LibraryStorage.mebibyte, revision: digest(1))
  private var sent: [CoreCommand] = []
  private var hold: Bool
  private let unknown: Bool
  private let commitBeforeUnknown: Bool
  private var continuation: CheckedContinuation<Void, Never>?

  init(hold: Bool = false, unknown: Bool = false, commitBeforeUnknown: Bool = true) {
    self.hold = hold
    self.unknown = unknown
    self.commitBeforeUnknown = commitBeforeUnknown
  }

  func snapshot() -> CoreSnapshot { .disconnected }
  func snapshot(query _: String) -> CoreSnapshot { .disconnected }
  func storage() -> LibraryStorage { current }
  func commands() -> [CoreCommand] { sent }
  func changeLimit() {
    current = LibraryStorage(objectByteLimit: 24 * LibraryStorage.mebibyte, revision: digest(4))
  }
  func send(_ command: CoreCommand) async throws -> CoreSnapshot {
    sent.append(command)
    if hold {
      hold = false
      await withCheckedContinuation { continuation = $0 }
    }
    if unknown && !commitBeforeUnknown { throw CoreClientError.commandOutcomeUnknown }
    current = LibraryStorage(
      objectByteLimit: command.objectByteLimit!, revision: digest(sent.count + 1))
    if unknown { throw CoreClientError.commandOutcomeUnknown }
    var response = CoreSnapshot.disconnected
    response.updatedStorage = current
    return response
  }
  func waitForSave() async { while continuation == nil { await Task.yield() } }
  func completeSave() {
    continuation?.resume()
    continuation = nil
  }
}
