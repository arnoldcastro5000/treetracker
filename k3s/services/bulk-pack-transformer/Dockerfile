# Vendored override Dockerfile for the v1 bulk-pack-transformer (see .scratch/volunteer-e2e-ci
# ticket 15).
#
# The submodule's own Dockerfile runs `npm ci`, whose `prepare` lifecycle runs `husky install` and
# exits 127 (no husky/git in the build image). That is a dev-tooling break only; the runtime needs
# prod dependencies only. `--ignore-scripts` skips the husky prepare, and `--omit=dev` drops the
# dev tree, so the committed lockfile stays authoritative for the prod deps that remain.
FROM node:16-alpine
WORKDIR /app
ENV PATH=/app/node_modules/.bin:$PATH
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund
COPY . ./
CMD [ "node", "." ]
