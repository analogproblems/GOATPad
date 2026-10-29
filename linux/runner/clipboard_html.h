#ifndef RUNNER_CLIPBOARD_HTML_H_
#define RUNNER_CLIPBOARD_HTML_H_

#include <flutter_linux/flutter_linux.h>

// Answers "getHtml" on the "gpad/clipboard" channel with the clipboard's
// text/html as bytes, or null when there is none. Flutter's own clipboard
// API only reads plain text, and pasting from a browser, Word or Google
// Docs into a Rich note needs the HTML.
//
// Returns the channel, which must be kept alive while the view is.
FlMethodChannel* clipboard_html_channel_new(FlBinaryMessenger* messenger);

#endif  // RUNNER_CLIPBOARD_HTML_H_
