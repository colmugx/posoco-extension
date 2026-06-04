name = "colmugx/posoco_ext_rtk"

version = "0.1.0"

import {
  "colmugx/posoco@0.3.0",
  "moonbitlang/async@0.19.1",
}

readme = "README.mbt.md"

license = "Apache-2.0"

keywords = [ "posoco", "rtk", "hook", "pipeline", "ai-agent" ]

description = "RTK extension for Posoco — PipelineHook that rewrites shell commands through the rtk subprocess to reduce LLM token consumption"

preferred_target = "native"

options(
  source: "src",
)
