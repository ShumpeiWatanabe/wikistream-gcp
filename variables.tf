variable "project_id" {
  type        = string
  description = "GCP project id"
  default     = "shumpei-project"
}

variable "region" {
  type        = string
  description = "Cloud Run region"
  default     = "asia-northeast1" # Tokyo
}

variable "service_name" {
  type        = string
  description = "Cloud Run service name"
  default     = "hello-cloudrun"
}