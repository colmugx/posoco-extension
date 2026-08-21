name = "colmugx/posoco-ext-context"

version = "0.2.0"

import {
  "colmugx/posoco@0.10.2",
  "colmugx/posoco-devkit@0.1.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "moonbitlang/async@0.21.0",
}

readme = "README.mbt.md"

license = "Apache-2.0"

keywords = [ "posoco", "context", "agents-md", "system-prompt" ]

description = "Posoco context loader — discovers and loads AGENTS.md / CLAUDE.md from a global + workspace ancestor chain and renders them through a caller-configured prompt envelope"

source = "src"
