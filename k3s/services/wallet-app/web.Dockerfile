# Static-export build of apps/web (Next 14 SPA) from the monorepo ROOT context, served by nginx at
# /wallet. The submodule ships no Dockerfile/deployment; this file + web/nginx.conf live here so the
# wallet-app submodule pin stays pristine (config patch + route removal happen in this build, not in
# the submodule tree). nginx.conf comes from the `localdeploy` named build context (up.sh wires it via
# extraContexts). All API routing is done by Emissary at the gateway (same origin, no CORS); nginx only
# serves the static SPA.
FROM node:18-alpine AS build
WORKDIR /app
RUN corepack enable
# Cypress is a web devDependency used only for tests; its postinstall binary download fails in Alpine.
ENV CYPRESS_INSTALL_BINARY=0
# next build phones home to telemetry.nextjs.org by default; disable it (the host is blocked and it is
# not needed for the build).
ENV NEXT_TELEMETRY_DISABLED=1
# node_modules/.git kept out by web.Dockerfile.dockerignore; the rm is a fallback.
COPY . .
RUN rm -rf node_modules apps/*/node_modules packages/*/node_modules
# output:"export" cannot build server route handlers. app/api holds only the legacy auth route
# handlers and the Keycloak-admin services they call; the real client login/register path goes to
# NEXT_PUBLIC_WALLET_APP_API (apps/user), so this whole server-side dir is dead. Remove it.
RUN rm -rf apps/web/src/app/api
# serve under /wallet at the gateway, and disable next/image optimization (required for output:export).
# Guard: fail the build if the sed anchor drifts, instead of silently producing a root-served bundle.
RUN sed -i 's#output: "export",#output: "export",\n  basePath: "/wallet",\n  images: { unoptimized: true },#' apps/web/next.config.js \
 && grep -q 'basePath: "/wallet"' apps/web/next.config.js || { echo "next.config basePath patch did not apply"; exit 1; }
# core is shared with the native app; its storage util has a native-only require of async-storage in a
# web-dead branch, but webpack still resolves it statically. Alias it to an empty module for the web
# build (valid JS; the native branch never runs on web, so the stub is never used). A plain external
# does NOT work here because the module IS reached in the web graph and emits invalid output.
RUN sed -i 's#    return config;#    config.resolve.alias = { ...(config.resolve.alias || {}), "@react-native-async-storage/async-storage": false };\n    return config;#' apps/web/next.config.js \
 && grep -q 'async-storage": false' apps/web/next.config.js || { echo "next.config async-storage alias patch did not apply"; exit 1; }
# Install only the workspaces apps/web needs; a full install pulls the bdd/native e2e tooling whose
# postinstall scripts fail in Alpine. web's tsconfig extends @treetracker/config but does not declare
# it as a dep (a latent fork bug), so focus it explicitly or `next build` fails with TS6053.
RUN yarn workspaces focus web core @treetracker/wallet @treetracker/config
# NEXT_PUBLIC_* are inlined at build time. The browser calls /user-api (apps/user) same-origin via the
# gateway, so a relative base needs no host.
ENV NEXT_PUBLIC_WALLET_APP_API=/user-api
RUN yarn workspace web build

# nginx serves ONLY the static export; Emissary handles /wallet -> / and all API routing.
FROM nginx:1.27-alpine
COPY --from=localdeploy nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/apps/web/out /usr/share/nginx/html
EXPOSE 80
