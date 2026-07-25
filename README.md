# Demo CI/CD DevSecOps

Projet pédagogique : une chaîne CI/CD DevSecOps 100% open source, orchestrée
par GitHub Actions, qui déploie un site statique nginx sur une infrastructure
AWS minimaliste via Terraform.

> L'instance n'a pas d'IP fixe (pas d'Elastic IP, hors scope du POC) : elle
> change à chaque recréation. Récupère l'URL courante avec
> `terraform output site_url` (voir [`infra/README.md`](infra/README.md)).

## Objectif

Illustrer, sur un cas volontairement simple (un seul serveur, un seul
environnement), les pratiques DevSecOps de base d'une chaîne CI/CD :
Infrastructure as Code versionnée, authentification cloud sans secret
statique, scan de sécurité automatisé, gate d'approbation manuelle avant
déploiement en production. Ce n'est **pas** un design de production à haute
disponibilité — pas de load balancer, pas d'auto-scaling, un seul serveur.

## Architecture

```
GitHub Actions (OIDC, aucune clé AWS stockée)
        │
        ▼
   Terraform (infra/)
        │
        ▼
┌─────────────────────────────────────────┐
│ AWS eu-west-3 (Paris)                    │
│                                           │
│  VPC (1 subnet public)                   │
│   └── EC2 t3.micro                       │
│        ├── nginx (sert /site)            │
│        ├── agent CloudWatch → logs nginx │
│        └── SSM Agent (accès sans SSH)    │
│                                           │
│  Security group : port 80 uniquement     │
│  IAM : rôle OIDC GitHub Actions,         │
│        rôle instance EC2 (SSM + logs)    │
└─────────────────────────────────────────┘
```

## Structure du dépôt

| Chemin | Contenu |
|---|---|
| [`site/`](site/) | Fichiers statiques du site servi par nginx |
| [`infra/`](infra/) | Terraform : réseau, IAM/OIDC, EC2, CloudWatch Logs, backend S3+DynamoDB. Détails, bootstrap et secrets à configurer : [`infra/README.md`](infra/README.md) |
| [`.github/workflows/terraform-infra.yml`](.github/workflows/terraform-infra.yml) | Pipeline CI/CD : Checkov, plan Terraform (+ commentaire de PR), apply gaté par approbation manuelle |

## Pipeline CI/CD

Déclenché sur toute PR ou push `main` touchant `infra/` ou `site/` :

1. **Checkov** — analyse statique de sécurité de l'infra Terraform (non
   bloquant pour l'instant, résultats dans l'onglet *Security*).
2. **Terraform Plan** — authentification AWS via OIDC (aucune clé statique),
   plan commenté automatiquement sur la PR.
3. **Terraform Apply** — uniquement sur `main`, derrière une approbation
   manuelle (GitHub Environment `prod`), applique exactement le plan
   revu à l'étape précédente.

## Sécurité et gouvernance

- **Pas de clé d'accès AWS statique** : authentification GitHub Actions →
  AWS via OpenID Connect (rôle IAM à assumer).
- **Pas de SSH** : accès administratif à l'instance via AWS Systems Manager
  Session Manager uniquement (aucun port 22 ouvert, aucune clé SSH stockée).
- **Moindre privilège** : la policy IAM du rôle GitHub Actions liste
  explicitement chaque action nécessaire, sans wildcard.
- **État Terraform** : backend S3 chiffré + verrouillage DynamoDB.
- **Tagging obligatoire** : `environment`, `project`, `owner` sur toutes les
  ressources.

Détails complets, valeurs à configurer toi-même, et mécanisme de mise à jour
du contenu statique : voir [`infra/README.md`](infra/README.md).
