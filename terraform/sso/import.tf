data "authentik_brand" "default" {
  default = true
}

import {
  id = data.authentik_brand.default.id
  to = authentik_brand.default
}
