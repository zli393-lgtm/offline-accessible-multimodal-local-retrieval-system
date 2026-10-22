#include "utils.h"

#include <windows.h>

#include <string>

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // UNICODE_STRING_MAX_CHARS is the Windows upper bound for this input.
  const int input_length = static_cast<int>(
      wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  const int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string, input_length, nullptr, 0,
      nullptr, nullptr);
  std::string utf8_string;
  if (target_length == 0 ||
      static_cast<size_t>(target_length) > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  const int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string, input_length,
      utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
