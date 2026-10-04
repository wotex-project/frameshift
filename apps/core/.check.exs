[
  parallel: false,
  halt_on_failure: true,
  retry: false,
  skipped: false,
  tools: [
    {:compiler, command: "mix compile --warnings-as-errors"},
    {:deps_get, command: "mix deps.get --check-locked"},
    {:unused_deps, command: "mix deps.unlock --check-unused"},
    {:formatter, command: "mix format --check-formatted"},
    {:mix_audit, command: "mix deps.audit"},
    {:hex_audit, command: "mix hex.audit"},
    {:credo, command: "mix credo --strict"},
    {:doctor, command: "mix doctor --summary"},
    {:sobelow, false},
    {:ex_doc, command: "mix docs --warnings-as-errors"},
    {:ex_unit, false},
    {:coverage, command: "mix coveralls", env: %{"MIX_ENV" => "test"}},
    {:dialyzer, command: "mix dialyzer --force-check"},
    {:diff, command: "git diff --check"},
    {:gettext, false},
    {:npm_test, false}
  ]
]
