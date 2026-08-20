# Vendored override Dockerfile for bulk-pack-consumer (see .scratch/volunteer-e2e-ci ticket 15).
#
# The submodule's own Dockerfile runs `npm ci`, which aborts here: co-mocha@1.1.2 peer-wants
# mocha<3 while devDependencies pin mocha@^8 (ERESOLVE). That conflict is baked into the committed
# package-lock.json, so `npm ci --omit=dev` still aborts (verified). The conflict is dev-tooling
# only; the runtime needs prod dependencies only (aws-sdk, dotenv, pg, sqs-consumer). So install
# prod deps with --legacy-peer-deps (which `npm ci` cannot honor) and skip lifecycle scripts.
FROM node:16-alpine
WORKDIR /app
ENV PATH=/app/node_modules/.bin:$PATH
COPY package.json ./
RUN npm install --omit=dev --legacy-peer-deps --ignore-scripts --no-audit --no-fund
COPY . ./
CMD [ "node", "." ]
