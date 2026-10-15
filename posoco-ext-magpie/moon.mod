name = "colmugx/posoco-ext-magpie"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/colmugx/posoco-extension"

license = "Apache-2.0"

keywords = [ "posoco", "magpie", "gateway", "model-manager", "control-plane" ]

description = "Posoco Magpie extension - Gateway-aware Model Manager with typed catalog metadata, protocol planning, and multi-protocol ModelPort execution"

source = "src"

import {
  "colmugx/posoco@0.22.1",
  "colmugx/posoco-kit-model-management@0.1.0",
  "colmugx/posoco-kit-messages@0.1.0",
  "colmugx/posoco-kit-responses@0.1.0",
  "posoco/kit-chat-completions@0.1.0",
  "colmugx/posoco-kit-rate-limit@0.1.0",
  "colmugx/posoco-kit-compact-summary@0.1.0",
  "moonbitlang/async@0.22.4",
}
