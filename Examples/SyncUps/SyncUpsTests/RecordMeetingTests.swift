import ComposableArchitecture
import XCTest

@testable import SyncUps

@MainActor
final class RecordMeetingTests: XCTestCase {
  func testTimer() async throws {
    let clock = TestClock()
    let dismissed = self.expectation(description: "dismissed")

    let store = TestStore(
      initialState: RecordMeeting.State(
        syncUp: Shared(
          SyncUp(
            id: SyncUp.ID(),
            attendees: [
              Attendee(id: Attendee.ID()),
              Attendee(id: Attendee.ID()),
              Attendee(id: Attendee.ID()),
            ],
            duration: .seconds(6)
          )
        )
      )
    ) {
      RecordMeeting()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = Date(timeIntervalSince1970: 1234567890)
      $0.dismiss = DismissEffect {
        dismissed.fulfill()
      }
      $0.speechClient.authorizationStatus = { .denied }
      $0.uuid = .incrementing
    }

    let onTask = await store.send(.onTask)

    await clock.advance(by: .seconds(1))
    await store.receive(\.timerTick) {
      $0.speakerIndex = 0
      $0.secondsElapsed = 1
      XCTAssertEqual($0.durationRemaining, .seconds(5))
    }

    await clock.advance(by: .seconds(1))
    await store.receive(\.timerTick) {
      $0.speakerIndex = 1
      $0.secondsElapsed = 2
      XCTAssertEqual($0.durationRemaining, .seconds(4))
    }

    await clock.advance(by: .seconds(1))
    await store.receive(\.timerTick) {
      $0.speakerIndex = 1
      $0.secondsElapsed = 3
      XCTAssertEqual($0.durationRemaining, .seconds(3))
    }

    await clock.advance(by: .seconds(1))
    await store.receive(\.timerTick) {
      $0.speakerIndex = 2
      $0.secondsElapsed = 4
      XCTAssertEqual($0.durationRemaining, .seconds(2))
    }

    await clock.advance(by: .seconds(1))
    await store.receive(\.timerTick) {
      $0.speakerIndex = 2
      $0.secondsElapsed = 5
      XCTAssertEqual($0.durationRemaining, .seconds(1))
    }

    await clock.advance(by: .seconds(1))
    await store.receive(\.timerTick) {
      $0.speakerIndex = 2
      $0.secondsElapsed = 6
      $0.syncUp.meetings.insert(
        Meeting(
          id: Meeting.ID(UUID(0)),
          date: Date(timeIntervalSince1970: 1234567890),
          transcript: ""
        ),
        at: 0
      )
      XCTAssertEqual($0.durationRemaining, .seconds(0))
    }

    await self.fulfillment(of: [dismissed])
    await onTask.cancel()
  }

  func testRecordTranscript() async throws {
    let clock = TestClock()
    let dismissed = self.expectation(description: "dismissed")

    let store = TestStore(
      initialState: RecordMeeting.State(
        syncUp: Shared(
          SyncUp(
            id: SyncUp.ID(),
            attendees: [
              Attendee(id: Attendee.ID()),
              Attendee(id: Attendee.ID()),
              Attendee(id: Attendee.ID()),
            ],
            duration: .seconds(6)
          )
        )
      )
    ) {
      RecordMeeting()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = Date(timeIntervalSince1970: 1234567890)
      $0.dismiss = DismissEffect { dismissed.fulfill() }
      $0.speechClient.authorizationStatus = { .authorized }
      $0.speechClient.startTask = { @Sendable _ in
        AsyncThrowingStream { continuation in
          continuation.yield(
            SpeechRecognitionResult(
              bestTranscription: Transcription(formattedString: "I completed the project"),
              isFinal: true
            )
          )
          continuation.finish()
        }
      }
      $0.uuid = .incrementing
    }

    let onTask = await store.send(.onTask)

    await store.receive(\.speechResult) {
      $0.transcript = "I completed the project"
    }

    await store.withExhaustivity(.off(showSkippedAssertions: true)) {
      await clock.advance(by: .seconds(6))
      await store.receive(\.timerTick)
      await store.receive(\.timerTick)
      await store.receive(\.timerTick)
      await store.receive(\.timerTick)
      await store.receive(\.timerTick)
      await store.receive(\.timerTick)
    }

    XCTAssertEqual(store.state.syncUp.meetings[0].transcript, "I completed the project")
    await self.fulfillment(of: [dismissed])
    await onTask.cancel()
  }

  func testEndMeetingSave() async throws {
    let clock = TestClock()
    let dismissed = self.expectation(description: "dismissed")

    let store = TestStore(initialState: RecordMeeting.State(syncUp: Shared(.mock))) {
      RecordMeeting()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = Date(timeIntervalSince1970: 1234567890)
      $0.dismiss = DismissEffect { dismissed.fulfill() }
      $0.speechClient.authorizationStatus = { .denied }
      $0.uuid = .incrementing
    }

    let onTask = await store.send(.onTask)

    await store.send(.endMeetingButtonTapped) {
      $0.alert = .endMeeting(isDiscardable: true)
    }

    await clock.advance(by: .seconds(3))
    await store.receive(\.timerTick)
    await store.receive(\.timerTick)
    await store.receive(\.timerTick)

    await store.send(.alert(.presented(.confirmSave))) {
      $0.alert = nil
    }
    store.state.$syncUp.assert {
      $0.meetings.insert(
        Meeting(
          id: Meeting.ID(UUID(0)),
          date: Date(timeIntervalSince1970: 1234567890),
          transcript: ""
        ),
        at: 0
      )
    }

    await self.fulfillment(of: [dismissed])
    await onTask.cancel()
  }

  func testEndMeetingDiscard() async throws {
    let clock = TestClock()
    let dismissed = self.expectation(description: "dismissed")

    let store = TestStore(initialState: RecordMeeting.State(syncUp: Shared(.mock))) {
      RecordMeeting()
    } withDependencies: {
      $0.continuousClock = clock
      $0.dismiss = DismissEffect { dismissed.fulfill() }
      $0.speechClient.authorizationStatus = { .denied }
    }

    let task = await store.send(.onTask)

    await store.send(.endMeetingButtonTapped) {
      $0.alert = .endMeeting(isDiscardable: true)
    }

    await store.send(.alert(.presented(.confirmDiscard))) {
      $0.alert = nil
    }

    await self.fulfillment(of: [dismissed])
    await task.cancel()
  }

  func testNextSpeaker() async throws {
    let clock = TestClock()
    let dismissed = self.expectation(description: "dismissed")

    let store = TestStore(
      initialState: RecordMeeting.State(
        syncUp: Shared(
          SyncUp(
            id: SyncUp.ID(),
            attendees: [
              Attendee(id: Attendee.ID()),
              Attendee(id: Attendee.ID()),
              Attendee(id: Attendee.ID()),
            ],
            duration: .seconds(6)
          )
        )
      )
    ) {
      RecordMeeting()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = Date(timeIntervalSince1970: 1234567890)
      $0.dismiss = DismissEffect { dismissed.fulfill() }
      $0.speechClient.authorizationStatus = { .denied }
      $0.uuid = .incrementing
    }

    let onTask = await store.send(.onTask)

    await store.send(.nextButtonTapped) {
      $0.speakerIndex = 1
      $0.secondsElapsed = 2
    }

    await store.send(.nextButtonTapped) {
      $0.speakerIndex = 2
      $0.secondsElapsed = 4
    }

    await store.send(.nextButtonTapped) {
      $0.alert = .endMeeting(isDiscardable: false)
    }

    await store.send(.alert(.presented(.confirmSave))) {
      $0.alert = nil
    }

    store.state.$syncUp.assert {
      $0.meetings.insert(
        Meeting(
          id: Meeting.ID(UUID(0)),
          date: Date(timeIntervalSince1970: 1234567890),
          transcript: ""
        ),
        at: 0
      )
    }
    await self.fulfillment(of: [dismissed])
    await onTask.cancel()
  }

  func testSpeechRecognitionFailure_Continue() async throws {
    let clock = TestClock()
    let dismissed = self.expectation(description: "dismissed")

    let store = TestStore(
      initialState: RecordMeeting.State(
        syncUp: Shared(
          SyncUp(
            id: SyncUp.ID(),
            attendees: [
              Attendee(id: Attendee.ID()),
              Attendee(id: Attendee.ID()),
              Attendee(id: Attendee.ID()),
            ],
            duration: .seconds(6)
          )
        )
      )
    ) {
      RecordMeeting()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = Date(timeIntervalSince1970: 1234567890)
      $0.dismiss = DismissEffect { dismissed.fulfill() }
      $0.speechClient.authorizationStatus = { .authorized }
      $0.speechClient.startTask = { @Sendable _ in
        AsyncThrowingStream {
          $0.yield(
            SpeechRecognitionResult(
              bestTranscription: Transcription(formattedString: "I completed the project"),
              isFinal: true
            )
          )
          struct SpeechRecognitionFailure: Error {}
          $0.finish(throwing: SpeechRecognitionFailure())
        }
      }
      $0.uuid = .incrementing
    }

    let onTask = await store.send(.onTask)

    await store.receive(\.speechResult) {
      $0.transcript = "I completed the project"
    }

    await store.receive(\.speechFailure) {
      $0.alert = .speechRecognizerFailed
      $0.transcript = "I completed the project ❌"
    }

    await store.send(.alert(.dismiss)) {
      $0.alert = nil
    }

    await clock.advance(by: .seconds(6))

    store.exhaustivity = .off(showSkippedAssertions: true)
    await store.receive(\.timerTick)
    await store.receive(\.timerTick)
    await store.receive(\.timerTick)
    await store.receive(\.timerTick)
    await store.receive(\.timerTick)
    await store.receive(\.timerTick)
    store.exhaustivity = .on

    await self.fulfillment(of: [dismissed])
    await onTask.cancel()
  }

  func testSpeechRecognitionFailure_Discard() async throws {
    let clock = TestClock()
    let dismissed = self.expectation(description: "dismissed")

    let store = TestStore(initialState: RecordMeeting.State(syncUp: Shared(.mock))) {
      RecordMeeting()
    } withDependencies: {
      $0.continuousClock = clock
      $0.dismiss = DismissEffect { dismissed.fulfill() }
      $0.speechClient.authorizationStatus = { .authorized }
      $0.speechClient.startTask = { @Sendable _ in
        AsyncThrowingStream {
          struct SpeechRecognitionFailure: Error {}
          $0.finish(throwing: SpeechRecognitionFailure())
        }
      }
    }

    let onTask = await store.send(.onTask)

    await store.receive(\.speechFailure) {
      $0.alert = .speechRecognizerFailed
    }

    await store.send(.alert(.presented(.confirmDiscard))) {
      $0.alert = nil
    }

    await self.fulfillment(of: [dismissed])
    await onTask.cancel()
  }
}
