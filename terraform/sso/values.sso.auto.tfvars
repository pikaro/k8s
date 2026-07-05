branding = {
  title = "authentik"
}

certificate = {
  common_name  = "sso.d-reis.com"
  organization = "d-reis.com"
}

users = {
  root = {
    name   = "Root User"
    email  = "root@d-reis.com"
    groups = ["superusers", "global-admins"]
  }

  pikaro = {
    name   = "David Reis"
    email  = "post@d-reis.com"
    groups = ["global-users", "personal-mcp-users"]
  }
}

groups = {
  superusers = {
    superuser = true
  }

  global-admins = {}
  global-users  = {}

  personal-mcp-users = {}
}

custom_group_properties = {
  is_global_admin = {
    groups = ["global-admins"]
  }
}
