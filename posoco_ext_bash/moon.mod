name = "colmugx/posoco_ext_bash"

version = "0.1.0"

import {
  "colmugx/posoco@0.3.0",
  "moonbitlang/async@0.19.1",
}

readme = "README.mbt.md"

license = "Apache-2.0"

keywords = [ "posoco", "shell", "tool", "bash" ]

description = "Posoco Shell Tool Extension — provides bash/command execution as a unified ToolProvider"

options(
  preferred_target: "native",
)