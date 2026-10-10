#pragma once

#include <archive.h>
#include <archive_entry.h>

// The `AE_IF*` file types are casts in the header, which Swift does not
// import. Restated as plain constants so a switch on `archive_entry_filetype`
// can name them.
enum {
  LAVA_AE_IFMT = 0170000,
  LAVA_AE_IFREG = 0100000,
  LAVA_AE_IFLNK = 0120000,
  LAVA_AE_IFDIR = 0040000,
};
