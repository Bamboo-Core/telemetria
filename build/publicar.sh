#!/usr/bin/env bash
###############################################################################
# publicar.sh — Build e push da imagem Telegraf-Huawei para o GHCR (USO INTERNO)
#
# Rode UMA VEZ (ou quando mudar o Dockerfile/protos). Depois disso, qualquer
# cliente apenas baixa a imagem com `docker compose up` — não precisa compilar.
#
# Pré-requisitos:
#   - docker buildx (já vem no Docker moderno)
#   - login no GHCR:
#       echo "$GHCR_PAT" | docker login ghcr.io -u <seu-usuario> --password-stdin
#     (PAT com escopo: write:packages)
#   - depois do 1º push, marque o pacote como PÚBLICO em:
#       github.com/orgs/Bamboo-Core/packages
#
# Uso:
#   ./publicar.sh                 # tag :latest
#   ./publicar.sh v1.2.3          # tag :v1.2.3 (e também :latest)
#   IMAGE=ghcr.io/outro/nome ./publicar.sh
###############################################################################
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${IMAGE:-ghcr.io/bamboo-core/telegraf-huawei}"
TAG="${1:-latest}"

# Quais .proto da Huawei incluir (precisa bater com o ARG do Dockerfile).
PROTO_FILES="${PROTO_FILES:-huawei-debug huawei-ifm}"

# Cache-bust para forçar recompilação dos passos de patch quando necessário.
CACHE_BUST="$(date +%s)"

echo "==> Buildando ${IMAGE}:${TAG}"
echo "    PROTO_FILES = ${PROTO_FILES}"
docker build \
  --build-arg PROTO_FILES="${PROTO_FILES}" \
  --build-arg CACHE_BUST="${CACHE_BUST}" \
  ${HTTP_PROXY:+--build-arg HTTP_PROXY="${HTTP_PROXY}"} \
  ${HTTPS_PROXY:+--build-arg HTTPS_PROXY="${HTTPS_PROXY}"} \
  -t "${IMAGE}:${TAG}" \
  .

if [ "${TAG}" != "latest" ]; then
  docker tag "${IMAGE}:${TAG}" "${IMAGE}:latest"
fi

echo "==> Enviando para o GHCR"
docker push "${IMAGE}:${TAG}"
[ "${TAG}" != "latest" ] && docker push "${IMAGE}:latest"

echo
echo "OK. Imagem publicada: ${IMAGE}:${TAG}"
echo "Lembre de deixar o pacote PÚBLICO no GitHub (org > Packages) para o cliente baixar sem login."
