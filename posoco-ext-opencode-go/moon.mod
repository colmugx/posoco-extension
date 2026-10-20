name = "colmugx/posoco-ext-opencode-go"

version = "0.1.0"

import {
  "colmugx/posoco@0.22.3",
  "colmugx/posoco-ext-opencode-zen@0.2.0",
  "posoco/devkit@0.4.1",
  "colmugx/posoco-kit-rate-limit@0.1.0",
  "posoco/ext-llm@0.2.0",
  "posoco/ext-oauth@0.1.0",
  "moonbitlang/async@0.22.5",
}

readme = "README.mbt.md"

license = "Apache-2.0"

keywords = [
  "posoco",
  "opencode",
  "go",
  "subscription",
  "quota",
  "model-port",
  "provider-factory",
  "llm",
]

description = "Posoco OpenCode Go extension — subscription-quota provider over the shared OpenCode multi-protocol wire, with the /usage three-window quota, plan allowances, and typed rate-limit recovery"

source = "src"
