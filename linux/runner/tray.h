#ifndef RUNNER_TRAY_H_
#define RUNNER_TRAY_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The "gpad/tray" channel: GPad's icon in the system tray, and showing or
// hiding [window] for it.
//
// The icon goes through libayatana-appindicator, or the older
// libappindicator, loaded when first needed so GPad still starts where
// neither is installed. "available" also asks the session bus whether
// anything shows such icons (GNOME doesn't, without an extension).
//
// Dart calls: available -> bool, show {status} -> bool, status {status},
// remove, hideWindow, showWindow, allowForeground (nothing to do here).
// The icon's menu calls Dart: syncNow, quit. Open GPad shows the window
// here.
//
// Returns the channel, which must be kept alive while the view is.
FlMethodChannel* tray_channel_new(FlBinaryMessenger* messenger,
                                  GtkWindow* window);

#endif  // RUNNER_TRAY_H_
