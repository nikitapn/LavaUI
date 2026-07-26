#!/usr/bin/env python3
import os
import re

# Match PascalCase identifiers followed by "("
# Exclude cases:
#  - after keywords like class/struct/enum
#  - when they appear at start of line
func_pattern = re.compile(
    r'(?<!class\s)(?<!struct\s)(?<!enum\s)(?<!new\s)(?<!delete\s)(?<!ImGui::)(?<!~)(?<!return\s)\b([A-Z][a-zA-Z0-9_]*)\s*\('
)

def pascal_to_camel(name: str) -> str:
    return name[0].lower() + name[1:] if name else name

def process_file(path: str, dry_run=True):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    lines = content.splitlines()
    new_lines = []
    changed = False

    for line in lines:
        stripped = line.lstrip()

        # Skip identifiers at beginning of line that are PascalCase
        if re.match(r'^[A-Z][a-zA-Z0-9_]*\s*\(', stripped):
            new_lines.append(line)
            continue

        # Replace PascalCase function calls/definitions
        new_line = func_pattern.sub(
            lambda m: pascal_to_camel(m.group(1)) + "(",
            line
        )
        if new_line != line:
            changed = True
        new_lines.append(new_line)

    if changed:
        if dry_run:
            print(f"[Would update] {path}")
        else:
            with open(path, "w", encoding="utf-8") as f:
                f.write("\n".join(new_lines) + "\n")
            print(f"Updated: {path}")

def walk_project(root: str, dry_run=True):
    for subdir, _, files in os.walk(root):
        for file in files:
            if file.endswith((".cpp", ".h", ".hpp", ".cc")):
                process_file(os.path.join(subdir, file), dry_run)

if __name__ == "__main__":
    # First run with dry_run=True to preview changes
    walk_project(".", dry_run=True)
