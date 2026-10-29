#ifndef RUNNER_TRAY_H_
#define RUNNER_TRAY_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>

// The "gpad/tray" channel: GPad's icon in the notification area, and
// showing or hiding the window for it.
//
// Dart calls: available -> bool, show {status} -> bool, status {status},
// remove, hideWindow, showWindow, and allowForeground, which a second GPad
// calls so the first may bring its window to the front. The icon calls
// Dart: syncNow, quit. A click on it, or Open GPad, shows the window here.
class Tray {
 public:
  Tray(HWND window, flutter::BinaryMessenger* messenger);
  ~Tray();

  Tray(const Tray&) = delete;
  Tray& operator=(const Tray&) = delete;

  // Handles the icon's messages to the window, and Explorer restarting.
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  void Show();
  void Remove();
  void ShowMenu();
  void BringBack();
  void CallDart(const std::string& method);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HICON icon_ = nullptr;
  bool shown_ = false;
  std::wstring status_ = L"GPad";
  UINT taskbar_created_;
};

#endif  // RUNNER_TRAY_H_
