// What a search box has to get right before any database is involved: which
// of two names is the better answer, where the match is, and what an
// extension means. Plus the two parsers that read other programs' files.

#include "mounts.hpp"
#include "ranking.hpp"
#include "xbel.hpp"

#include <cstdio>
#include <string>

using namespace lava::indexer;

namespace {

int failures = 0;

void check(bool ok, const std::string &what) {
  if (ok) return;
  std::printf("FAIL: %s\n", what.c_str());
  ++failures;
}

double score(const std::string &name, const std::string &query) {
  return scoreName(name, splitQuery(query)).score;
}

void tiers() {
  check(score("Report.pdf", "rep") > score("Quarterly Report.pdf", "rep"),
        "a name starting with the query beats a word starting with it");
  check(score("Quarterly Report.pdf", "rep") > score("Unreported.pdf", "rep"),
        "a word start beats the middle of a word");
  check(score("QuarterlyReport.pdf", "rep") > score("Unreported.pdf", "rep"),
        "camelCase counts as a word start");
  check(score("Q3report.pdf", "rep") > score("Unreported.pdf", "rep"),
        "a digit run ending counts as a word start");
  check(score("Invoice.pdf", "invoice") > score("Invoice 0042 copy (2) final.pdf", "invoice"),
        "shorter wins inside a tier");
  check(score("Unreported-but-long-enough-name.pdf", "rep") <
            score("Report-with-an-extremely-long-trailing-name-for-sure.pdf", "rep"),
        "length never crosses a tier");
  check(score("REPORT.PDF", "report") == score("report.pdf", "report"), "case does not matter");
}

void positions() {
  const NameScore s = scoreName("Quarterly Report Q3.pdf", splitQuery("report"));
  check(s.matched && s.matchStart == 10 && s.matchLength == 6, "match reported at the word");
  const NameScore best = scoreName("unreported_Report.pdf", splitQuery("report"));
  check(best.matchStart == 11, "the best occurrence is reported, not the first");
  const NameScore two = scoreName("Site Report Walkthrough.mp4", splitQuery("walk site"));
  check(two.matched && two.matchStart == 12, "the first term is the one highlighted");
  const NameScore miss = scoreName("Résumé.pdf", splitQuery("resume"));
  check(!miss.matched && miss.matchLength == 0, "an accent-folded match is not highlighted");
}

void queries() {
  const auto t = splitQuery("  Lease   Agreement\t");
  check(t.size() == 2 && t[0] == "lease" && t[1] == "agreement", "split and fold");
  check(splitQuery("   ").empty(), "blank is no terms");
}

void extensions() {
  check(extensionOf("Report.PDF") == "pdf", "extension lowercased");
  check(extensionOf(".bashrc").empty(), "a dotfile has no extension");
  check(extensionOf("archive.tar.gz") == "gz", "last dot wins");
  check(extensionOf("trailing.").empty(), "a trailing dot is no extension");
  check(categoryOf("mov") == Kind::videos, "mov is a video");
  check(categoryOf("pdf") == Kind::documents, "pdf is a document");
  check(categoryOf("xyz") == Kind::any, "unknown is no category");
}

void context() {
  const int64_t now = 1'760'000'000;
  check(contextBoost(now, now - 86400, 3, false) > contextBoost(now, 0, 3, false),
        "opened yesterday beats never opened");
  check(contextBoost(now, 0, 2, false) > contextBoost(now, 0, 9, false), "shallow beats deep");
  check(contextBoost(now, now, 0, false) < 100, "recency never crosses a tier");
}

void mountinfo() {
  const std::string table =
      "22 1 259:3 / / rw,relatime shared:1 - ext4 /dev/nvme0n1p3 rw\n"
      "98 22 0:52 / /mnt/windows ro,nosuid,nodev,relatime shared:50 - fuseblk /dev/nvme0n1p2 "
      "ro,user_id=0\n"
      "99 22 0:53 /sub /mnt/with\\040space rw - btrfs /dev/sda1 rw\n";
  const auto mounts = parseMountInfo(table);
  check(mounts.size() == 3, "three mounts parsed");
  const MountInfo *m = mountFor(mounts, "/mnt/windows/Learning");
  check(m && m->mountPoint == "/mnt/windows" && m->readOnly && m->fsType == "fuseblk",
        "the Windows partition, read-only");
  check(m && m->identity() == "/dev/nvme0n1p2 /", "identity is source and fs root");
  const MountInfo *h = mountFor(mounts, "/mnt/windowsish");
  check(h && h->mountPoint == "/", "a prefix is a path prefix, not a string one");
  const MountInfo *s = mountFor(mounts, "/mnt/with space/x");
  check(s && s->fsRoot == "/sub" && !s->readOnly, "octal escapes undone");
}

void xbel() {
  const std::string doc = R"(<?xml version="1.0" encoding="UTF-8"?>
<xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks">
  <bookmark href="file:///home/u/Documents/Lease%20Agreement.pdf" added="2026-08-30T10:00:00Z" modified="2026-08-30T10:00:00Z" visited="2026-08-30T10:00:00Z">
    <info><metadata owner="http://freedesktop.org"><bookmark:applications>
      <bookmark:application name="Evince" exec="&apos;evince %u&apos;" modified="2026-10-02T09:30:00.250000Z" count="3"/>
    </bookmark:applications></metadata></info>
  </bookmark>
  <bookmark href="https://example.com/" added="2026-08-30T10:00:00Z" modified="2026-08-30T10:00:00Z" visited="2026-08-30T10:00:00Z"/>
  <bookmark href="file:///tmp/a&amp;b.txt" added="2026-01-01T00:00:00Z" modified="2026-01-01T00:00:00Z" visited="2026-01-01T00:00:00Z"></bookmark>
</xbel>)";
  const auto files = parseXbel(doc);
  check(files.size() == 2, "http skipped, two files kept");
  if (files.size() == 2) {
    check(files[0].path == "/home/u/Documents/Lease Agreement.pdf", "percent-decoded");
    // 2026-10-02T09:30:00.25Z
    check(files[0].lastOpenNs == 1'790'933'400'250'000'000, "newest application time wins");
    check(files[1].path == "/tmp/a&b.txt", "entities decoded");
  }
}

}  // namespace

int main() {
  tiers();
  positions();
  queries();
  extensions();
  context();
  mountinfo();
  xbel();
  if (failures) std::printf("%d failure(s)\n", failures);
  else std::printf("ok\n");
  return failures ? 1 : 0;
}
