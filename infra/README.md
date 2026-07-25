# Infrastructure — POC EC2 + nginx (prod)

Infrastructure Terraform minimaliste pour héberger un site statique (`/site`
à la racine du dépôt) sur une seule instance EC2 nginx, dans un seul
environnement (`prod`). Pas de load balancer, pas d'auto-scaling : c'est un
POC pédagogique volontairement simple.

Fichiers : `backend.tf` (backend distant S3 + DynamoDB), `variables.tf`,
`main.tf` (réseau, IAM/OIDC, EC2, CloudWatch Logs), `outputs.tf`,
`templates/user_data.sh.tftpl` (provisioning de l'instance).

## Ce que tu dois renseigner toi-même

Aucun identifiant, ARN ou ID de compte AWS réel n'est présent dans ce code.
Avant tout `init`/`plan`, tu dois fournir :

| Où | Quoi |
|---|---|
| `terraform.tfvars` (copie de `terraform.tfvars.example`) | `project_name`, `owner`, `github_repository` (`org/repo`), `state_bucket_name`, `state_lock_table_name`, etc. |
| `backend.hcl` (copie de `backend.hcl.example`), ou secrets/vars GitHub Actions en CI | `bucket`, `key`, `region`, `dynamodb_table` du backend S3/DynamoDB |

`terraform.tfvars` et `backend.hcl` sont dans `.gitignore` : ne les committe
jamais.

### Bootstrap du backend (une seule fois, manuel)

Le bucket S3 et la table DynamoDB du backend ne sont **pas** créés par ce
code Terraform (problème classique de l'œuf et la poule : Terraform a besoin
d'un backend pour s'initialiser). Crée-les une fois, manuellement ou via un
petit script à part :

- Bucket S3 : versioning activé, chiffrement par défaut activé (SSE-S3 ou
  SSE-KMS), accès public entièrement bloqué (Block Public Access).
- Table DynamoDB : clé de partition `LockID` (type String), mode
  `PAY_PER_REQUEST` suffit pour un usage aussi faible.

## Lancer un plan en local

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # puis édite le fichier
cp backend.hcl.example backend.hcl              # puis édite le fichier

terraform init -backend-config=backend.hcl
terraform validate
terraform plan
```

Authentification AWS en local : utilise tes propres identifiants (profil
`~/.aws/credentials`, SSO, etc.) — l'authentification OIDC décrite plus bas
concerne uniquement GitHub Actions, pas l'usage local.

Aucune commande de ce README ne modifie de ressources AWS (`init`,
`validate`, `plan` uniquement). Un `terraform apply` reste une décision
volontaire, prise en dehors de ce document.

## Comment le pipeline l'exécute

Workflow : [`.github/workflows/terraform-infra.yml`](../.github/workflows/terraform-infra.yml).
Déclenché sur PR touchant `infra/**` ou `site/**` (plan) et sur push `main`
(plan + apply), plus `workflow_dispatch` manuel.

1. **`checkov`** — scanne `infra/` (voir plus bas). Non bloquant pour
   l'instant (`soft_fail: true`) : les résultats sont publiés dans l'onglet
   *Security > Code scanning*, pas de blocage du plan/apply. À durcir plus
   tard (seuil de sévérité) une fois le baseline de findings traité — c'est
   un choix délibéré de démarrage, pas un oubli.
2. **`terraform-plan`** — s'authentifie auprès d'AWS via **OIDC**
   (`aws-actions/configure-aws-credentials`, `role-to-assume:` le secret
   `AWS_GITHUB_ACTIONS_ROLE_ARN`, permission `id-token: write`) — aucune clé
   d'accès statique, aucun secret AWS long-lived dans GitHub. Exécute
   `terraform init -backend-config=...` avec les valeurs du backend fournies
   via des *variables* GitHub Actions, puis `validate` et `plan`. Sur PR, le
   plan est posté/mis à jour en commentaire. Sur push `main`, le plan est en
   plus sauvegardé en artefact (`tfplan-prod`).
3. **`terraform-apply`** — uniquement sur push `main`, après le job plan.
   Utilise l'**Environment GitHub `prod`** comme gate manuel : configure des
   *required reviewers* dans `Settings > Environments > prod > Deployment
   protection rules` pour qu'un humain valide avant l'apply réel (sinon
   l'apply se déclenche automatiquement dès que le job précédent termine).
   Applique **exactement** l'artefact de plan produit à l'étape précédente
   (`terraform apply tfplan`), pas un plan recalculé au moment de
   l'approbation — évite qu'un état ait changé entre la revue et l'exécution.

Le rôle IAM assumé (`github_actions_deploy`, voir `outputs.github_actions_role_arn`)
est restreint par défaut à `<github_repository>` (toutes les refs — branches,
tags, PR) via la claim OIDC `job_workflow_ref` — resserre via la variable
`github_oidc_allowed_ref` (ex. `refs/heads/main`) si tu veux limiter le
déploiement à un seul flux.

> **Note** : le scoping se fait sur `job_workflow_ref`, pas sur `sub`.
> AWS impose que la trust policy d'un provider GitHub OIDC soit scopée via
> `sub` ou `job_workflow_ref` (sinon `CreateRole`/`UpdateAssumeRolePolicy`
> est rejeté). `sub` a été écarté car son format change si GitHub active les
> "immutable IDs" dans les claims (`repo:owner@123/repo@456:ref:...` au lieu
> de `repo:owner/repo:ref:...`) — un filtre `sub` codé en dur casse alors
> silencieusement l'authentification OIDC, ce qui s'est produit sur ce
> projet dès le premier run du pipeline. `job_workflow_ref`
> (`owner/repo/.github/workflows/fichier.yml@ref`) n'est pas affecté par ce
> toggle.

### Secrets et variables GitHub Actions à configurer

Dans `Settings > Secrets and variables > Actions` du dépôt :

**Secret** (`Secrets`, valeur jamais loguée) :

| Nom | Valeur |
|---|---|
| `AWS_GITHUB_ACTIONS_ROLE_ARN` | ARN du rôle `github_actions_deploy` créé par ce Terraform (sortie `github_actions_role_arn`). Traité comme secret car il révèle l'ID de compte AWS. |

**Variables** (`Variables`, non sensibles, visibles en clair dans les logs) :

| Nom | Exemple |
|---|---|
| `AWS_REGION` | `eu-west-3` |
| `TF_STATE_BUCKET` | `ton-bucket-state-terraform` |
| `TF_STATE_KEY` | `demo-cicd/prod/terraform.tfstate` |
| `TF_STATE_DYNAMODB_TABLE` | `ta-table-dynamodb-lock` |
| `TF_VAR_PROJECT_NAME` | `demo-cicd` |
| `TF_VAR_OWNER` | ton nom ou ton équipe |

(`github_repository` n'a pas besoin d'être configuré séparément : le
workflow le déduit automatiquement de `${{ github.repository }}`.)

### Bootstrap initial du rôle OIDC (problème de l'œuf et la poule)

Le rôle `github_actions_deploy` doit **déjà exister** pour que le pipeline
puisse s'authentifier et l'appliquer/le maintenir — il ne peut pas se créer
lui-même au tout premier run. Séquence de démarrage :

1. En local, avec tes propres identifiants AWS (voir "Lancer un plan en
   local" ci-dessus) : `terraform apply` une première fois pour créer le
   fournisseur OIDC, le rôle `github_actions_deploy` et le reste de l'infra.
   (Seule commande d'`apply` de tout ce document, volontairement en dehors
   du périmètre automatisé par ce assistant.)
2. Récupère l'ARN du rôle (`terraform output github_actions_role_arn`) et
   renseigne-le dans le secret `AWS_GITHUB_ACTIONS_ROLE_ARN`.
3. À partir de là, le pipeline peut prendre le relais pour les runs suivants
   (y compris pour faire évoluer sa propre policy IAM, scopée à son propre
   nom de rôle).

## Déploiement du site statique

Deux mécanismes possibles. Celui **implémenté** dans ce code est l'option A ;
l'option B est documentée comme alternative si tes besoins évoluent.

### Option A (implémentée) — via `user_data`, déclenché par `terraform plan/apply`

Au provisioning, `user_data` clone le dépôt public (`git clone --depth 1`)
et copie `/site` vers `/usr/share/nginx/html`. Un hash SHA1 du contenu de
`/site` (calculé par Terraform avec `fileset`/`filesha1`) est injecté en
commentaire inerte dans le script `user_data`. Combiné à
`user_data_replace_on_change = true`, toute modification d'un fichier dans
`/site` fait apparaître un remplacement d'instance au prochain
`terraform plan` — la mise à jour du site suit donc exactement le même
pipeline (`plan` → review → `apply`) que le reste de l'infra.

- **Avantages** : aucune ressource AWS supplémentaire ; un seul mécanisme
  (`terraform apply`) pour infra ET contenu ; entièrement déclaratif et
  visible dans le plan avant application ; cohérent avec l'esprit "POC
  simple, pas de pièces mobiles en plus".
- **Inconvénients** : remplacement complet de l'instance à chaque
  changement de contenu → coupure de quelques dizaines de secondes et
  changement d'IP publique (pas grave ici, pas de DNS figé) ; le dépôt doit
  être public en HTTPS (pas d'identifiants disponibles dans `user_data`) ;
  pas adapté à des mises à jour fréquentes ou à fort trafic.

### Option B (non implémentée) — mise à jour à chaud via SSM Send-Command

Le contenu de `/site` serait synchronisé vers un bucket S3 dédié par le
pipeline CI, puis un `aws ssm send-command` déclencherait sur l'instance un
`aws s3 sync s3://.../site /usr/share/nginx/html --delete` suivi d'un
`systemctl reload nginx`, sans jamais toucher à l'instance elle-même.

- **Avantages** : zéro coupure, mise à jour en quelques secondes,
  indépendante du cycle de vie Terraform (pas besoin de `terraform apply`
  pour changer le contenu), fonctionnerait aussi avec un dépôt privé.
- **Inconvénients** : ajoute un bucket S3, une IAM policy supplémentaire
  (droits `s3:GetObject`/`PutObject` sur ce bucket, `ssm:SendCommand` côté
  rôle GitHub Actions), et une étape de pipeline dédiée — plus de pièces
  mobiles pour un gain qui n'est pas nécessaire à ce stade du POC.

Si le trafic ou la fréquence de mise à jour augmentent, basculer vers
l'option B est la suite logique.

## Accès administratif (pas de SSH)

Le security group n'ouvre **aucun port 22**. L'accès à l'instance se fait
exclusivement via **AWS Systems Manager Session Manager**, permis par le
rôle IAM d'instance (`AmazonSSMManagedInstanceCore`) :

```bash
aws ssm start-session --target <instance-id> --region <region>
```

(commande fournie telle quelle par l'output Terraform `ssm_connect_command`).
Aucune clé SSH n'est générée ni stockée par ce code.

## Checkov

Ce code est un module Terraform HCL standard, sans wrapper particulier :
`checkov -d infra/` fonctionne sans adaptation. Quelques findings sont
volontairement acceptés et documentés inline via des commentaires
`# checkov:skip=<ID> <justification>` (ex. ouverture du port 80 au monde
entier, sortant large sur le security group, pas de monitoring détaillé) —
ce sont des compromis assumés pour un POC pédagogique, pas des oublis.

## Least privilege du rôle GitHub Actions

La policy du rôle `github_actions_deploy` (`main.tf`) liste explicitement
chaque action IAM nécessaire — aucun `service:*` ni `*` en tant qu'Action.
Le `Resource` est restreint au plus précis possible (ARN du bucket S3 et de
la clé d'état, table DynamoDB, log group CloudWatch, rôle/instance-profile
IAM par préfixe de nom, provider OIDC). Quelques actions EC2/réseau
(`ec2:RunInstances`, `ec2:CreateVpc`, etc.) restent en `Resource = "*"` car
IAM ne supporte pas de restriction par ARN de ressource pour la majorité des
API EC2 — c'est une limitation d'AWS, pas un renoncement au principe : c'est
documenté statement par statement dans `main.tf`.

## Résumé des ressources créées

Voir le message de résumé fourni séparément (réseau, IAM/OIDC, compute,
logs) avant intégration dans le workflow GitHub Actions.
