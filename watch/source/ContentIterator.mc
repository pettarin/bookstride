using Toybox.Application;
using Toybox.Math;
using Toybox.Media;
using Toybox.Lang;

// Iterator to control the order of song playback
class ContentIterator extends Media.ContentIterator {
  private var mTrackIndex = 0;
  private var mTracks = [];

  // Constructor
  function initialize() {
    ContentIterator.initialize();
    initializePlaylist();
  }

  // Returns the playback profile
  function getPlaybackProfile() {
    var profile = new PlaybackProfile();

    profile.playbackControls = [
      Media.PLAYBACK_CONTROL_SKIP_BACKWARD,
      Media.PLAYBACK_CONTROL_SKIP_FORWARD,
      Media.PLAYBACK_CONTROL_PREVIOUS,
      Media.PLAYBACK_CONTROL_NEXT,
      Media.PLAYBACK_CONTROL_LIBRARY,
      Media.PLAYBACK_CONTROL_PLAYBACK
    ];

    profile.attemptSkipAfterThumbsDown = false;
    profile.requirePlaybackNotification = true;
    profile.playbackNotificationThreshold = 15;
    profile.skipPreviousThreshold = 10;

    return profile;
  }

  // Returns the next song, or null if there is no next song. Also increments the current
  // song index.
  function next() {
    if (mTrackIndex < mTracks.size() - 1) {
      ++mTrackIndex;
      var obj = Media.getCachedContentObj(
        new Media.ContentRef(mTracks[mTrackIndex], Media.CONTENT_TYPE_AUDIO)
      );
      return obj;
    }

    return null;
  }

  // Returns the previous song, or null if there is no previous song. Also decrements the current
  // song index.
  function previous() {
    if (mTrackIndex > 0) {
      --mTrackIndex;
      var obj = Media.getCachedContentObj(
        new Media.ContentRef(mTracks[mTrackIndex], Media.CONTENT_TYPE_AUDIO)
      );
      return obj;
    }

    return null;
  }

  // Gets the current song to play
  function get() {
    var obj = null;
    if (mTrackIndex >= 0 && mTrackIndex < mTracks.size()) {
      obj = Media.getCachedContentObj(
        new Media.ContentRef(mTracks[mTrackIndex], Media.CONTENT_TYPE_AUDIO)
      );
    }

    return obj;
  }

  function peekNext() {
    var nextIndex = mTrackIndex + 1;
    if (nextIndex < mTracks.size()) {
      var obj = Media.getCachedContentObj(
        new Media.ContentRef(mTracks[nextIndex], Media.CONTENT_TYPE_AUDIO)
      );
      return obj;
    }

    return null;
  }

  function peekPrevious() {
    var previousIndex = mTrackIndex - 1;
    if (previousIndex >= 0) {
      var obj = Media.getCachedContentObj(
        new Media.ContentRef(mTracks[previousIndex], Media.CONTENT_TYPE_AUDIO)
      );
      return obj;
    }

    return null;
  }

  function shuffling() {
    return false;
  }

  function canSkip() {
    return true;
  }

  function toggleShuffle() {}

  function shufflePlaylist() {}

  function initializePlaylist() {
    var isbn = Application.Properties.getValue("CURRENT_ISBN");
    var books = Application.Properties.getValue("BOOKS");
    mTracks = [];
    if (books != null) {
      for (var i = 0; i < books.size(); i += 1) {
        if (books[i]["isbn"] == isbn) {
          mTracks = books[i]["tracks"];
        }
      }
    }
    var savedIndex = Application.Properties.getValue("CURRENT_TRACK") as Lang.String or Lang.Number or Null;
    if (savedIndex == null || !(savedIndex instanceof Lang.Number) || savedIndex >= mTracks.size())  {
        mTrackIndex = 0;
    } else {
        mTrackIndex = savedIndex;
    }
  }
}