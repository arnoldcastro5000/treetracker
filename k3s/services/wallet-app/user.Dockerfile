# Workspace-aware build of apps/user (the NestJS user-api) from the monorepo ROOT context.
# The submodule's apps/user/Dockerfile is NOT workspace-aware: it copies only apps/user/package.json,
# so it misses the Yarn 4 workspace root and the `@packages`/`@utils`/`@dtos` tsconfig aliases the app
# uses. Here the whole monorepo is the build context (images.context: treetracker-wallet-app). We
# install with corepack yarn@4.9.4 (node-modules linker; symlinks work in the container overlayfs,
# unlike the host FS), then build the `user` workspace.
#
# nest build runs plain tsc with `allowJs: true`, so it compiles the aliased sources (libs/* and the
# plain-JS packages/queue) INTO dist and emits every alias as a RELATIVE require. So the runtime needs
# no alias resolution: `require("@utils/swagger")` becomes `require("../libs/utils/swagger")` and
# `require("@packages/queue/pgClient.js")` becomes a relative path to dist/packages/queue. We still
# focus the `queue` workspace so its runtime deps (pg/dotenv/loglevel), which the compiled queue code
# loads, are present in node_modules.
FROM node:18-alpine AS builder
WORKDIR /app
RUN corepack enable
# node_modules and .git are kept out of the context by user.Dockerfile.dockerignore; the rm is a
# fallback for a docker engine that does not honor the dockerfile-specific ignore file.
COPY . .
RUN rm -rf node_modules apps/*/node_modules packages/*/node_modules
# Install ONLY the workspaces apps/user needs: `user` (carries its own build tooling: nest-cli,
# typescript, @treetracker/config) and `queue` (its compiled code loads pg/dotenv/loglevel at runtime).
# A full `yarn install` would also pull the web/bdd/native e2e tooling (cypress, chromedriver,
# geckodriver) whose postinstall scripts fail in Alpine.
RUN yarn workspaces focus user queue
RUN yarn workspace user build

FROM node:18-alpine AS prod
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app ./
EXPOSE 8080
# nest-cli entryFile ("apps/user/src/main") and start:prod ("dist/src/main") disagree on the dist
# path, so locate the built entry at runtime instead of hardcoding it.
CMD ["sh","-c","node $(find apps/user/dist -name main.js | head -1)"]
