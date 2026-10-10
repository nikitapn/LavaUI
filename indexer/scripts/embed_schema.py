#!/usr/bin/env python3
"""schema.sql -> a header holding it as one string, so the daemon cannot run
against a schema file that is not the one it was built with."""
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    sql = f.read()
assert ')sql"' not in sql
with open(dst, "w", encoding="utf-8") as f:
    f.write("// Generated from indexer/schema.sql by embed_schema.py. Do not edit.\n")
    f.write("#pragma once\n\nnamespace lava::indexer {\n")
    f.write('inline constexpr const char *kSchemaSql = R"sql(' + sql + ')sql";\n')
    f.write("}  // namespace lava::indexer\n")
