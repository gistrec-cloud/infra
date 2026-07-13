# ─── Managed MySQL: one shared cluster, many per-app databases and users ───

resource "yandex_mdb_mysql_cluster" "projects" {
  name                = "projects"
  environment         = "PRODUCTION"
  network_id          = var.network_id
  version             = "8.0"
  deletion_protection = true

  backup_retain_period_days = 60
  security_group_ids        = []
  host_group_ids            = []
  labels                    = {}

  mysql_config = {
    binlog_transaction_dependency_tracking = "0"
    sql_mode                               = "ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"
  }

  resources {
    resource_preset_id = "b2.medium"
    disk_type_id       = "network-hdd"
    disk_size          = 50
  }

  access {
    data_lens     = true
    data_transfer = false
    web_sql       = true
    yandex_query  = false
  }

  backup_window_start {
    hours   = 22
    minutes = 0
  }

  performance_diagnostics {
    enabled                      = true
    sessions_sampling_interval   = 60
    statements_sampling_interval = 180
  }

  maintenance_window {
    day  = "MON"
    hour = 2
    type = "WEEKLY"
  }

  host {
    zone             = var.zone
    subnet_id        = var.subnet_id
    assign_public_ip = true
  }
}

# ─── Databases ───
locals {
  mysql_databases = toset([
    "askads",
    "budget-explorer",
    "clear-transcript-bot",
    "clear-transcript-bot-test",
    "dnd-crime",
    "eve-contracts",
    "food-scraper",
    "libre",
    "linkreach",
    "loquia",
    "realmctl",
    "recepter",
    "vk-ads-tool",
    "vk-ads-tool-test",
    "wordpress",
  ])
}

resource "yandex_mdb_mysql_database" "this" {
  for_each = local.mysql_databases

  cluster_id = yandex_mdb_mysql_cluster.projects.id
  name       = each.value
}

# ─── Users ───
# password is a required field but cannot be read back from MySQL, so every user
# carries a placeholder and `ignore_changes = [password]` — without this an apply
# would rotate every production user's password to the placeholder.
locals {
  mysql_users = {
    "askads"                    = { global_permissions = [], permissions = [{ database_name = "askads", roles = ["ALL"] }] }
    "budget-explorer"           = { global_permissions = [], permissions = [{ database_name = "budget-explorer", roles = ["ALL"] }] }
    "clear-transcript-bot"      = { global_permissions = [], permissions = [{ database_name = "clear-transcript-bot", roles = ["ALL"] }] }
    "clear-transcript-bot-ro"   = { global_permissions = [], permissions = [{ database_name = "clear-transcript-bot", roles = ["SELECT"] }] }
    "clear-transcript-bot-test" = { global_permissions = [], permissions = [{ database_name = "clear-transcript-bot-test", roles = ["ALL"] }] }
    "dnd-crime"                 = { global_permissions = [], permissions = [{ database_name = "dnd-crime", roles = ["ALL"] }] }
    "eve-contracts"             = { global_permissions = [], permissions = [{ database_name = "eve-contracts", roles = ["ALL"] }] }
    "food-scraper"              = { global_permissions = [], permissions = [{ database_name = "food-scraper", roles = ["ALL"] }] }
    "libre"                     = { global_permissions = [], permissions = [{ database_name = "libre", roles = ["ALL"] }] }
    "linkreach"                 = { global_permissions = [], permissions = [{ database_name = "linkreach", roles = ["ALL"] }] }
    "loquia"                    = { global_permissions = [], permissions = [{ database_name = "loquia", roles = ["ALL"] }] }
    "loquia-ro"                 = { global_permissions = [], permissions = [{ database_name = "loquia", roles = ["SELECT"] }] }
    "realmctl"                  = { global_permissions = [], permissions = [{ database_name = "realmctl", roles = ["ALL"] }] }
    "recepter"                  = { global_permissions = [], permissions = [{ database_name = "recepter", roles = ["ALL"] }] }
    "stats"                     = { global_permissions = ["PROCESS", "REPLICATION_CLIENT", "SHOW_ROUTINE"], permissions = [] }
    "vk-ads-tool"               = { global_permissions = [], permissions = [{ database_name = "vk-ads-tool", roles = ["ALL"] }] }
    "vk-ads-tool-test"          = { global_permissions = [], permissions = [{ database_name = "vk-ads-tool-test", roles = ["ALL"] }] }
    "wordpress"                 = { global_permissions = [], permissions = [{ database_name = "wordpress", roles = ["ALL"] }] }
  }
}

resource "yandex_mdb_mysql_user" "this" {
  for_each = local.mysql_users

  cluster_id         = yandex_mdb_mysql_cluster.projects.id
  name               = each.key
  password           = "placeholder-ignored" # gitleaks:allow — never applied, see lifecycle below
  global_permissions = each.value.global_permissions

  dynamic "permission" {
    for_each = each.value.permissions
    content {
      database_name = permission.value.database_name
      roles         = permission.value.roles
    }
  }

  depends_on = [yandex_mdb_mysql_database.this]

  lifecycle {
    ignore_changes = [password]
  }
}
