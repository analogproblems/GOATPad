#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <sddl.h>

#include "flutter_window.h"
#include "utils.h"

#pragma comment(lib, "advapi32.lib")

// Tells GPad's installer and uninstaller that GPad is running, so they ask
// for it to be closed first (AppMutex in windows/installer/gpad.iss).
// Windows lets go of both mutexes when GPad exits.
static void HoldRunningMutexes() {
  // In this session, for Setup run from the same account.
  ::CreateMutexW(nullptr, FALSE, L"GPad.Running");

  // In every session, for an install for all accounts: an administrator's
  // Setup must see GPad open in another person's session. Anyone signed in
  // may only wait on it (SYNCHRONIZE), which is all Setup asks for; only its
  // owner may do more. Opened for SYNCHRONIZE alone, so a second person's
  // GPad holds the one the first person's made, keeping it while either runs.
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!::ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:(A;;GA;;;OW)(A;;0x00100000;;;AU)", SDDL_REVISION_1,
          &descriptor, nullptr)) {
    return;
  }
  SECURITY_ATTRIBUTES attributes = {static_cast<DWORD>(sizeof(attributes)),
                                    descriptor, FALSE};
  ::CreateMutexExW(&attributes, L"Global\\GPad.Running", 0, SYNCHRONIZE);
  ::LocalFree(descriptor);
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HoldRunningMutexes();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"GPad", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
