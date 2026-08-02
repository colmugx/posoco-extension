// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "colmugx/posoco-ext-fs-session"

version = "0.1.0"

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = [ "posoco", "session", "fs", "jsonl", "store", "bun" ]

preferred_target = "native"

description = "Posoco JSONL File Session Store — persistent session storage via JSONL files, dual-target (native + bun-js)"

import {
  "colmugx/posoco@0.7.2",
  "moonbitlang/async@0.20.3",
  "moonbitlang/x@0.4.46",
}
