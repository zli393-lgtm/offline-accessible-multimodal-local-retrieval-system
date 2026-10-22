#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>

#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::string Utf8FromWide(const wchar_t* value) {
  if (value == nullptr) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 1) return {};
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), size, nullptr,
                      nullptr);
  result.pop_back();
  return result;
}

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
  if (size <= 1) return {};
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), size);
  result.pop_back();
  return result;
}

bool AppendPath(IShellItem* item, flutter::EncodableList* paths) {
  PWSTR path = nullptr;
  const HRESULT result = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
  if (FAILED(result) || path == nullptr) return false;
  paths->emplace_back(Utf8FromWide(path));
  CoTaskMemFree(path);
  return true;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  path_picker_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "retrieval/system_path_picker",
          &flutter::StandardMethodCodec::GetInstance());
  path_picker_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const bool pick_directory = call.method_name() == "pickDirectory";
        const bool pick_files = call.method_name() == "pickFiles";
        if (!pick_directory && !pick_files) {
          result->NotImplemented();
          return;
        }

        bool multiple = false;
        std::string initial_directory;
        std::string filter_label;
        std::vector<std::string> allowed_suffixes;
        if (const auto* arguments =
                std::get_if<flutter::EncodableMap>(call.arguments())) {
          const auto entry = arguments->find(flutter::EncodableValue("multiple"));
          if (entry != arguments->end()) {
            if (const auto* value = std::get_if<bool>(&entry->second)) {
              multiple = *value;
            }
          }
          const auto initial_entry =
              arguments->find(flutter::EncodableValue("initialDirectory"));
          if (initial_entry != arguments->end()) {
            if (const auto* value =
                    std::get_if<std::string>(&initial_entry->second)) {
              initial_directory = *value;
            }
          }
          const auto label_entry =
              arguments->find(flutter::EncodableValue("filterLabel"));
          if (label_entry != arguments->end()) {
            if (const auto* value =
                    std::get_if<std::string>(&label_entry->second)) {
              filter_label = *value;
            }
          }
          const auto suffix_entry =
              arguments->find(flutter::EncodableValue("allowedSuffixes"));
          if (suffix_entry != arguments->end()) {
            if (const auto* values =
                    std::get_if<flutter::EncodableList>(&suffix_entry->second)) {
              for (const auto& item : *values) {
                if (const auto* value = std::get_if<std::string>(&item)) {
                  allowed_suffixes.push_back(*value);
                }
              }
            }
          }
        }

        IFileOpenDialog* dialog = nullptr;
        HRESULT status = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                          CLSCTX_INPROC_SERVER,
                                          IID_PPV_ARGS(&dialog));
        if (FAILED(status) || dialog == nullptr) {
          result->Error("dialog-create-failed",
                        "Unable to create the Windows file picker.");
          return;
        }

        FILEOPENDIALOGOPTIONS options = FOS_FORCEFILESYSTEM |
                                        FOS_PATHMUSTEXIST |
                                        FOS_NOCHANGEDIR;
        if (pick_directory) options |= FOS_PICKFOLDERS;
        if (pick_files && multiple) options |= FOS_ALLOWMULTISELECT;
        dialog->SetOptions(options);
        dialog->SetTitle(pick_directory
                             ? L"\x9009\x62E9\x6587\x4EF6\x5939"
                             : L"\x9009\x62E9\x6587\x4EF6");

        if (!initial_directory.empty()) {
          IShellItem* initial_item = nullptr;
          const std::wstring initial_path = WideFromUtf8(initial_directory);
          if (!initial_path.empty() &&
              SUCCEEDED(SHCreateItemFromParsingName(
                  initial_path.c_str(), nullptr, IID_PPV_ARGS(&initial_item))) &&
              initial_item != nullptr) {
            dialog->SetFolder(initial_item);
            initial_item->Release();
          }
        }
        std::vector<std::wstring> filter_names;
        std::vector<std::wstring> filter_patterns;
        std::vector<COMDLG_FILTERSPEC> filter_specs;
        if (pick_files && !allowed_suffixes.empty()) {
          filter_names.push_back(WideFromUtf8(
              filter_label.empty() ? "Allowed files" : filter_label));
          std::wstring pattern;
          for (size_t index = 0; index < allowed_suffixes.size(); ++index) {
            if (index > 0) pattern += L";";
            pattern += L"*" + WideFromUtf8(allowed_suffixes[index]);
          }
          filter_patterns.push_back(pattern);
          filter_specs.push_back(
              {filter_names.back().c_str(), filter_patterns.back().c_str()});
          dialog->SetFileTypes(static_cast<UINT>(filter_specs.size()),
                               filter_specs.data());
          dialog->SetFileTypeIndex(1);
        }

        status = dialog->Show(GetHandle());
        if (status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
          dialog->Release();
          result->Success(flutter::EncodableValue(flutter::EncodableList{}));
          return;
        }
        if (FAILED(status)) {
          dialog->Release();
          result->Error("dialog-open-failed",
                        "Unable to open the Windows file picker.");
          return;
        }

        flutter::EncodableList paths;
        if (pick_files && multiple) {
          IShellItemArray* items = nullptr;
          status = dialog->GetResults(&items);
          if (SUCCEEDED(status) && items != nullptr) {
            DWORD count = 0;
            items->GetCount(&count);
            for (DWORD index = 0; index < count; ++index) {
              IShellItem* item = nullptr;
              if (SUCCEEDED(items->GetItemAt(index, &item)) && item != nullptr) {
                AppendPath(item, &paths);
                item->Release();
              }
            }
            items->Release();
          }
        } else {
          IShellItem* item = nullptr;
          status = dialog->GetResult(&item);
          if (SUCCEEDED(status) && item != nullptr) {
            AppendPath(item, &paths);
            item->Release();
          }
        }
        dialog->Release();
        result->Success(flutter::EncodableValue(paths));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    path_picker_channel_.reset();
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
