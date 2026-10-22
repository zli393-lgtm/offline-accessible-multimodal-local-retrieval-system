#include <gtest/gtest.h>

#include "utils.h"

TEST(Utf8FromUtf16Test, HandlesNullAndEmptyInput) {
  EXPECT_TRUE(Utf8FromUtf16(nullptr).empty());
  EXPECT_TRUE(Utf8FromUtf16(L"").empty());
}

TEST(Utf8FromUtf16Test, ConvertsAsciiChineseAndSupplementaryCharacters) {
  EXPECT_EQ(Utf8FromUtf16(L"retrieval"), "retrieval");
  EXPECT_EQ(Utf8FromUtf16(L"\u672C\u5730\u68C0\u7D22"),
            "\xE6\x9C\xAC\xE5\x9C\xB0\xE6\xA3\x80\xE7\xB4\xA2");
  EXPECT_EQ(Utf8FromUtf16(L"\U0001F50D"), "\xF0\x9F\x94\x8D");
}

TEST(Utf8FromUtf16Test, RejectsAnUnpairedUtf16Surrogate) {
  const wchar_t invalid[] = {static_cast<wchar_t>(0xD800), L'X', L'\0'};
  EXPECT_TRUE(Utf8FromUtf16(invalid).empty());
}
