using Toybox.Application;
using Toybox.Lang;
using Toybox.Test;

// Run No Evil unit tests for the position-sync logic
// (docs/watch-position-sync-design.md). Compiled only when monkeyc is
// invoked with -t/--unit-test; excluded from app builds.
//
// To run (SDK bin on PATH, simulator running):
//   monkeyc -f monkey.jungle -d fr265s_sim -o build/tests.prg \
//       -y ../../keys/developer_key -t
//   monkeydo build/tests.prg fr265s -t
//
// or `make tests`. The tests avoid the network and the UI: every path
// that would call Communications.makeWebRequest or WatchUi.pushView is
// steered into its no-token / in-flight / prompt-pending early return,
// or driven directly through the public callbacks (pushLocal, onPushed,
// onPromptAnswer).

(:test)
module PositionSyncTests {

  const BOOK_A = "9781234567890";
  const BOOK_B = "9780987654321";

  // Reset persisted + in-memory state so each test starts deterministic.
  // Current book is BOOK_A, track 3, position 12345 s. No auth token:
  // pushLocal then stores PENDING_POSITION and returns
  // without touching the network.
  function reset() {
    Application.Properties.setValue("AUTHENTICATION_TOKEN", "");
    Application.Storage.deleteValue("PENDING_POSITION");
    Application.Storage.deleteValue("LAST_SYNCED");
    Application.Storage.deleteValue("DIVERGENCE_DECLINED");
    Application.Storage.deleteValue("AUTH_STALE");
    DataStore.setCurrentIsbn(BOOK_A);
    DataStore.setCurrentTrack(3);
    DataStore.setCurrentPosition(12345);

    var c = PositionSync.get();
    c.mInFlight = false;
    c.mPushInFlight = false;
    c.mPromptUp = false;
    c.mWaiters = [];
    c.mPromptKind = null;
    c.mPromptCloud = null;
    c.mRecentPush = false;
    // Force the offline code path (store pending, skip requests) so no
    // test can fire a real request, regardless of what AUTHENTICATION_TOKEN
    // the simulator happens to have persisted from earlier manual testing.
    c.mRequestsDisabled = true;
    c.mLastPushIsbn = null;
    c.mLastPushTrack = null;
    c.mLastPushPosSec = null;
  }

  // ------------------------------------------------------------------
  // Position comparison
  // ------------------------------------------------------------------

  (:test)
  function testIsAheadUsesTrackIndexFirst(logger as Test.Logger) as Lang.Boolean {
    reset();
    // Higher track wins regardless of seconds.
    Test.assert(PositionSync.get().isAhead(2, 0.0, 1, 9999999.0));
    Test.assert(!PositionSync.get().isAhead(1, 9999999.0, 2, 0.0));
    return true;
  }

  (:test)
  function testIsAheadEpsilonBoundary(logger as Test.Logger) as Lang.Boolean {
    reset();
    // Strictly more than EPS seconds ahead on the same track.
    Test.assert(PositionSync.get().isAhead(3, 200.0, 3, 100.0));
    Test.assertMessage(!PositionSync.get().isAhead(3, 104.9, 3, 100.0), "within EPS is not ahead");
    Test.assertMessage(!PositionSync.get().isAhead(3, 105.0, 3, 100.0), "exactly EPS is not ahead");
    Test.assert(PositionSync.get().isAhead(3, 105.01, 3, 100.0));
    return true;
  }

  (:test)
  function testIsSameSpotEpsilonBoundary(logger as Test.Logger) as Lang.Boolean {
    reset();
    Test.assert(PositionSync.get().isSameSpot(2, 100.0, 2, 104.9));
    Test.assertMessage(PositionSync.get().isSameSpot(2, 100.0, 2, 105.0), "exactly EPS is the same spot");
    Test.assertMessage(!PositionSync.get().isSameSpot(2, 100.0, 2, 105.01), "past EPS is a different spot");
    Test.assertMessage(!PositionSync.get().isSameSpot(2, 100.0, 3, 102.0), "different track is a different spot");
    return true;
  }

  (:test)
  function testFormatHms(logger as Test.Logger) as Lang.Boolean {
    reset();
    // Regression: Number/Number division may yield a Float in Monkey C,
    // so h and m must be floored explicitly — "1:02:05", never
    // "1.0347:2.08:05".
    var c = PositionSync.get();
    Test.assertEqual(c.formatHms(0.0), "0:00:00");
    Test.assertEqual(c.formatHms(59.0), "0:00:59");
    Test.assertEqual(c.formatHms(75.0), "0:01:15");
    Test.assertEqual(c.formatHms(3661.0), "1:01:01");
    Test.assertEqual(c.formatHms(3725.0), "1:02:05");
    Test.assertEqual(c.formatHms(3600.0), "1:00:00");
    return true;
  }

  (:test)
  function testLocalSnapshotUnits(logger as Test.Logger) as Lang.Boolean {
    reset();
    // Position is seconds within the track (the DataStore unit and the
    // cloud unit are the same); the snapshot carries cloud units:
    // zero-indexed track, seconds as a float.
    var snap = PositionSync.get().localSnapshot();
    Test.assert(snap != null);
    Test.assertEqual(snap["isbn"], 9781234567890l);
    Test.assertEqual(snap["track"], 3);
    Test.assertEqual(snap["seconds"], 12345.0);
    return true;
  }

  // ------------------------------------------------------------------
  // Outbound: throttling, pending positions, failure handling
  // ------------------------------------------------------------------

  (:test)
  function testPushFailureSetsPendingAndAttemptMarkers(logger as Test.Logger) as Lang.Boolean {
    reset();
    // A push attempt that cannot go out records PENDING_POSITION... and
    // the attempt markers, so the onSong tick loop won't re-fire on every
    // tick. (reset() forces the offline path, so the harness can never
    // send a real request.)
    logger.debug("AUTHENTICATION_TOKEN readback after reset: ["
      + Application.Properties.getValue("AUTHENTICATION_TOKEN") + "]");
    PositionSync.get().pushLocal();
    var pending = DataStore.getPendingPosition();
    Test.assertMessage(pending != null, "no-token push should be marked pending");
    Test.assertEqual(pending["isbn"], 9781234567890l);
    Test.assertEqual(pending["track"], 3);
    Test.assertEqual(pending["seconds"], 12345.0);

    var c = PositionSync.get();
    Test.assertEqualMessage(c.mLastPushIsbn, 9781234567890l, "attempt marker isbn");
    Test.assertEqualMessage(c.mLastPushTrack, 3, "attempt marker track");
    Test.assertEqualMessage(c.mLastPushPosSec, 12345, "attempt marker position");
    return true;
  }

  (:test)
  function testSameTrackTickDoesNotRepush(logger as Test.Logger) as Lang.Boolean {
    reset();
    // After a failed attempt, ticks on the same track within
    // PUSH_INTERVAL_S must not fire another push (throttle holds across failures)
    var c = PositionSync.get();
    c.pushLocal();                          // markers + pending at 12345.0 s
    DataStore.setCurrentPosition(12845);    // +5 s on the same track
    c.onPositionUpdate(3, 12845);
    Test.assertEqual(DataStore.getPendingPosition()["seconds"], 12345.0);
    return true;
  }

  (:test)
  function testTickPastIntervalPushes(logger as Test.Logger) as Lang.Boolean {
    reset();
    // The 10-minute mid-track interval is a legitimate retry trigger:
    // PUSH_INTERVAL_S of progress fires the next attempt.
    var c = PositionSync.get();
    c.pushLocal();                          // markers + pending at 12345.0 s
    DataStore.setCurrentPosition(12945);    // +600 s = PUSH_INTERVAL_S
    c.onPositionUpdate(3, 12945);
    Test.assertEqual(DataStore.getPendingPosition()["seconds"], 12945.0);
    return true;
  }

  (:test)
  function testBookChangeTriggersPush(logger as Test.Logger) as Lang.Boolean {
    reset();
    // Switching books must re-sync even when the new book's track index
    // coincides with the old one's (markers key on isbn + track).
    var c = PositionSync.get();
    c.pushLocal();                         // BOOK_A track 3 markers
    DataStore.setCurrentIsbn(BOOK_B);
    DataStore.setCurrentTrack(3);
    DataStore.setCurrentPosition(500);
    c.onPositionUpdate(3, 500);
    var pending = DataStore.getPendingPosition();
    Test.assertMessage(pending != null, "book change should push");
    Test.assertEqualMessage(pending["isbn"], 9780987654321l, "pending must track the new book");
    Test.assertEqual(pending["seconds"], 500.0);
    return true;
  }

  (:test)
  function testOnPushed401SetsAuthStaleAndPending(logger as Test.Logger) as Lang.Boolean {
    reset();
    // 401/403 surfaces as the AUTH_STALE hint; the position stays pending.
    PositionSync.get().onPushed(401, null);
    Test.assertMessage(DataStore.getAuthStale(), "401 must mark auth stale");
    Test.assertMessage(DataStore.getPendingPosition() != null, "401 push must stay pending");
    Test.assertMessage(!PositionSync.get().mPushInFlight, "push flag must clear");
    return true;
  }

  (:test)
  function testOnPushedSuccessStoresLastSynced(logger as Test.Logger) as Lang.Boolean {
    reset();
    // A successful push clears the pending position, records the cloud
    // echo as LAST_SYNCED (no re-read needed), and arms the read
    // suppression window.
    var c = PositionSync.get();
    c.onPushed(200, { "changed_at" => "2026-09-15T13:44:12.345Z" });
    Test.assertMessage(!DataStore.getAuthStale(), "success must clear auth stale");
    Test.assertMessage(DataStore.getPendingPosition() == null, "success must clear pending");
    var synced = DataStore.getLastSynced();
    Test.assertMessage(synced != null, "LAST_SYNCED must be recorded");
    Test.assertEqual(synced["changed_at"], "2026-09-15T13:44:12.345Z");
    Test.assertEqual(synced["track"], 3);
    Test.assertMessage(c.mRecentPush, "read-after-push suppression must arm");
    return true;
  }

  (:test)
  function testOnPositionUpdateClearsDeclinedInFlightGate(logger as Test.Logger) as Lang.Boolean {
    reset();
    // Any onSong update clears a previous divergence decline, and an
    // in-flight push gates further pushes entirely.
    DataStore.setDivergenceDeclined(true);
    var c = PositionSync.get();
    c.mPushInFlight = true;
    c.onPositionUpdate(3, 12345);
    Test.assertMessage(!DataStore.getDivergenceDeclined(), "tick must clear the declined flag");
    Test.assertMessage(DataStore.getPendingPosition() == null, "no push while one is in flight");
    return true;
  }

  (:test)
  function testOnPositionUpdateIgnoresPlaybackPosition(logger as Test.Logger) as Lang.Boolean {
    reset();
    // PlaybackPosition objects carry structure we don't parse; the next
    // Number-valued tick will sync. Must not throw or push.
    PositionSync.get().onPositionUpdate(3, { "track" => 3 });
    Test.assertMessage(DataStore.getPendingPosition() == null, "non-Number tick must not push");
    return true;
  }

  // ------------------------------------------------------------------
  // Pending-position plumbing
  // ------------------------------------------------------------------

  (:test)
  function testFlushPendingDropsStaleBook(logger as Test.Logger) as Lang.Boolean {
    reset();
    // A pending entry for a book that is no longer current is dropped,
    // not pushed (it can never match the current DataStore state).
    DataStore.setPendingPosition({
      "isbn" => 9780987654321l,
      "track" => 1,
      "seconds" => 10.0,
      "changed_at" => null
    });
    PositionSync.get().flushPending();
    Test.assertMessage(DataStore.getPendingPosition() == null, "stale pending must be dropped");
    return true;
  }

  (:test)
  function testFlushPendingRetriesCurrentBook(logger as Test.Logger) as Lang.Boolean {
    reset();
    // A pending position for the current book is retried immediately; with
    // no token it stays pending and the attempt markers move to the retry.
    DataStore.setCurrentPosition(990); // 990.0 s
    DataStore.setPendingPosition({
      "isbn" => 9781234567890l,
      "track" => 3,
      "seconds" => 200.0,
      "changed_at" => null
    });
    var c = PositionSync.get();
    c.flushPending();
    var pending = DataStore.getPendingPosition();
    Test.assertMessage(pending != null, "current-book pending must survive a retry");
    Test.assertEqualMessage(pending["seconds"], 990.0, "retry must carry the fresh position");
    Test.assertEqualMessage(c.mLastPushPosSec, 990, "retry must update the attempt marker");
    return true;
  }

  // ------------------------------------------------------------------
  // Waiter mechanics (fix: Array.remove returns a Boolean, so waiters are
  // popped by object before invoke)
  // ------------------------------------------------------------------

  (:test)
  function testWaitersDeferredToPendingPrompt(logger as Test.Logger) as Lang.Boolean {
    reset();
    // While a divergence prompt is up, a pre-playback request is queued
    // and resolved from the prompt's answer — playback must not
    // start (or the check be lost) in between.
    var c = PositionSync.get();
    c.mPromptUp = true;
    c.mRecentPush = true; // observable through readAfterPushExpired
    c.playWithCheck(c.method(:readAfterPushExpired));
    Test.assertEqualMessage(c.mWaiters.size(), 1, "continuation must be queued behind the prompt");

    c.onPromptAnswer(false); // decline keeps local, drains waiters
    Test.assertEqualMessage(c.mWaiters.size(), 0, "prompt answer must drain waiters");
    Test.assertMessage(!c.mRecentPush, "queued continuation must have run after the prompt");
    return true;
  }

  (:test)
  function testPropertiesTokenReadback(logger as Test.Logger) as Lang.Boolean {
    // Diagnostic/guard: the pushLocal() tests rely on reset() being able to
    // force the no-token path. On the first suite run the token did not
    // read back as "" after setValue("", ") — this test pins down whether
    // Properties writes round-trip inside the unit-test harness. A failure
    // here means the simulator has a persisted token that setValue("")
    // does not clear (harmless to the suite: mRequestsDisabled covers it).
    Application.Properties.setValue("AUTHENTICATION_TOKEN", "");
    var readBack = Application.Properties.getValue("AUTHENTICATION_TOKEN");
    logger.debug("Properties readback of cleared token: [" + readBack + "]");
    Test.assertEqualMessage(readBack, "",
      "setValue(key, \"\") must read back as \"\"");
    Application.Properties.setValue("AUTHENTICATION_TOKEN", "probe");
    Test.assertEqual(Application.Properties.getValue("AUTHENTICATION_TOKEN"), "probe");
    Application.Properties.setValue("AUTHENTICATION_TOKEN", "");
    return true;
  }

  // ------------------------------------------------------------------
  // Persisted state round trips
  // ------------------------------------------------------------------

  (:test)
  function testStorageRoundTrip(logger as Test.Logger) as Lang.Boolean {
    reset();
    var pos = { "isbn" => 9781234567890l, "track" => 2, "seconds" => 12.5, "changed_at" => null };
    DataStore.setPendingPosition(pos);
    Test.assert(DataStore.getPendingPosition() != null);
    Test.assertEqual(DataStore.getPendingPosition()["seconds"], 12.5);

    var synced = { "isbn" => 9781234567890l, "track" => 2, "seconds" => 12.5, "changed_at" => "2026-09-15T13:44:12.345Z" };
    DataStore.setLastSynced(synced);
    Test.assertEqual(DataStore.getLastSynced()["changed_at"], "2026-09-15T13:44:12.345Z");

    DataStore.setDivergenceDeclined(true);
    Test.assert(DataStore.getDivergenceDeclined());
    DataStore.setDivergenceDeclined(false);
    Test.assert(!DataStore.getDivergenceDeclined());

    DataStore.setAuthStale(true);
    Test.assert(DataStore.getAuthStale());

    DataStore.setPendingPosition(null);
    Test.assertMessage(DataStore.getPendingPosition() == null, "clearing pending must delete the key");
    return true;
  }
}
