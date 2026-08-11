# Used by "mix format"
[
  plugins: [Styler],
  # test/fixtures is deliberately NOT an input: those migrations are corpus
  # data standing in for user-written files — golden outputs and parser tests
  # anchor to their exact line numbers, and Styler would inject
  # @moduledoc false into them. (mix.exs test_ignore_filters excludes the
  # same tree from ExUnit discovery.)
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib}/**/*.{ex,exs}",
    "test/*.exs",
    "test/{cerbero,integration,support}/**/*.{ex,exs}"
  ]
]
