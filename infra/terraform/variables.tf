variable "aws_region" {
  description = "Región de AWS"
  type        = string
  default     = "eu-south-2"
}

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
  default     = "tfm-app"
}

variable "environment" {
  description = "Entorno del despliegue"
  type        = string
  default     = "base"
}