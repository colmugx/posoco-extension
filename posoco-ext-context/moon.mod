name = "colmugx/posoco-ext-context"

version = "0.1.0"

import {
  "colmugx/posoco@0.8.0",
  "colmugx/posoco-devkit@0.1.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "moonbitlang/async@0.20.3",
}

readme = "README.mbt.md"

license = "Apache-2.0"

keywords = [ "posoco", "context", "agents-md", "system-prompt" ]

description = "Posoco context loader — discovers and loads AGENTS.md / CLAUDE.md from global + workspace ancestor chain, exposes them as a SystemPromptContributor rendering <cetas-context> envelopes"

source = "src"
