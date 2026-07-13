# ─── Service account ───
resource "yandex_iam_service_account" "budget_explorer" {
  name = "budget-explorer"
}
