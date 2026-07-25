data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  common_tags = {
    environment = "prod"
    project     = var.project_name
    owner       = var.owner
  }

  name_prefix = var.project_name

  # Hash du contenu de /site : toute modification d'un fichier du site change
  # ce hash, qui est injecté (en commentaire, inerte pour bash) dans le
  # user_data. Combiné à `user_data_replace_on_change = true`, cela fait que
  # `terraform plan` détecte le changement et remplace l'instance pour tirer
  # le nouveau contenu au prochain apply. Voir infra/README.md pour les
  # alternatives de mise à jour du site.
  site_files = fileset("${path.module}/../site", "**")
  site_hash  = sha1(join("", [for f in local.site_files : filesha1("${path.module}/../site/${f}")]))
}

# -----------------------------------------------------------------------------
# Réseau : VPC minimal, un seul sous-réseau public
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-public-subnet" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Security group : port 80 uniquement en entrée. Pas de port 22 : l'accès
# administratif se fait exclusivement via AWS SSM Session Manager (voir rôle
# IAM de l'instance plus bas), donc aucun port SSH n'est ouvert.
# -----------------------------------------------------------------------------

resource "aws_security_group" "web" {
  name        = "${local.name_prefix}-web-sg"
  description = "Allow HTTP inbound only ; no SSH (access via SSM Session Manager)" # GroupDescription: ASCII only (AWS API constraint)
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-web-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  description       = "HTTP public - site statique" # checkov:skip=CKV_AWS_260 Site web public volontairement ouvert sur 0.0.0.0/0:80 (POC pédagogique, pas de WAF/CDN)
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  description       = "Full outbound required (system updates, git clone, SSM/CloudWatch agents)" # checkov:skip=CKV_AWS_382 Sortant large necessaire pour la mise a jour du site via git clone et les agents AWS ; POC sans VPC endpoints
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# -----------------------------------------------------------------------------
# IAM - rôle d'instance EC2 : SSM (accès administratif sans SSH) + écriture
# des logs nginx dans le log group CloudWatch dédié.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "ec2" {
  name = "${local.name_prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

# Politique gérée AWS pour Session Manager : usage standard et documenté pour
# ce cas d'usage (accès SSH sans clé). L'exigence "pas de wildcard" du sujet
# vise le rôle GitHub Actions ci-dessous, dont la policy est écrite à la main.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ec2_logs" {
  name = "${local.name_prefix}-ec2-logs"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.nginx.arn}:*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# CloudWatch Logs - logs nginx, rétention 7 jours
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "nginx" {
  name              = "/ec2/${local.name_prefix}/nginx"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Compute : une seule instance EC2, nginx installé et site déployé via
# user_data. Voir infra/README.md pour le détail du mécanisme de déploiement
# et les alternatives de mise à jour du contenu statique.
# -----------------------------------------------------------------------------

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  metadata_options {
    http_tokens   = "required" # IMDSv2 obligatoire
    http_endpoint = "enabled"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  monitoring = false # checkov:skip=CKV_AWS_126 Monitoring détaillé non nécessaire pour un POC pédagogique (coût)

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    github_repository = var.github_repository
    log_group_name    = aws_cloudwatch_log_group.nginx.name
    site_hash         = local.site_hash
  })
  user_data_replace_on_change = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-web" })
}

# -----------------------------------------------------------------------------
# IAM - rôle assumé par GitHub Actions via OIDC (aucune clé d'accès statique)
# -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # Empreintes SHA1 de la chaîne TLS de token.actions.githubusercontent.com
  # (CA racine + intermédiaire). Depuis 2023, AWS ne valide plus réellement
  # cette empreinte pour les fournisseurs OIDC connus (il s'appuie sur son
  # propre magasin de CA de confiance) : le champ reste néanmoins requis par
  # la ressource et doit contenir des valeurs syntaxiquement valides.
  thumbprint_list = [
    "ab9d0263244dd0326eb67015705a667e79cfe998",
    "2d74d6dfd96eea55ad7baafa0d3c6552b2dadc37",
  ]

  tags = local.common_tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

locals {
  # AWS exige que la trust policy d'un provider GitHub OIDC soit scopée via
  # `sub` ou `job_workflow_ref` (pas uniquement via d'autres claims comme
  # `repository`) : sinon UpdateAssumeRolePolicy/CreateRole rejette la policy
  # ("must evaluate ... sub or job_workflow_ref which is not scoped to all").
  # On utilise `job_workflow_ref` plutôt que `sub` car son format
  # (owner/repo/.github/workflows/fichier.yml@ref) reste stable même si
  # GitHub active les "immutable IDs" dans `sub`
  # (repo:owner@id/repo@id:ref:...), qui a cassé une première version de ce
  # trust policy basée sur `sub`.
  github_oidc_job_workflow_ref = var.github_oidc_allowed_ref != null ? "${var.github_repository}/.github/workflows/*@${var.github_oidc_allowed_ref}" : "${var.github_repository}/.github/workflows/*"
}

resource "aws_iam_role" "github_actions" {
  name = "${local.name_prefix}-github-actions-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:job_workflow_ref" = local.github_oidc_job_workflow_ref
        }
      }
    }]
  })

  tags = local.common_tags
}

# Policy strictement scopée : aucune action avec wildcard (pas de "service:*"
# ni "*"). Le Resource est restreint partout où IAM le permet ; certaines
# actions EC2/réseau ne supportent pas de permission au niveau ressource côté
# AWS (uniquement Resource = "*" possible) — c'est documenté statement par
# statement ci-dessous, jamais compensé par un wildcard d'action.
resource "aws_iam_role_policy" "github_actions" {
  name = "${local.name_prefix}-github-actions-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Réseau et compute EC2 : IAM ne supporte pas de restriction par
        # ARN de ressource pour la quasi-totalité de ces actions.
        Sid    = "Ec2NetworkAndCompute"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVpcs",
          "ec2:CreateVpc",
          "ec2:DeleteVpc",
          "ec2:ModifyVpcAttribute",
          "ec2:DescribeVpcAttribute",
          "ec2:DescribeSubnets",
          "ec2:CreateSubnet",
          "ec2:DeleteSubnet",
          "ec2:ModifySubnetAttribute",
          "ec2:DescribeInternetGateways",
          "ec2:CreateInternetGateway",
          "ec2:DeleteInternetGateway",
          "ec2:AttachInternetGateway",
          "ec2:DetachInternetGateway",
          "ec2:DescribeRouteTables",
          "ec2:CreateRouteTable",
          "ec2:DeleteRouteTable",
          "ec2:CreateRoute",
          "ec2:DeleteRoute",
          "ec2:AssociateRouteTable",
          "ec2:DisassociateRouteTable",
          "ec2:ReplaceRouteTableAssociation",
          "ec2:DescribeSecurityGroups",
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
          "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInstanceAttribute",
          "ec2:DescribeInstanceCreditSpecifications",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:StopInstances",
          "ec2:StartInstances",
          "ec2:ModifyInstanceAttribute",
          "ec2:ModifyInstanceMetadataOptions",
          "ec2:DescribeImages",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeVolumes",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          "ec2:DescribeTags",
        ]
        Resource = "*"
      },
      {
        Sid    = "IamRoleAndInstanceProfileManagement"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-*",
          "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${local.name_prefix}-*",
        ]
      },
      {
        Sid      = "IamPassRoleToEc2"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-ec2-role"
        Condition = {
          StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
        }
      },
      {
        Sid    = "IamOidcProvider"
        Effect = "Allow"
        Action = [
          "iam:GetOpenIDConnectProvider",
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
      },
      {
        # DescribeLogGroups ne supporte pas de restriction par ARN côté AWS.
        Sid      = "LogsDescribe"
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      },
      {
        Sid    = "LogsLogGroupManagement"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:PutRetentionPolicy",
          "logs:DeleteRetentionPolicy",
          "logs:TagResource",
          "logs:UntagResource",
          "logs:ListTagsForResource",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ec2/${local.name_prefix}/*"
      },
      {
        Sid      = "StateBucketAccess"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket_name}"
      },
      {
        Sid    = "StateObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket_name}/${var.state_bucket_key}"
      },
      {
        Sid    = "StateLockTable"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.state_lock_table_name}"
      },
    ]
  })
}
