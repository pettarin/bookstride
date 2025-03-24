import Toybox.Lang;
import Toybox.Media;

// This class handles events from the system's media
// player. getContentIterator() returns an iterator
// that iterates over the songs configured to play.
class ContentDelegate extends Media.ContentDelegate {
  function initialize() {
    ContentDelegate.initialize();
  }

  // Returns an iterator that is used by the system to play songs.
  // A custom iterator can be created that extends Media.ContentIterator
  // to return only songs chosen in the sync configuration mode.
  function getContentIterator() as Media.ContentIterator? {
    return new ContentIterator();
  }

  // Respond to a user ad click
  function onAdAction(adContext as Object) as Void {}

  // Respond to a thumbs-up action
  function onThumbsUp(contentRefId as Object) as Void {}

  // Respond to a thumbs-down action
  function onThumbsDown(contentRefId as Object) as Void {}

  // Respond to a command to turn shuffle on or off
  function onShuffle() as Void {}

  // Handles a notification from the system that an event has
  // been triggered for the given song
  function onSong(
    contentRefId as Object,
    songEvent as SongEvent,
    playbackPosition as Number or PlaybackPosition
  ) as Void {
    var downloadedBooks = Application.Properties.getValue("BOOKS");
    if (downloadedBooks == null) {
      downloadedBooks = [];
    }

    for (var i = 0; i < downloadedBooks.size(); i += 1) {
      for (var j = 0; j < downloadedBooks[i]["tracks"].size(); j += 1) {
        if (downloadedBooks[i]["tracks"][j] == contentRefId) {
            Application.Properties.setValue("CURRENT_ISBN", downloadedBooks[i]["isbn"]);
            Application.Properties.setValue("CURRENT_TRACK", j);
        }
      }
    }
  }
}
