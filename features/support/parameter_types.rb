# frozen_string_literal: true

ParameterType(
  name: "symbol",
  regexp: /:\w+/,
  transformer: ->(s) { s[1..].to_sym }
)
