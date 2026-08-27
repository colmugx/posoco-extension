name = "colmugx/posoco-ext-credentials"

version = "0.1.0"

import {
  "colmugx/posoco@0.13.0",
  "colmugx/posoco-ext-oauth@0.1.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "moonbitlang/async@0.21.0",
}

readme = "README.mbt.md"

license = "Apache-2.0"

keywords = [ "posoco", "credentials", "oauth", "persistence", "storage" ]

description = "Posoco provider-credential persistence — backend-neutral tagged-record codec plus a WorkspaceFs file backend. The storage boundary is @oauth.ProviderCredentialStore; OS secret-manager backends plug in through the same trait."

source = "src"
