// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "colmugx/posoco-ext-fs-session"

version = "0.3.0"

readme = "README.mbt.md"

repository = "https://github.com/colmugx/posoco-extension"

license = "Apache-2.0"

keywords = [ "posoco", "session", "fs", "jsonl", "store", "bun" ]

preferred_target = "native"

description = "Posoco JSONL File Session Store"

import {
  "colmugx/posoco@0.14.3",
  "colmugx/posoco-devkit@0.2.0",
  "moonbitlang/async@0.21.0",
  "moonbitlang/x@0.4.50",
}
