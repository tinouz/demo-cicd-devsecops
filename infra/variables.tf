# -----------------------------------------------------------------------------
# Général / tagging
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "Région AWS de déploiement."
  type        = string
  default     = "eu-west-3"
}

variable "project_name" {
  description = "Nom du projet, utilisé comme préfixe de nommage et dans le tag `project`. À renseigner (pas de valeur générique par défaut)."
  type        = string
}

variable "owner" {
  description = "Propriétaire/responsable des ressources, utilisé dans le tag `owner` (ex: ton nom ou ton équipe)."
  type        = string
}

# -----------------------------------------------------------------------------
# Réseau
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "Bloc CIDR du VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Bloc CIDR du sous-réseau public unique."
  type        = string
  default     = "10.0.1.0/24"
}

# -----------------------------------------------------------------------------
# Compute
# -----------------------------------------------------------------------------

variable "instance_type" {
  description = "Type d'instance EC2. t3.micro par défaut (éligible free tier)."
  type        = string
  default     = "t3.micro"
}

variable "log_retention_days" {
  description = "Durée de rétention des logs CloudWatch (nginx)."
  type        = number
  default     = 7
}

# -----------------------------------------------------------------------------
# GitHub Actions / OIDC
# -----------------------------------------------------------------------------

variable "github_repository" {
  description = "Dépôt GitHub au format \"organisation-ou-utilisateur/nom-du-repo\" (ex: \"mon-org/demo-cicd\"). Utilisé pour restreindre le rôle OIDC à ce dépôt et pour cloner le site statique depuis l'instance EC2. Le dépôt doit être public pour que le clonage via HTTPS fonctionne sans identifiants."
  type        = string
}

variable "github_oidc_subject" {
  description = "Filtre du claim `sub` du token OIDC GitHub autorisé à assumer le rôle. Par défaut, restreint à toutes les refs du dépôt indiqué (branches, tags, PRs). Resserre par exemple à \"repo:org/repo:ref:refs/heads/main\" pour limiter au seul déploiement depuis `main`."
  type        = string
  default     = null
}

variable "create_github_oidc_provider" {
  description = "Si true, crée le fournisseur OIDC IAM `token.actions.githubusercontent.com`. AWS n'autorise qu'un seul fournisseur par URL et par compte : mets à false si ce fournisseur existe déjà dans ton compte (auquel cas il est référencé via une data source)."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Backend d'état (utilisées uniquement pour scoper précisément la policy IAM
# du rôle GitHub Actions sur le bucket S3 et la table DynamoDB du backend ;
# doivent correspondre aux valeurs passées à `terraform init -backend-config`)
# -----------------------------------------------------------------------------

variable "state_bucket_name" {
  description = "Nom du bucket S3 utilisé comme backend d'état Terraform (doit correspondre à la valeur `bucket` fournie à `terraform init`)."
  type        = string
}

variable "state_bucket_key" {
  description = "Clé (chemin) de l'objet d'état dans le bucket S3 (doit correspondre à la valeur `key` fournie à `terraform init`)."
  type        = string
  default     = "demo-cicd/prod/terraform.tfstate"
}

variable "state_lock_table_name" {
  description = "Nom de la table DynamoDB utilisée pour le verrouillage d'état (doit correspondre à la valeur `dynamodb_table` fournie à `terraform init`)."
  type        = string
}
