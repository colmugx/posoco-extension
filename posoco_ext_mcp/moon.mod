name = "colmugx/posoco-ext-mcp"

version = "0.1.0"

import {
  "colmugx/posoco@0.4.0",
  "moonbitlang/async@0.20.0",
  "colmugx/mcp@0.14.0",
}

readme = "README.mbt.md"

license = "Apache-2.0"

keywords = [ "posoco", "mcp", "model-context-protocol", "tool" ]

description = "Posoco MCP Extension — connects to MCP servers as a unified ToolProvider"

options(
  preferred_target: "native",
)