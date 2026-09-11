#pragma once

#include <string>
#include <vector>

namespace lava {

/// The local paths in a `text/uri-list`, which is how every desktop drags a
/// file.
///
/// One URI per line, CRLF endings, `#` for a comment — RFC 2483. Only
/// `file://` becomes a path: dragging an http URL out of a browser is a real
/// thing that happens, and handing that to a caller expecting a filename, as
/// if it were one, is worse than dropping it.
///
/// Percent-decoded, because a file called `my photo.jpg` arrives as
/// `my%20photo.jpg` and opening that opens nothing. The authority is skipped
/// rather than checked: `file:///tmp/x` and `file://localhost/tmp/x` are the
/// same file, and no other authority is a local path at all.
std::vector<std::string> paths_from_uri_list(const std::string &text);

/// The inverse of `paths_from_uri_list`: local paths as a `text/uri-list`.
///
/// Absolute paths only — a relative one would become an authority after
/// `file://`, which is not a file and which `paths_from_uri_list` would
/// then refuse. Percent-encoded, because a space in a filename has to
/// survive a pipe to a client that decodes RFC 2483.
std::string uri_list_from_paths(const std::vector<std::string> &paths);

}  // namespace lava
