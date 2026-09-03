name = "colmugx/posoco-ext-ratelimit"

version = "0.3.0"

import {
  "colmugx/posoco@0.14.3",
  "colmugx/posoco-devkit@0.3.0",
  "moonbitlang/async@0.21.0",
}

readme = "README.mbt.md"

license = "Apache-2.0"

keywords = [ "posoco", "rate-limit", "429", "auto-resume", "coding-plan" ]

description = "Posoco rate-limit guard extension - records 429 quota resets per session and auto-resumes the interrupted turn when the provider-stated reset time arrives"

source = "src"
