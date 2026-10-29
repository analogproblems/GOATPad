#include "clipboard_html.h"

#include <cstring>

static void html_received(GtkClipboard* clipboard,
                          GtkSelectionData* selection,
                          gpointer user_data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(user_data);
  gint length = 0;
  const guchar* data =
      selection == nullptr
          ? nullptr
          : gtk_selection_data_get_data_with_length(selection, &length);
  // A negative length means the clipboard has no HTML.
  g_autoptr(FlValue) result = data != nullptr && length > 0
                                  ? fl_value_new_uint8_list(data, length)
                                  : fl_value_new_null();
  fl_method_call_respond_success(call, result, nullptr);
}

static void method_call(FlMethodChannel* channel,
                        FlMethodCall* call,
                        gpointer user_data) {
  if (strcmp(fl_method_call_get_name(call), "getHtml") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  // Asynchronous, so a slow clipboard owner never freezes the window.
  gtk_clipboard_request_contents(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD),
                                 gdk_atom_intern_static_string("text/html"),
                                 html_received, g_object_ref(call));
}

FlMethodChannel* clipboard_html_channel_new(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, "gpad/clipboard", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call, nullptr,
                                            nullptr);
  return channel;
}
