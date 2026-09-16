using Toybox.Application;
using Toybox.PersistedContent;
using Toybox.Communications;
using Toybox.Lang;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

// How far apart two positions must be (seconds) to count as different.
const POSITION_EPS = 5.0;
// Listening time between cloud pushes while a track plays (seconds).
const PUSH_INTERVAL_S = 600;
// libro.fm takes ~10s to surface writes in reads (see docs/watch-position-sync-design.md);
// don't re-read the cloud right after a successful push.
const READ_AFTER_PUSH_MS = 15000;

// Async Yes/No prompt (WatchUi.Confirmation is asynchronous; there is no
// synchronous confirm() in the Connect IQ API). Hands the answer back to
// the PositionSync coordinator.
class PositionSyncPromptDelegate extends WatchUi.ConfirmationDelegate {
  function initialize() {
    ConfirmationDelegate.initialize();
  }

  function onResponse(response as WatchUi.Confirm) as Lang.Boolean {
    // The Confirmation dialog dismisses itself when an option is selected
    // (Garmin's own ConfirmationDialog sample pops nothing here); popping
    // again would close whatever view sits beneath the dialog.
    PositionSync.onPromptAnswer(response != WatchUi.CONFIRM_NO);
    return response != WatchUi.CONFIRM_NO;
  }
}

// Implements the position-sync rules from docs/watch-position-sync-design.md:
//
// - Outbound: throttled silent pushes of the current book's position
//   from onSong ticks; a failed push becomes PENDING_POSITION and retries
//   at the next trigger point (app open, pre-playback, explicit sync, app
//   stop).
// - Inbound: a check at app open and again before playback starts.
//   Direction of divergence comes from comparing listening positions
//   (track_index, track_seconds) lexicographically — never from
//   changed_at, because an offline watch always loses the wall-clock race.
// - Prompts: shown only when there is evidence another device wrote
//   the cloud record. "Rewind to cloud time?" adopts the cloud position;
//   declining keeps the watch position and pushes it up. "Fast forward to
//   cloud time?" adopts the cloud position; declining keeps local and
//   suppresses re-prompting until the local position moves.
class PositionSyncCoordinator {
  var mInFlight = false;      // a cloud read is running
  var mPushInFlight = false;  // a cloud write is running
  var mPromptUp = false;      // an async prompt is on screen
  var mWaiters = [];          // Lang.Methods waiting on the in-flight check
  var mPromptKind = null;     // "rewind" or "forward"
  var mPromptCloud = null;    // the cloud snapshot being offered
  var mRecentPush = false;    // a push succeeded < READ_AFTER_PUSH_MS ago
  var mRecentPushTimer = null;
  var mLastPushIsbn as Lang.Long? = null;
  var mLastPushTrack as Lang.Number? = null;
  var mLastPushPosSec as Lang.Number? = null;
  // Unit tests flip this to force the offline path (store pending instead
  // of sending, skip reads); production leaves it false. Same code path
  // the app takes when the phone is out of range.
  var mRequestsDisabled = false;

  function initialize() {
    mRecentPushTimer = new Timer.Timer();
  }

  // Gate expiry callback: the cloud has had time to surface our write.
  function readAfterPushExpired() as Void {
    mRecentPush = false;
  }

  // ------------------------------------------------------------------
  // Snapshots & comparison
  // ------------------------------------------------------------------

  // The current book's position as a cloud-unit snapshot, or null when
  // there's no current book / position (e.g. PlaybackPosition objects).
  // DataStore's position is seconds within the track (see DataStore
  // CURRENT_POSITION), which is already the cloud unit.
  function localSnapshot() as Lang.Dictionary? {
    var isbn = DataStore.getCurrentIsbn();
    var pos = DataStore.getCurrentPosition();
    if (isbn == null || !(pos instanceof Lang.Number)) {
      return null;
    }
    return {
      "isbn" => isbn,
      "track" => DataStore.getCurrentTrack(),
      // No /1000: DataStore's CURRENT_POSITION is seconds, not ms.
      "seconds" => (pos as Lang.Number).toFloat(),
      "changed_at" => null
    };
  }

  function isSameSpot(trackA, secA, trackB, secB) as Lang.Boolean {
    return trackA == trackB && (secA - secB).abs() <= POSITION_EPS;
  }

  // Is (trackA, secA) strictly further ahead than (trackB, secB)?
  function isAhead(trackA, secA, trackB, secB) as Lang.Boolean {
    if (trackA > trackB) {
      return true;
    }
    if (trackA < trackB) {
      return false;
    }
    return secA > secB + POSITION_EPS;
  }

  // h:mm:ss, for prompt strings. Number/Number division in Monkey C returns
  // a Float when the quotient is not exact (Toybox.Lang docs), so floor
  // explicitly: h/m must never stringify with decimals.
  function formatHms(seconds) as Lang.String {
    var total = seconds.toFloat().abs().toNumber();
    var h = (total / 3600).toNumber();
    var m = ((total % 3600) / 60).toNumber();
    var s = total % 60;
    return h + ":" + m.format("%02d") + ":" + s.format("%02d");
  }

  // ------------------------------------------------------------------
  // Outbound
  // ------------------------------------------------------------------

  // Called from ContentDelegate.onSong for every position tick. The
  // position is already persisted in DataStore before we get here.
  function onPositionUpdate(track, positionSec) {
    if (DataStore.getDivergenceDeclined()) {
      // The local position moved since the user last declined: the decline
      // no longer represents the current state.
      DataStore.setDivergenceDeclined(false);
    }
    if (!(positionSec instanceof Lang.Number)) {
      // PlaybackPosition objects carry structure we don't parse; the next
      // Number-valued tick will sync.
      return;
    }
    if (mPromptUp || mPushInFlight) {
      return;
    }

    // Book change detection: the markers remember which (book, track) the
    // last push attempt covered, so switching books always re-syncs even
    // when the new book's track index coincides with the old one's.
    var isbn = DataStore.getCurrentIsbn();
    var trackChanged = mLastPushTrack == null
      || mLastPushIsbn != isbn
      || track != mLastPushTrack;
    var listenedFar = mLastPushPosSec == null
      || (positionSec.toNumber() - mLastPushPosSec).abs() >= PUSH_INTERVAL_S;
    if (trackChanged || listenedFar) {
      pushLocal();
    }
  }

  // Push the current local position to the cloud, fire-and-forget. On
  // failure it becomes PENDING_POSITION and retries at the next trigger.
  function pushLocal() {
    var snapshot = localSnapshot();
    if (snapshot == null) {
      return;
    }
    // Record the attempt markers up front: a failed push (no token,
    // offline, 5xx) must not re-fire on every onSong tick. Throttled
    // mid-track pushes, retries at trigger points instead.
    mLastPushIsbn = snapshot["isbn"];
    mLastPushTrack = snapshot["track"];
    mLastPushPosSec = snapshot["seconds"].toNumber();
    var token = Application.Properties.getValue("AUTHENTICATION_TOKEN");
    if (token == null || token == "" || mRequestsDisabled) {
      DataStore.setPendingPosition(snapshot);
      return;
    }
    mPushInFlight = true;
    Communications.makeWebRequest(
      Constants.POSITION_PUSH_URL,
      {
        "isbn" => snapshot["isbn"],
        "track_index" => snapshot["track"],
        "track_seconds" => snapshot["seconds"]
      },
      {
        :method => Communications.HTTP_REQUEST_METHOD_POST,
        :headers => {
          "Content-Type" => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
          "Authorization" => "Bearer " + token
        },
        :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
      },
      method(:onPushed)
    );
  }

  function onPushed(
    responseCode as Lang.Number,
    data as Null or Lang.Dictionary or Lang.String or PersistedContent.Iterator
  ) as Void {
    mPushInFlight = false;
    var snapshot = localSnapshot();
    if (responseCode == 200) {
      DataStore.setAuthStale(false);
      DataStore.setPendingPosition(null);
      if (snapshot != null) {
        mLastPushTrack = snapshot["track"];
        var pos = DataStore.getCurrentPosition();
        if (pos instanceof Lang.Number) {
          mLastPushPosSec = pos;
        }
        mRecentPush = true;
        mRecentPushTimer.start(method(:readAfterPushExpired), READ_AFTER_PUSH_MS, false);
        if (data != null && data["changed_at"] != null) {
          // Remember exactly what the cloud record looks like after our
          // write, so a later check can tell "our own record" from
          // "another device wrote".
          snapshot["changed_at"] = data["changed_at"];
        }
        DataStore.setLastSynced(snapshot);
      }
    } else {
      if (responseCode == 401 || responseCode == 403) {
        DataStore.setAuthStale(true);
      }
      if (snapshot != null) {
        DataStore.setPendingPosition(snapshot);
      }
    }
  }

  // Retry any position that failed to push earlier. Called at app open,
  // before playback, at explicit-sync time, and on app stop.
  function flushPending() {
    var pending = DataStore.getPendingPosition();
    if (pending == null || mPushInFlight || mPromptUp) {
      return;
    }
    var isbn = DataStore.getCurrentIsbn();
    if (isbn != null && pending["isbn"] == isbn) {
      pushLocal();
    } else {
      // Stale pending entry for a book that's no longer current; drop it.
      DataStore.setPendingPosition(null);
    }
  }

  // ------------------------------------------------------------------
  // Inbound
  // ------------------------------------------------------------------

  // App-open check: non-blocking; may raise an async prompt if another
  // device moved the current book's cloud position.
  function checkAtOpen() {
    runCheck(null);
  }

  // Pre-playback check: resolves any divergence first (prompting if
  // needed), then invokes done() so the caller can start playback. If the
  // network isn't available, done() runs immediately and playback uses
  // the local position.
  function playWithCheck(done as Lang.Method) {
    if (mPromptUp || mInFlight) {
      // A prompt or cloud read is already pending: defer startPlayback
      // until it resolves, so the seek lands before the first track.
      mWaiters.add(done);
      return;
    }
    runCheck(done);
  }

  private function runCheck(done as Lang.Method?) {
    // Queue the continuation first: when the check ends in a prompt (or
    // finds one pending), the waiters are finished from onPromptAnswer;
    // otherwise finishWaiters drains them here. Without this, a
    // playWithCheck continuation would be lost across an async prompt.
    if (done != null) {
      mWaiters.add(done);
    }
    var token = Application.Properties.getValue("AUTHENTICATION_TOKEN");
    var isbn = DataStore.getCurrentIsbn();
    if (token == null || token == "" || isbn == null) {
      finishWaiters(null);
      return;
    }
    // A push that just succeeded means a cloud read would be stale; the
    // LAST_SYNCED snapshot already reflects the push, so skip the read.
    // Offline (or tests forcing offline) behaves the same way: play local.
    if (mRecentPush || mRequestsDisabled) {
      finishWaiters(null);
      return;
    }
    mInFlight = true;
    Communications.makeWebRequest(
      Constants.POSITION_URL + isbn,
      {},
      {
        :method => Communications.HTTP_REQUEST_METHOD_GET,
        :headers => { "Authorization" => "Bearer " + token },
        :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
      },
      method(:onCloudPosition)
    );
  }

  function onCloudPosition(
    responseCode as Lang.Number,
    data as Null or Lang.Dictionary or Lang.String or PersistedContent.Iterator
  ) as Void {
    mInFlight = false;
    if (responseCode == 200 && data != null) {
      DataStore.setAuthStale(false);
      // resolveCloud returns false when it raised an async prompt; the
      // waiters are finished from onPromptAnswer instead.
      if (resolveCloud(data)) {
        finishWaiters(null);
      }
    } else {
      if (responseCode == 401 || responseCode == 403) {
        DataStore.setAuthStale(true);
      }
      // Network/server failure: play local, retry at the next trigger.
      finishWaiters(null);
    }
  }

  // Apply the decision table to one cloud record. Returns true when
  // the resolution finished synchronously; false when an async prompt is
  // up and the waiters will be finished from onPromptAnswer.
  private function resolveCloud(data as Lang.Dictionary) as Lang.Boolean {
    var cloudTrack = data["track_index"];
    var cloudSec = data["track_seconds"];
    var local = localSnapshot();
    if (cloudTrack == null || cloudSec == null || local == null) {
      // No server position (or nothing to compare): just flush.
      flushPending();
      return true;
    }
    var localTrack = local["track"];
    var localSec = local["seconds"];
    var cloudSnap = {
      "isbn" => local["isbn"],
      "track" => cloudTrack,
      "seconds" => cloudSec.toFloat(),
      "changed_at" => data["changed_at"]
    };

    if (isSameSpot(cloudTrack, cloudSec, localTrack, localSec)) {
      // Agree: record the cloud state, flush anything pending.
      DataStore.setLastSynced(cloudSnap);
      flushPending();
      return true;
    }

    var last = DataStore.getLastSynced();
    if (isAhead(localTrack, localSec, cloudTrack, cloudSec)) {
      // Local is ahead. Prompt only when the cloud record moved since we
      // last read or wrote it, i.e. another device was involved; a watch
      // that merely listened offline pushes silently. A prompt that is
      // already up is never pre-empted: no silent push, no second
      // prompt — the pending answer resolves this check's waiters.
      if (mPromptUp) {
        return false;
      }
      if (!cloudMovedSince(last, cloudSnap)) {
        pushLocal();
      } else {
        startPrompt("rewind", local, cloudSnap);
        return false;
      }
    } else if (isAhead(cloudTrack, cloudSec, localTrack, localSec)) {
      // Cloud is ahead: another device necessarily wrote it. Adopting it
      // decides where listening continues, so it still requires consent;
      // declining suppresses re-prompting until the position moves.
      if (DataStore.getDivergenceDeclined()) {
        return true;
      }
      if (mPromptUp) {
        // Wait for the pending prompt's answer.
        return false;
      }
      startPrompt("forward", local, cloudSnap);
      return false;
    }
    return true;
  }

  // Did the cloud record change since the watch last read or wrote it?
  // Null changed_at values (first check after install) count as "not
  // moved": a watch that merely listened offline should never be asked
  // about its own unsent progress.
  private function cloudMovedSince(
    last as Lang.Dictionary?,
    cloud as Lang.Dictionary
  ) as Lang.Boolean {
    if (last == null) {
      return false;
    }
    var lastChanged = last["changed_at"];
    var cloudChanged = cloud["changed_at"];
    if (lastChanged != null && cloudChanged != null && lastChanged == cloudChanged) {
      return false;
    }
    // The stamps differ (or one is unknown). If the position is still the
    // one we last observed, nothing moved.
    if (isSameSpot(last["track"], last["seconds"], cloud["track"], cloud["seconds"])) {
      return false;
    }
    return true;
  }

  private function startPrompt(kind as Lang.String, local as Lang.Dictionary, cloud as Lang.Dictionary) {
    mPromptUp = true;
    mPromptKind = kind;
    mPromptCloud = cloud;
    var message;
    if (kind == "rewind") {
      message = "Rewind to cloud time " + formatHms(local["seconds"]) + " -> "
        + formatHms(cloud["seconds"]) + "?";
    } else {
      message = "Fast forward to cloud time " + formatHms(local["seconds"]) + " -> "
        + formatHms(cloud["seconds"]) + "?";
    }
    WatchUi.pushView(
      new WatchUi.Confirmation(message),
      new PositionSyncPromptDelegate(),
      WatchUi.SLIDE_IMMEDIATE
    );
  }

  // Entry point from PositionSyncPromptDelegate.onResponse.
  function onPromptAnswer(confirmed as Lang.Boolean) as Void {
    var kind = mPromptKind;
    var cloud = mPromptCloud;
    mPromptUp = false;
    mPromptKind = null;
    mPromptCloud = null;

    if (kind == "rewind") {
      if (confirmed) {
        adoptRemote(cloud);
      } else {
        // Keep the watch position and make it authoritative.
        pushLocal();
      }
    } else {
      if (confirmed) {
        adoptRemote(cloud);
      } else {
        // Keep local; no push (cloud is ahead and we don't overwrite it).
        DataStore.setDivergenceDeclined(true);
      }
    }
    finishWaiters(null);
  }

  // Adopt the cloud position: seek the current book and record it as the
  // last-synced state. Clears any pending local position so the discarded
  // session can't be pushed later. No unit conversion: cloud seconds are
  // DataStore's CURRENT_POSITION unit (Media.ActiveContent consumes
  // seconds too).
  private function adoptRemote(cloud as Lang.Dictionary) {
    DataStore.setCurrentTrack(cloud["track"]);
    DataStore.setCurrentPosition(cloud["seconds"].toNumber());
    DataStore.setLastSynced(cloud);
    DataStore.setPendingPosition(null);
  }

  private function finishWaiters(done as Lang.Method?) {
    if (done != null) {
      done.invoke();
    }
    // Note: Array.remove() removes by object identity and returns a
    // Boolean (Toybox.Lang.Array docs), so grab the element before
    // removing it — the popped waiter is the value to invoke.
    while (mWaiters.size() > 0) {
      var waiter = mWaiters[0] as Lang.Method;
      mWaiters.remove(waiter);
      waiter.invoke();
    }
  }
}

// Module facade: a lazily-created singleton, so callers can use
// PositionSync.xxx() without managing an instance.
module PositionSync {
  var mCoordinator = null;

  function get() as PositionSyncCoordinator {
    if (mCoordinator == null) {
      mCoordinator = new PositionSyncCoordinator();
    }
    return mCoordinator;
  }

  function onPositionUpdate(track, positionSec) as Void {
    get().onPositionUpdate(track, positionSec);
  }

  function flushPending() as Void {
    get().flushPending();
  }

  function checkAtOpen() as Void {
    get().checkAtOpen();
  }

  function playWithCheck(done as Lang.Method) as Void {
    get().playWithCheck(done);
  }

  function onPromptAnswer(confirmed as Lang.Boolean) as Void {
    get().onPromptAnswer(confirmed);
  }
}
