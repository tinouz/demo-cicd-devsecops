#!/usr/bin/env bash
# Bootstrap (create) ou teardown (destroy) du backend Terraform S3 + DynamoDB.
#
# Ce backend ne peut pas être géré par le Terraform de infra/ lui-même :
# Terraform a besoin d'un backend pour s'initialiser, il ne peut donc pas
# créer le bucket/table qu'il utilise comme backend (voir infra/README.md,
# section "Bootstrap du backend").
#
# Usage:
#   ./bootstrap-backend.sh create
#   ./bootstrap-backend.sh destroy
#
# Configuration via variables d'environnement (valeurs par défaut ci-dessous
# alignées sur infra/terraform.tfvars.example) :
#   TF_STATE_BUCKET, TF_STATE_DYNAMODB_TABLE, AWS_REGION

set -euo pipefail

ACTION="${1:-}"
BUCKET="${TF_STATE_BUCKET:-demo-cicd-devsecops-tfstate}"
TABLE="${TF_STATE_DYNAMODB_TABLE:-demo-cicd-devsecops-tflock}"
REGION="${AWS_REGION:-eu-west-3}"

usage() {
  echo "Usage: $0 create|destroy" >&2
  echo "Env: TF_STATE_BUCKET=$BUCKET TF_STATE_DYNAMODB_TABLE=$TABLE AWS_REGION=$REGION" >&2
  exit 1
}

create() {
  echo "==> Bucket S3: $BUCKET ($REGION)"
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"

  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  echo "==> Table DynamoDB: $TABLE ($REGION)"
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" \
    > /dev/null

  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"

  echo "==> OK. Backend prêt : bucket=$BUCKET table=$TABLE region=$REGION"
}

empty_bucket() {
  # Bucket versionné : il faut supprimer toutes les versions d'objets et
  # tous les delete markers avant de pouvoir supprimer le bucket lui-même.
  echo "==> Vidage du bucket $BUCKET (versions + delete markers)"
  while :; do
    RAW=$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGION" --max-items 1000 --output json)

    PAYLOAD=$(echo "$RAW" | python3 -c "
import sys, json
d = json.load(sys.stdin)
objects = [{'Key': v['Key'], 'VersionId': v['VersionId']} for v in d.get('Versions', [])]
objects += [{'Key': v['Key'], 'VersionId': v['VersionId']} for v in d.get('DeleteMarkers', [])]
print(json.dumps({'Objects': objects, 'Quiet': True}))
")

    COUNT=$(echo "$PAYLOAD" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['Objects']))")
    if [ "$COUNT" -eq 0 ]; then
      break
    fi

    aws s3api delete-objects --bucket "$BUCKET" --region "$REGION" --delete "$PAYLOAD" > /dev/null
  done
}

destroy() {
  if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
    empty_bucket
    echo "==> Suppression du bucket $BUCKET"
    aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION"
  else
    echo "==> Bucket $BUCKET introuvable, rien à faire"
  fi

  if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
    echo "==> Suppression de la table $TABLE"
    aws dynamodb delete-table --table-name "$TABLE" --region "$REGION" > /dev/null
    aws dynamodb wait table-not-exists --table-name "$TABLE" --region "$REGION"
  else
    echo "==> Table $TABLE introuvable, rien à faire"
  fi

  echo "==> OK. Backend détruit."
}

case "$ACTION" in
  create) create ;;
  destroy) destroy ;;
  *) usage ;;
esac
