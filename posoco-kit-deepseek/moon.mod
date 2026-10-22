name = "colmugx/posoco-kit-deepseek"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/colmugx/posoco-extension"

license = "Apache-2.0"

keywords = [ "posoco", "deepseek", "reasoning", "prefix-cache", "kit" ]

description = "Posoco DeepSeek kit — the client-side half of DeepSeek's serving contract: prefix-stable tool order and tail guidance, reasoning budget and collapse guards, bounded nonstream recovery, and one shared settings parser"

source = "src"

import {
  "colmugx/posoco@0.22.3",
  "posoco/devkit@0.4.1",
  "moonbitlang/async@0.22.5",
}
