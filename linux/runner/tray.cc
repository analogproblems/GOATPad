#include "tray.h"

#include <dlfcn.h>

#include <cstring>
#include <initializer_list>

namespace {

// From libappindicator's app-indicator.h. GPad doesn't build against it,
// so that it starts where it isn't installed; libayatana-appindicator has
// the same functions.
typedef struct _AppIndicator AppIndicator;
constexpr int kCategoryApplicationStatus = 0;
constexpr int kStatusPassive = 0;
constexpr int kStatusActive = 1;

struct AppIndicatorApi {
  AppIndicator* (*new_with_path)(const gchar* id,
                                 const gchar* icon_name,
                                 int category,
                                 const gchar* icon_theme_path);
  void (*set_status)(AppIndicator* indicator, int status);
  void (*set_menu)(AppIndicator* indicator, GtkMenu* menu);
  void (*set_title)(AppIndicator* indicator, const gchar* title);
  void (*set_secondary_activate_target)(AppIndicator* indicator,
                                        GtkWidget* menu_item);
};

struct Tray {
  FlMethodChannel* channel;
  GtkWindow* window;
  // Never closed: the icon may last until GPad quits.
  void* library;
  AppIndicatorApi api;
  AppIndicator* indicator;
  GtkWidget* status_item;
};

bool load_api(Tray* tray) {
  if (tray->library == nullptr) {
    for (const char* name :
         {"libayatana-appindicator3.so.1", "libappindicator3.so.1"}) {
      void* library = dlopen(name, RTLD_NOW | RTLD_LOCAL);
      if (library == nullptr) continue;
      AppIndicatorApi api = {
          reinterpret_cast<decltype(api.new_with_path)>(
              dlsym(library, "app_indicator_new_with_path")),
          reinterpret_cast<decltype(api.set_status)>(
              dlsym(library, "app_indicator_set_status")),
          reinterpret_cast<decltype(api.set_menu)>(
              dlsym(library, "app_indicator_set_menu")),
          reinterpret_cast<decltype(api.set_title)>(
              dlsym(library, "app_indicator_set_title")),
          reinterpret_cast<decltype(api.set_secondary_activate_target)>(
              dlsym(library, "app_indicator_set_secondary_activate_target")),
      };
      if (api.new_with_path == nullptr || api.set_status == nullptr ||
          api.set_menu == nullptr || api.set_title == nullptr ||
          api.set_secondary_activate_target == nullptr) {
        dlclose(library);
        continue;
      }
      tray->library = library;
      tray->api = api;
      break;
    }
  }
  return tray->library != nullptr;
}

void respond(FlMethodCall* call, FlValue* value) {
  fl_method_call_respond_success(call, value, nullptr);
}

void respond_bool(FlMethodCall* call, bool value) {
  g_autoptr(FlValue) result = fl_value_new_bool(value);
  respond(call, result);
}

void show_window(Tray* tray) {
  gtk_widget_show(GTK_WIDGET(tray->window));
  gtk_window_present(tray->window);
}

void call_dart(Tray* tray, const gchar* method) {
  fl_method_channel_invoke_method(tray->channel, method, nullptr, nullptr,
                                  nullptr, nullptr);
}

void on_open(Tray* tray) { show_window(tray); }

void on_sync_now(Tray* tray) { call_dart(tray, "syncNow"); }

void on_quit(Tray* tray) { call_dart(tray, "quit"); }

GtkWidget* add_item(GtkWidget* menu, const gchar* label,
                    void (*activate)(Tray*), Tray* tray) {
  GtkWidget* item = gtk_menu_item_new_with_label(label);
  g_signal_connect_swapped(item, "activate", G_CALLBACK(activate), tray);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
  return item;
}

// The icon lives next to the executable, in data/tray/gpad-tray.png.
gchar* icon_folder() {
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree gchar* folder =
      executable == nullptr ? g_get_current_dir()
                            : g_path_get_dirname(executable);
  return g_build_filename(folder, "data", "tray", nullptr);
}

// The tray went away, as when its GNOME extension is turned off: show the
// window rather than strand GPad without a way back.
void connection_changed(AppIndicator* indicator, gboolean connected,
                        gpointer data) {
  Tray* tray = static_cast<Tray*>(data);
  if (!connected && !gtk_widget_get_visible(GTK_WIDGET(tray->window))) {
    show_window(tray);
  }
}

void make_indicator(Tray* tray) {
  g_autofree gchar* icons = icon_folder();
  tray->indicator = tray->api.new_with_path(
      "gpad", "gpad-tray", kCategoryApplicationStatus, icons);
  tray->api.set_title(tray->indicator, "GPad");
  g_signal_connect(tray->indicator, "connection-changed",
                   G_CALLBACK(connection_changed), tray);

  GtkWidget* menu = gtk_menu_new();
  tray->status_item = gtk_menu_item_new_with_label("GPad");
  gtk_widget_set_sensitive(tray->status_item, FALSE);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), tray->status_item);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
  GtkWidget* open = add_item(menu, "Open GPad", on_open, tray);
  add_item(menu, "Sync now", on_sync_now, tray);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
  add_item(menu, "Quit GPad", on_quit, tray);
  gtk_widget_show_all(menu);
  tray->api.set_menu(tray->indicator, GTK_MENU(menu));
  // A middle click on the icon, where the desktop passes it on, opens GPad.
  tray->api.set_secondary_activate_target(tray->indicator, open);
}

const gchar* status_argument(FlMethodCall* call) {
  FlValue* args = fl_method_call_get_args(call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* status = fl_value_lookup_string(args, "status");
  if (status == nullptr || fl_value_get_type(status) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(status);
}

void set_status(Tray* tray, const gchar* status) {
  if (tray->status_item != nullptr && status != nullptr) {
    gtk_menu_item_set_label(GTK_MENU_ITEM(tray->status_item), status);
  }
}

// Whether something on the session bus shows tray icons: the
// StatusNotifierWatcher, with a host registered.
void host_answered(GObject* source, GAsyncResult* result, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(source), result, nullptr);
  gboolean registered = FALSE;
  if (reply != nullptr) {
    g_autoptr(GVariant) value = nullptr;
    g_variant_get(reply, "(v)", &value);
    registered = g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN) &&
                 g_variant_get_boolean(value);
  }
  respond_bool(call, registered);
}

void bus_ready(GObject* source, GAsyncResult* result, gpointer data) {
  g_autoptr(GDBusConnection) bus = g_bus_get_finish(result, nullptr);
  if (bus == nullptr) {
    g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
    respond_bool(call, false);
    return;
  }
  g_dbus_connection_call(
      bus, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
      "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", "org.kde.StatusNotifierWatcher",
                    "IsStatusNotifierHostRegistered"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, nullptr,
      host_answered, data);
}

void method_call(FlMethodChannel* channel, FlMethodCall* call,
                 gpointer data) {
  Tray* tray = static_cast<Tray*>(data);
  const gchar* method = fl_method_call_get_name(call);
  if (strcmp(method, "available") == 0) {
    if (!load_api(tray)) {
      respond_bool(call, false);
      return;
    }
    // Asynchronous, so a slow bus never freezes the window.
    g_bus_get(G_BUS_TYPE_SESSION, nullptr, bus_ready, g_object_ref(call));
  } else if (strcmp(method, "show") == 0) {
    if (!load_api(tray)) {
      respond_bool(call, false);
      return;
    }
    if (tray->indicator == nullptr) make_indicator(tray);
    set_status(tray, status_argument(call));
    tray->api.set_status(tray->indicator, kStatusActive);
    respond_bool(call, true);
  } else if (strcmp(method, "status") == 0) {
    set_status(tray, status_argument(call));
    respond(call, nullptr);
  } else if (strcmp(method, "remove") == 0) {
    if (tray->indicator != nullptr) {
      tray->api.set_status(tray->indicator, kStatusPassive);
    }
    respond(call, nullptr);
  } else if (strcmp(method, "hideWindow") == 0) {
    gtk_widget_hide(GTK_WIDGET(tray->window));
    respond(call, nullptr);
  } else if (strcmp(method, "showWindow") == 0) {
    show_window(tray);
    respond(call, nullptr);
  } else if (strcmp(method, "allowForeground") == 0) {
    respond(call, nullptr);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

void free_tray(gpointer data) {
  Tray* tray = static_cast<Tray*>(data);
  if (tray->indicator != nullptr) {
    tray->api.set_status(tray->indicator, kStatusPassive);
    g_object_unref(tray->indicator);
  }
  g_free(tray);
}

}  // namespace

FlMethodChannel* tray_channel_new(FlBinaryMessenger* messenger,
                                  GtkWindow* window) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel =
      fl_method_channel_new(messenger, "gpad/tray", FL_METHOD_CODEC(codec));
  Tray* tray = g_new0(Tray, 1);
  tray->channel = channel;
  tray->window = window;
  fl_method_channel_set_method_call_handler(channel, method_call, tray,
                                            free_tray);
  return channel;
}
