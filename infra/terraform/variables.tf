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

variable "db_name" {
  description = "Nombre de la base de datos"
  type        = string
  default     = "events"
}

variable "db_username" {
  description = "Usuario administrador de la base de datos"
  type        = string
  default     = "events_user"
}

variable "db_password" {
  description = "Password administrador de la base de datos"
  type        = string
  sensitive   = true
  default     = null
}

variable "create_nat" {
  description = "Indica si se debe crear una NAT Gateway para dar salida a Internet a las subredes privadas"
  type        = bool
  default     = false
}

variable "create_rds" {
  description = "Indica si se debe crear la instancia RDS PostgreSQL"
  type        = bool
  default     = false
}

variable "create_eks" {
  description = "Indica si se debe crear el cluster EKS y su node group"
  type        = bool
  default     = false
}
