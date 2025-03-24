using Toybox.System;
using Toybox.WatchUi;

class BaseDelegate extends WatchUi.BehaviorDelegate {
    // Detect Menu behavior
    function onMenu() {
        System.println("Menu behavior triggered");
        return false; // allow InputDelegate function to be called
    }
}