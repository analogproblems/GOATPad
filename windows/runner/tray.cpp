#include "tray.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include "resource.h"

namespace {

constexpr UINT kIconMessage = WM_APP + 1;
constexpr UINT kIconId = 1;

enum MenuItem : UINT { kOpen = 1, kSyncNow, kQuit };

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring utf16(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      utf16.data(), length);
  return utf16;
}

// The "status" argument, or "GPad" without one.
std::wstring StatusArgument(const flutter::EncodableValue* arguments) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return L"GPad";
  }
  auto found = map->find(flutter::EncodableValue("status"));
  if (found == map->end()) {
    return L"GPad";
  }
  const auto* status = std::get_if<std::string>(&found->second);
  return status == nullptr ? L"GPad" : Utf16FromUtf8(*status);
}

}  // namespace

Tray::Tray(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window),
      taskbar_created_(RegisterWindowMessage(L"TaskbarCreated")) {
  icon_ = static_cast<HICON>(
      LoadImage(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON),
                IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR));
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "gpad/tray", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "available") {
          // Every Windows desktop GPad runs on has a notification area.
          result->Success(flutter::EncodableValue(true));
        } else if (method == "show") {
          status_ = StatusArgument(call.arguments());
          wanted_ = true;
          Show();
          result->Success(flutter::EncodableValue(shown_));
        } else if (method == "status") {
          status_ = StatusArgument(call.arguments());
          if (shown_) {
            Show();
          }
          result->Success();
        } else if (method == "remove") {
          Remove();
          result->Success();
        } else if (method == "hideWindow") {
          ::ShowWindow(window_, SW_HIDE);
          result->Success();
        } else if (method == "showWindow") {
          BringBack();
          result->Success();
        } else if (method == "allowForeground") {
          AllowSetForegroundWindow(ASFW_ANY);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

Tray::~Tray() {
  channel_->SetMethodCallHandler(nullptr);
  Remove();
  if (icon_ != nullptr) {
    DestroyIcon(icon_);
  }
}

std::optional<LRESULT> Tray::HandleMessage(UINT message, WPARAM wparam,
                                           LPARAM lparam) {
  if (message == kIconMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
        BringBack();
        break;
      case WM_RBUTTONUP:
        ShowMenu();
        break;
    }
    return 0;
  }
  if (message == taskbar_created_ && wanted_) {
    // Explorer (re)started, without GPad's icon.
    shown_ = false;
    Show();
    if (!shown_ && !IsWindowVisible(window_)) {
      // Nothing to come back by: show the window rather than strand GPad.
      BringBack();
    }
    return 0;
  }
  return std::nullopt;
}

void Tray::Show() {
  NOTIFYICONDATA data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  data.uCallbackMessage = kIconMessage;
  data.hIcon = icon_;
  lstrcpynW(data.szTip, status_.c_str(), ARRAYSIZE(data.szTip));
  // An icon Explorer lost, restarting, can't be changed: add it again.
  if (!shown_ || Shell_NotifyIcon(NIM_MODIFY, &data) == FALSE) {
    shown_ = Shell_NotifyIcon(NIM_ADD, &data) != FALSE;
  }
}

void Tray::Remove() {
  wanted_ = false;
  if (!shown_) {
    return;
  }
  NOTIFYICONDATA data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  Shell_NotifyIcon(NIM_DELETE, &data);
  shown_ = false;
}

void Tray::ShowMenu() {
  HMENU menu = CreatePopupMenu();
  AppendMenu(menu, MF_STRING | MF_GRAYED, 0, status_.c_str());
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kOpen, L"Open GPad");
  AppendMenu(menu, MF_STRING, kSyncNow, L"Sync now");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kQuit, L"Quit GPad");
  SetMenuDefaultItem(menu, kOpen, FALSE);
  POINT cursor;
  GetCursorPos(&cursor);
  // Without this the menu stays open when clicked away from.
  SetForegroundWindow(window_);
  UINT chosen = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                               cursor.x, cursor.y, 0, window_, nullptr);
  PostMessage(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  switch (chosen) {
    case kOpen:
      BringBack();
      break;
    case kSyncNow:
      CallDart("syncNow");
      break;
    case kQuit:
      CallDart("quit");
      break;
  }
}

void Tray::BringBack() {
  ::ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window_);
}

void Tray::CallDart(const std::string& method) {
  channel_->InvokeMethod(method, nullptr);
}
