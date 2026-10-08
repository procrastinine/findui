#!/bin/bash
# Source from release build scripts after selecting CARGO_HOME. Encoded flags
# preserve paths containing spaces and any caller-provided compiler options.
export CARGO_ENCODED_RUSTFLAGS="$(ruby -rshellwords -e '
  flags = if ENV.key?("CARGO_ENCODED_RUSTFLAGS")
    ENV.fetch("CARGO_ENCODED_RUSTFLAGS").split("\x1f")
  else
    Shellwords.split(ENV.fetch("RUSTFLAGS", ""))
  end
  [[Dir.home, "/build"], [ENV.fetch("CARGO_HOME"), "/cargo"], [Dir.pwd, "/src/FindUI"]].each do |from, to|
    flags << "--remap-path-prefix=#{from}=#{to}"
  end
  print flags.join("\x1f")
')"
