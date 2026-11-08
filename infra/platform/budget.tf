# Subscription budget: email alerts only. Azure Pay-As-You-Go has no hard cap.
resource "azurerm_consumption_budget_subscription" "main" {
  name            = "my_budget"
  subscription_id = data.azurerm_subscription.current.id
  amount          = var.budget_amount_brl
  time_grain      = "Monthly"

  time_period {
    start_date = "2026-03-01T00:00:00Z"
    end_date   = "2028-02-29T00:00:00Z"
  }

  notification {
    threshold_type = "Forecasted"
    operator       = "GreaterThan"
    threshold      = 85
    contact_emails = var.budget_contact_emails
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      threshold_type = "Actual"
      operator       = "GreaterThanOrEqualTo"
      threshold      = notification.value
      contact_emails = var.budget_contact_emails
    }
  }
}
