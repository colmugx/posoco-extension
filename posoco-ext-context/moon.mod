name = "colmugx/posoco-ext-context"

version = "0.2.0"

import {
  "colmugx/posoco@0.20.1",
  "posoco/devkit@0.4.1",
  "colmugx/posoco-ext-workspace@0.1.0",
  "moonbitlang/async@0.22.4",
}

readme = "README.mbt.md"

license = "Apache-2.0"

keywords = [ "posoco", "context", "agents-md", "system-prompt" ]

description = "Posoco context loader — discovers and loads AGENTS.md / CLAUDE.md from a global + workspace ancestor chain and renders them through a caller-configured prompt envelope"

source = "src"
