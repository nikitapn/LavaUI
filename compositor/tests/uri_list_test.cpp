// What a dropped URI list has to survive.
//
// The list is written by whichever application the user dragged from, and the
// interesting cases are all things real senders do rather than things anybody
// designed: CRLF endings, percent-escapes for every space in a filename,
// `localhost` in the authority, a trailing blank line, and a browser dragging
// an http URL into a window that only wants files.

#include "uri_list.hpp"

#include <cstdio>
#include <string>
#include <vector>

using lava::paths_from_uri_list;

namespace {

int failures = 0;

void expect(const std::string &text, const std::vector<std::string> &want,
            const std::string &what) {
  const std::vector<std::string> got = paths_from_uri_list(text);
  if (got == want) return;
  std::printf("FAIL: %s\n  got: ", what.c_str());
  for (const std::string &p : got) std::printf("[%s] ", p.c_str());
  std::printf("\n want: ");
  for (const std::string &p : want) std::printf("[%s] ", p.c_str());
  std::printf("\n");
  ++failures;
}

void theOrdinaryCase() {
  expect("file:///tmp/a.png\r\n", {"/tmp/a.png"}, "one file, CRLF");
  expect("file:///tmp/a.png\n", {"/tmp/a.png"}, "one file, LF only");
  expect("file:///tmp/a.png", {"/tmp/a.png"}, "one file, no newline at all");
  expect("file:///tmp/a.png\r\nfile:///tmp/b.png\r\n",
         {"/tmp/a.png", "/tmp/b.png"}, "two files keep their order");
}

void escapesAreDecoded() {
  expect("file:///tmp/my%20photo.jpg\r\n", {"/tmp/my photo.jpg"},
         "a space arrives as %20");
  expect("file:///tmp/%C3%A9t%C3%A9.jpg\r\n", {"/tmp/\xC3\xA9t\xC3\xA9.jpg"},
         "UTF-8 survives byte by byte");
  expect("file:///tmp/a%2Fb.png\r\n", {"/tmp/a/b.png"},
         "an escaped slash decodes like any other byte");
  // Senders that do not escape at all are common enough to matter, and a file
  // really can be called "100%".
  expect("file:///tmp/100%.txt\r\n", {"/tmp/100%.txt"},
         "a stray percent stays a percent");
  expect("file:///tmp/a%zz.txt\r\n", {"/tmp/a%zz.txt"},
         "so does one followed by things that are not hex");
  expect("file:///tmp/a%2.txt\r\n", {"/tmp/a%2.txt"},
         "and one cut short at the end of the line");
}

void authoritiesAreHandled() {
  expect("file://localhost/tmp/a.png\r\n", {"/tmp/a.png"},
         "localhost means this machine");
  expect("file://otherhost/tmp/a.png\r\n", {},
         "a real host is not a local path and is refused");
}

void everythingElseIsIgnored() {
  expect("# some comment\r\nfile:///tmp/a.png\r\n", {"/tmp/a.png"},
         "comments are skipped");
  expect("\r\n\r\nfile:///tmp/a.png\r\n\r\n", {"/tmp/a.png"},
         "blank lines are skipped");
  expect("https://example.com/a.png\r\n", {},
         "a dragged web URL is not a file");
  expect("file:///tmp/a.png\r\nhttps://example.com/b.png\r\n",
         {"/tmp/a.png"}, "a mixed list keeps only what is local");
  expect("", {}, "nothing in, nothing out");
  expect("file://\r\n", {}, "a scheme with no path at all");
  expect("file:///\r\n", {"/"}, "the root is a path, if an odd one");
  expect("garbage", {}, "text that is not a URI list");
}

void hostileInputIsRefused() {
  // A NUL truncates a path in every API that will receive one, so a sender
  // that embeds one is naming a different file than it appears to.
  expect("file:///tmp/a%00b.png\r\n", {}, "an embedded NUL drops the path");

  // Not a security property, just a shape: a very long line must come back
  // whole or not at all, never half-decoded.
  std::string longName(4096, 'x');
  expect("file:///tmp/" + longName + "\r\n", {"/tmp/" + longName},
         "a long path survives intact");
}

}  // namespace

int main() {
  theOrdinaryCase();
  escapesAreDecoded();
  authoritiesAreHandled();
  everythingElseIsIgnored();
  hostileInputIsRefused();

  if (failures == 0) std::printf("uri list: all checks passed\n");
  return failures == 0 ? 0 : 1;
}
