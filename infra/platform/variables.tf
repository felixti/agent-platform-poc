variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "resource_group_name" {
  type    = string
  default = "aks-lab"
}

variable "cluster_name" {
  type    = string
  default = "aks-lab"
}

variable "budget_amount_brl" {
  description = "Monthly subscription budget (alerts only, not a hard cap)."
  type        = number
  default     = 450
}

variable "budget_contact_emails" {
  type = list(string)
}

variable "schedule_timezone" {
  type    = string
  default = "America/Sao_Paulo"
}

variable "schedule_weekdays" {
  type    = list(string)
  default = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
}

variable "schedule_start_time" {
  description = "Local time (HH:MM) at which the cluster is started on schedule days."
  type        = string
  default     = "08:00"
}

variable "schedule_stop_time" {
  description = "Local time (HH:MM) at which the cluster is stopped on schedule days."
  type        = string
  default     = "21:00"
}

variable "platform_pool_vm_size" {
  description = "On-demand pool for platform services (gateway, Postgres, Valkey, Argo CD, brains)."
  type        = string
  default     = "Standard_D2ds_v5"
}

variable "sandbox_pool_vm_size" {
  description = "Kata (Pod Sandboxing) pool. Must support nested virtualization; B-series does not."
  type        = string
  default     = "Standard_D2ds_v5"
}

variable "sandbox_pool_spot" {
  description = "Run the sandbox pool on Spot VMs (cheap, evictable)."
  type        = bool
  default     = true
}

variable "sandbox_pool_max_count" {
  type    = number
  default = 1
}

variable "tags" {
  type = map(string)
  default = {
    purpose = "lab"
    project = "agent-platform-poc"
  }
}

variable "schedule_start_enabled" {
  description = "Start the cluster automatically on schedule days."
  type        = bool
  default     = false
}

variable "schedule_stop_enabled" {
  description = "Stop the cluster automatically on schedule days (safety net)."
  type        = bool
  default     = true
}
