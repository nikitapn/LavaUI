; Indentation for Python. The captures are described in IndentQuery.swift.

; Bracketed continuations: one level past the line the bracket opened on,
; back to it before the closer.
[
  (argument_list)
  (parameters)
  (tuple)
  (parenthesized_expression)
  (list)
  (dictionary)
  (set)
  (subscript)
  (list_comprehension)
  (dictionary_comprehension)
  (set_comprehension)
  (generator_expression)
  (ERROR)
] @indent.scope

; A colon that opens a suite: the suite is a level past the line the
; statement began on, not the line the colon is on (`def f(\n  a,\n):`).
; A colon with no block after it — a lambda, an annotation, a slice — is not.
(_ ":" @indent.after (block)) @indent.anchor

(string) @indent.ignore

; An unterminated quote: what follows it on the line is not code, however
; much of it recovery parsed as some.
(ERROR . (string_start)) @indent.open_string

(comment) @indent.comment
