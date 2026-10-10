#pragma once

// The pure half of searching: what a name's extension means, how a query is
// split, and how well a name answers it. No SQLite and no filesystem, so all
// of it is tested headlessly (`tests/ranking_test.cpp`).

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace lava::indexer {

/// Mirrors `lava.index.Category` in the IDL, value for value, so the servant
/// can cast between the two without a table.
enum class Kind : uint32_t { any, folders, documents, images, videos, audio, archives };

/// Lowercased extension without the dot; empty for none. A leading dot is a
/// hidden file, not an extension: `.bashrc` has none.
std::string extensionOf(std::string_view name);

/// Which category an extension belongs to; `Kind::any` for none of them.
Kind categoryOf(std::string_view ext);

/// Every extension in `kind`, for an `ext IN (…)` filter.
const std::vector<std::string_view> &extensionsOf(Kind kind);

/// ASCII-lowercases. Leaves other bytes alone, so byte offsets into the
/// result are byte offsets into the original — which is what highlighting
/// needs. The accent- and case-folding beyond ASCII is FTS5's job; this only
/// has to rank what FTS5 already found.
std::string foldAscii(std::string_view s);

/// The query, folded and split on whitespace. Order kept: the first term is
/// the one a match position is reported for.
std::vector<std::string> splitQuery(std::string_view query);

/// How well one name answers a query. `matched` false means a term is not in
/// the name at all (FTS5 can still have matched it through accent folding;
/// such a hit ranks last rather than being dropped).
struct NameScore {
  bool matched = false;
  double score = 0;
  uint32_t matchStart = 0;
  uint32_t matchLength = 0;
};

/// Scores `name` against folded `terms`. Per term: the whole name starting
/// with it beats a word starting with it, which beats anywhere else; shorter
/// names win ties, because the shorter name is the more exact answer.
NameScore scoreName(std::string_view name, const std::vector<std::string> &terms);

/// The nudges applied once a candidate's path is known. Recency is the big
/// one: something opened yesterday is very likely what is being typed again.
double contextBoost(int64_t nowSeconds, int64_t lastOpenedSeconds, int depth,
                    bool isDirectory);

}  // namespace lava::indexer
