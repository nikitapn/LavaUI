; Indentation for C. The captures are described in IndentQuery.swift.

; Brace bodies: after the line a brace opened on, the body's indentation is
; the user's. An ERROR is here because a half-typed block is one.
[
  (compound_statement)
  (field_declaration_list)
  (declaration_list)
  (ERROR)
] @indent.block

; Lists continue one level past the line they opened on, braces included:
; an initializer list's elements are not statements.
[
  (initializer_list)
  (enumerator_list)
  (argument_list)
  (parameter_list)
  (parenthesized_expression)
  (parenthesized_declarator)
  (subscript_expression)
  (array_declarator)
  (for_statement)
] @indent.scope

; A case label's statements are a level past the label.
(case_statement ":" @indent.after) @indent.anchor

[
  (string_literal)
  (char_literal)
  ; Error recovery can lift a literal's contents out of its string node.
  (string_content)
] @indent.ignore

(comment) @indent.comment
