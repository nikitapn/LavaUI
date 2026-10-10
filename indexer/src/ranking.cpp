#include "ranking.hpp"

#include <algorithm>
#include <cmath>

namespace lava::indexer {

namespace {

// Tiers far enough apart that no length or context nudge crosses one: a name
// that starts with the query always beats one that merely contains it.
constexpr double kWholeNamePrefix = 300;
constexpr double kWordPrefix = 200;
constexpr double kSubstring = 100;
constexpr double kFoldedOnly = 10;

const std::vector<std::string_view> kDocuments = {
    "pdf", "doc", "docx", "odt", "rtf", "txt", "md", "tex", "epub", "djvu", "mobi",
    "xls", "xlsx", "ods", "csv", "ppt", "pptx", "odp", "pages", "numbers", "key"};
const std::vector<std::string_view> kImages = {
    "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "svg", "heic",
    "heif", "avif", "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "psd", "xcf"};
const std::vector<std::string_view> kVideos = {
    "mp4", "mkv", "mov", "avi", "webm", "m4v", "wmv", "flv", "mpg", "mpeg", "ts",
    "m2ts", "3gp", "ogv"};
const std::vector<std::string_view> kAudio = {
    "mp3", "flac", "ogg", "opus", "wav", "m4a", "aac", "wma", "aiff", "alac"};
const std::vector<std::string_view> kArchives = {
    "zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "iso", "dmg"};
const std::vector<std::string_view> kNone = {};

bool isWordByte(unsigned char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
         c >= 0x80;
}

// A word starts after a separator, or where camelCase or a digit run turns
// into letters: "QuarterlyReport", "Q3Report".
bool isWordStart(std::string_view name, size_t at) {
  if (at == 0) return true;
  const auto prev = static_cast<unsigned char>(name[at - 1]);
  const auto cur = static_cast<unsigned char>(name[at]);
  if (!isWordByte(prev)) return true;
  if (prev >= 'a' && prev <= 'z' && cur >= 'A' && cur <= 'Z') return true;
  if (prev >= '0' && prev <= '9' && !(cur >= '0' && cur <= '9')) return true;
  return false;
}

}  // namespace

std::string extensionOf(std::string_view name) {
  const size_t dot = name.rfind('.');
  if (dot == std::string_view::npos || dot == 0 || dot + 1 == name.size()) return {};
  return foldAscii(name.substr(dot + 1));
}

const std::vector<std::string_view> &extensionsOf(Kind kind) {
  switch (kind) {
    case Kind::documents: return kDocuments;
    case Kind::images: return kImages;
    case Kind::videos: return kVideos;
    case Kind::audio: return kAudio;
    case Kind::archives: return kArchives;
    default: return kNone;
  }
}

Kind categoryOf(std::string_view ext) {
  for (Kind k : {Kind::documents, Kind::images, Kind::videos, Kind::audio, Kind::archives}) {
    const auto &list = extensionsOf(k);
    if (std::find(list.begin(), list.end(), ext) != list.end()) return k;
  }
  return Kind::any;
}

std::string foldAscii(std::string_view s) {
  std::string out(s);
  for (char &c : out) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  }
  return out;
}

std::vector<std::string> splitQuery(std::string_view query) {
  std::vector<std::string> terms;
  size_t i = 0;
  while (i < query.size()) {
    while (i < query.size() && (query[i] == ' ' || query[i] == '\t')) ++i;
    const size_t start = i;
    while (i < query.size() && query[i] != ' ' && query[i] != '\t') ++i;
    if (i > start) terms.push_back(foldAscii(query.substr(start, i - start)));
  }
  return terms;
}

NameScore scoreName(std::string_view name, const std::vector<std::string> &terms) {
  NameScore out;
  if (terms.empty()) return out;
  const std::string folded = foldAscii(name);
  out.matched = true;
  double total = 0;
  for (size_t t = 0; t < terms.size(); ++t) {
    const std::string &term = terms[t];
    // Prefer the best occurrence, not the first: "report_final_Report.pdf"
    // should credit the word start, wherever it is.
    double best = 0;
    size_t bestAt = std::string::npos;
    for (size_t at = folded.find(term); at != std::string::npos;
         at = folded.find(term, at + 1)) {
      const double tier = at == 0 ? kWholeNamePrefix
                          : isWordStart(name, at) ? kWordPrefix
                                                  : kSubstring;
      if (tier > best) {
        best = tier;
        bestAt = at;
      }
    }
    if (bestAt == std::string::npos) {
      out.matched = false;
      total += kFoldedOnly;
      continue;
    }
    total += best;
    if (t == 0) {
      out.matchStart = static_cast<uint32_t>(bestAt);
      out.matchLength = static_cast<uint32_t>(term.size());
    }
  }
  // Averaged, so a three-word query is not three times as good as a
  // one-word one; ranking compares names against the same query only.
  out.score = total / static_cast<double>(terms.size());
  // Up to ~20 points for brevity: "Invoice.pdf" over "Invoice 0042 copy
  // (2) final.pdf" for "invoice". Never enough to cross a tier.
  out.score += 20.0 / (1.0 + static_cast<double>(name.size()) / 16.0);
  return out;
}

double contextBoost(int64_t nowSeconds, int64_t lastOpenedSeconds, int depth,
                    bool isDirectory) {
  double boost = 0;
  if (lastOpenedSeconds > 0) {
    // Up to 60, halving every two weeks: enough to lift a recent file over
    // an unopened one in the same tier, not over a better tier.
    const double days =
        std::max<double>(0, static_cast<double>(nowSeconds - lastOpenedSeconds) / 86400.0);
    boost += 60.0 * std::exp2(-days / 14.0);
  }
  // Shallow beats deep, mildly: ~/Documents/Lease.pdf over the same name
  // five levels into somebody's backup.
  boost -= 1.5 * std::min(depth, 12);
  // A folder that matches is usually somewhere the user meant to go.
  if (isDirectory) boost += 2;
  return boost;
}

}  // namespace lava::indexer
