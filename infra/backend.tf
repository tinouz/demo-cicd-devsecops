terraform {
  required_version = ">= 1.5.0"

  # Configuration de backend partielle et volontairement vide : aucune valeur
  # spécifique au compte AWS (nom de bucket, table DynamoDB...) n'est écrite
  # en dur dans ce dépôt.
  #
  # Les valeurs réelles sont fournies au moment du `terraform init`, soit :
  #   - en local, via un fichier infra/backend.hcl (non versionné, voir
  #     infra/backend.hcl.example) ;
  #   - en CI, via des flags -backend-config alimentés par des secrets/vars
  #     GitHub Actions.
  #
  # Voir infra/README.md pour le détail complet.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
