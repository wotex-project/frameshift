import Foundation
import FrameshiftShell
import Testing

@Suite("Shell value models")
struct ModelsTests {
  @Test("Frame media have stable human labels")
  func frameMediumLabels() {
    #expect(FrameMedium.paper.label == "Paper")
    #expect(FrameMedium.photo.label == "Photo")
    #expect(FrameMedium.pixel.label == "Pixel")
  }

  @Test("Selected target resolves only an exact durable identifier")
  func selectedTarget() {
    let paper = FrameTarget(
      id: "paper-1",
      name: "Hallway",
      medium: .paper,
      profileID: "urn:frameshift:profile:paper",
      state: .waitingForContact
    )
    let photo = FrameTarget(
      id: "photo-1",
      name: "Studio",
      medium: .photo,
      profileID: "urn:frameshift:profile:photo",
      state: .displayed
    )

    var snapshot = CoreSnapshot(
      targets: [paper, photo],
      selectedTargetID: photo.id,
      statusMessage: "Ready"
    )

    #expect(snapshot.selectedTarget == photo)

    snapshot.selectedTargetID = "missing"
    #expect(snapshot.selectedTarget == nil)
  }

  @Test("Commands preserve their identity and optional payload through Codable")
  func commandCodableRoundTrip() throws {
    let id = try #require(UUID(uuidString: "018f20d0-975c-7c4a-b38f-a2f9c6da1c4b"))
    let command = CoreCommand(
      id: id,
      kind: .queue,
      targetID: "frame-1",
      itemID: "sha256:fixture"
    )

    let encoded = try JSONEncoder().encode(command)
    let decoded = try JSONDecoder().decode(CoreCommand.self, from: encoded)

    #expect(decoded == command)
    #expect(decoded.id == id)
  }

  @Test("Profile timing and pending loop survive the core snapshot boundary")
  func playlistSnapshotRoundTrip() throws {
    let source = Data(
      """
      {"targets":[{"id":"paper-1","name":"Hallway","medium":"paper","profileID":"paper-v1","state":"waitingForContact","minimumDwellMs":180000,"recommendedDwellMs":21600000,"recommendationBasis":"provisional-profile","recommendationRevision":"frameshift-paper-e6-v1","playlist":{"status":"pending","revision":"sha256:fixture","entryCount":2,"dwellMs":21600000}}],"selectedTargetID":"paper-1","instruction":"","items":[],"generationAvailability":"notConfigured","statusMessage":"Waiting for frame"}
      """.utf8
    )

    let snapshot = try JSONDecoder().decode(CoreSnapshot.self, from: source)
    #expect(snapshot.selectedTarget?.minimumDwellMs == 180_000)
    #expect(snapshot.selectedTarget?.recommendedDwellMs == 21_600_000)
    #expect(snapshot.selectedTarget?.playlist?.status == .pending)

    let command = CoreCommand(kind: .loopPinned, targetID: "paper-1", dwellMs: 21_600_000)
    let decoded = try JSONDecoder().decode(CoreCommand.self, from: JSONEncoder().encode(command))
    #expect(decoded == command)
  }

  @Test("Every playlist member can carry its pending state in the library")
  func libraryLoopMembership() throws {
    let data = Data(
      """
      {"id":"master-2","title":"Warm study","digest":"master-2","isPinned":true,"queuedTargetID":null,"loopStatus":"pending"}
      """.utf8
    )

    let item = try JSONDecoder().decode(LibraryItem.self, from: data)
    #expect(item.loopStatus == .pending)
    #expect(item.queuedTargetID == nil)
  }

  @Test("Pending replacement retains the continuing active-loop indication")
  func replacementLoopState() throws {
    let source = Data(
      """
      {"status":"pending","revision":"sha256:fixture","entryCount":2,"dwellMs":21600000,"replacingActive":true}
      """.utf8
    )

    let playlist = try JSONDecoder().decode(FramePlaylist.self, from: source)
    #expect(playlist.replacingActive == true)
  }

  @Test("Custom interval rounds a receiver minimum up to a whole minute")
  func customIntervalMinimum() {
    #expect(LoopIntervalInput.minimumMinutes(minimumDwellMs: 180_001) == 4)
    #expect(LoopIntervalInput.dwellMilliseconds("3", minimumDwellMs: 180_001) == nil)
    #expect(LoopIntervalInput.dwellMilliseconds(" 4 ", minimumDwellMs: 180_001) == 240_000)
  }

  @Test("Custom interval rejects malformed and out-of-range input")
  func customIntervalBounds() {
    #expect(LoopIntervalInput.dwellMilliseconds("1.5", minimumDwellMs: nil) == nil)
    #expect(LoopIntervalInput.dwellMilliseconds("-3", minimumDwellMs: nil) == nil)
    #expect(LoopIntervalInput.dwellMilliseconds("525601", minimumDwellMs: nil) == nil)
    #expect(
      LoopIntervalInput.dwellMilliseconds("525600", minimumDwellMs: nil) == 31_536_000_000)
  }

  @Test("Disconnected state never invents device or generation availability")
  func disconnectedState() {
    let snapshot = CoreSnapshot.disconnected

    #expect(snapshot.targets.isEmpty)
    #expect(snapshot.selectedTargetID == nil)
    #expect(snapshot.generationAvailability == .notConfigured)
  }

  @Test("Sub-minute intervals use checked whole-integer unit conversion")
  func preciseIntervalBounds() {
    #expect(
      LoopIntervalInput.dwellMilliseconds("1501", unit: .milliseconds, minimumDwellMs: 1000) == 1501
    )
    #expect(LoopIntervalInput.dwellMilliseconds("2", unit: .seconds, minimumDwellMs: 1501) == 2000)
    #expect(LoopIntervalInput.dwellMilliseconds("1", unit: .seconds, minimumDwellMs: 1501) == nil)
    #expect(
      LoopIntervalInput.dwellMilliseconds(String(Int.max), unit: .hours, minimumDwellMs: nil) == nil
    )
    #expect(LoopIntervalInput.dwellMilliseconds("1.5", unit: .seconds, minimumDwellMs: nil) == nil)
    #expect(
      LoopIntervalInput.dwellMilliseconds("31536000000", unit: .milliseconds, minimumDwellMs: nil)
        == 31_536_000_000)
    #expect(
      LoopIntervalInput.dwellMilliseconds("31536000001", unit: .milliseconds, minimumDwellMs: nil)
        == nil)
    #expect(LoopIntervalInput.exactUnit(for: 1501) == .milliseconds)
    #expect(LoopIntervalInput.exactUnit(for: 120000) == .minutes)
  }
}
