; inherits: c
; C++ on top of C's rules.

[
  (subscript_argument_list)
  (condition_clause)
  (template_argument_list)
  (template_parameter_list)
] @indent.scope

; `public:` — the members after it are a level past it. `_` does not match
; an ERROR, and a class still being typed has no closing brace yet.
(_ (access_specifier) @indent.anchor . ":" @indent.after)
(ERROR (access_specifier) @indent.anchor . ":" @indent.after)

[
  (raw_string_literal)
  (raw_string_content)
] @indent.ignore
