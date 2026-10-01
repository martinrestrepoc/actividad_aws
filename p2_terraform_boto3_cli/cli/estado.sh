#!/usr/bin/env bash
set -euo pipefail

carpeta=$(cd "$(dirname "$0")" && pwd)
inventario="$carpeta/.runtime/recursos.json"
aws_cli() { aws --profile default --region us-east-1 --no-cli-pager "$@"; }
[[ -f "$inventario" ]] || { echo "no hay inventario" >&2; exit 1; }

identidad=$(aws_cli sts get-caller-identity --output json)
arn=$(jq -r '.Arn' <<< "$identidad")
cuenta=$(jq -r '.Account' <<< "$identidad")
[[ "$arn" =~ :user/(.*/)?user_cli$ && "$cuenta" == $(jq -r '.account' "$inventario") && $(jq -r '.region' "$inventario") == us-east-1 ]] || exit 1
printf 'Identidad: %s\nRegión: us-east-1\n' "$arn"
printf 'Fase: %s\n' "$(jq -r '.phase' "$inventario")"

# solo se interpreta como ausente el error indicado; los demás se muestran
consultar() {
    local ausente="$1"
    shift
    if aws_cli "$@" 2> "$carpeta/.runtime/error.txt"; then
        return 0
    fi
    if grep -Fq "($ausente)" "$carpeta/.runtime/error.txt"; then
        echo "ausente"
    else
        cat "$carpeta/.runtime/error.txt" >&2
        return 1
    fi
}

vpc=$(jq -r '.vpc // empty' "$inventario")
if [[ -n "$vpc" ]]; then
    echo "VPC:"
    consultar InvalidVpcID.NotFound ec2 describe-vpcs --vpc-ids "$vpc" --query 'Vpcs[].{id:VpcId,estado:State}' --output json
fi
bucket=$(jq -r '.bucket // empty' "$inventario")
if [[ -n "$bucket" ]]; then
    echo "S3: $bucket"
    consultar 404 s3api head-bucket --bucket "$bucket" --expected-bucket-owner "$cuenta" --output json
fi
instancia=$(jq -r '.instance // empty' "$inventario")
if [[ -n "$instancia" ]]; then
    echo "EC2:"
    consultar InvalidInstanceID.NotFound ec2 describe-instances --instance-ids "$instancia" \
        --query 'Reservations[].Instances[].{id:InstanceId,estado:State.Name}' --output json
fi
db=$(jq -r '.database // empty' "$inventario")
if [[ -n "$db" ]]; then
    echo "RDS:"
    consultar DBInstanceNotFound rds describe-db-instances --db-instance-identifier "$db" \
        --query 'DBInstances[].{id:DBInstanceIdentifier,estado:DBInstanceStatus,endpoint:Endpoint.Address,secreto:MasterUserSecret}' --output json
fi
