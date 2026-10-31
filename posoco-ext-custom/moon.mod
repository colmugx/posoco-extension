name = "colmugx/posoco-ext-custom"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/colmugx/posoco-extension"

license = "Apache-2.0"

keywords = [
  "posoco",
  "custom-provider",
  "model-port",
  "chat-completions",
  "responses",
  "messages",
  "streaming",
]

description = "Posoco custom-provider extension — settings-declared arbitrary endpoints served on the Chat Completions, OpenAI Responses, or Anthropic Messages wire"

source = "src"

import {
  "colmugx/posoco@0.23.1",
  "posoco/devkit@0.4.1",
  "posoco/ext-llm@0.2.0",
  "posoco/ext-oauth@0.1.0",
  "posoco/kit-chat-completions@0.1.0",
  "colmugx/posoco-kit-responses@0.1.0",
  "colmugx/posoco-kit-messages@0.1.0",
  "colmugx/posoco-kit-rate-limit@0.1.0",
  "moonbitlang/async@0.22.5",
}
