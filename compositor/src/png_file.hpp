#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace lava {

/// Writes `png` to a fresh file under the temporary directory and answers with
/// its path.
///
/// How a picture crosses a process boundary here. A shared-memory reply is
/// capped at half a megabyte and a screenful of PNG is past that, so the two
/// calls that hand one over — the screenshot portal to its D-Bus caller, and
/// `CaptureScreen` to a Lava client — both write a file and pass the name.
/// Both processes are on the same filesystem; the file *is* the transfer.
///
/// The file belongs to whoever receives the path. Nothing here deletes it.
bool writeTempPng(const std::vector<uint8_t> &png, std::string &outPath);

/// The whole of a file, or false. For the other direction: a caller that was
/// handed a path and has to turn it back into bytes.
bool readFileBytes(const std::string &path, std::vector<uint8_t> &out);

}  // namespace lava
