# Vendored override Dockerfile for bulk-pack-transformer-v2 (see .scratch/volunteer-e2e-ci ticket 32).
#
# The submodule's upstream build works as-is; this file is IDENTICAL to it, plus ONE line: it
# overlays a LocalStack-aware server/infra/aws/s3.js so POST /tracks can PutObject to the local
# S3 (LocalStack) instead of 500-ing on a Missing-Bucket / real-AWS endpoint. Vendoring here (not a
# submodule edit) keeps the bulk-pack-transformer-v2 pin pristine, matching the admin-client /
# consumer precedent (k3s/services/README.md). The patched file lives beside this Dockerfile and
# comes in through the `localdeploy` named build context wired by k3s/up.sh:
#   docker build -f k3s/services/bulk-pack-transformer-v2/Dockerfile \
#     --build-context localdeploy=k3s/services/bulk-pack-transformer-v2 bulk-pack-transformer-v2
FROM node:16-alpine
WORKDIR /app
ENV PATH /app/node_modules/.bin:$PATH
COPY package.json ./
COPY package-lock.json ./
RUN npm ci --silent
COPY . ./
# Endpoint-aware S3 client. Prod leaves AWS_ENDPOINT unset, so this file behaves exactly like
# upstream there; locally it points the client at LocalStack (see s3.js in this dir).
COPY --from=localdeploy s3.js server/infra/aws/s3.js
CMD [ "node", "." ]
