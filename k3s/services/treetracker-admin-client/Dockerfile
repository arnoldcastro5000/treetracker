# Local e2e image for the admin-client /verify UI.
#
# Vendored into the superproject (see k3s/services/README.md). The build context is the
# treetracker-admin-client submodule (app source); this file and nginx.conf live here in
# k3s/services/ so the admin-client pin can track master (2.0.0) without carrying a local
# deployment/ tree. nginx.conf is pulled from the `localdeploy` named build context, wired
# up by k3s/up.sh:
#   docker build -f k3s/services/treetracker-admin-client/Dockerfile \
#     --build-context localdeploy=k3s/services/treetracker-admin-client treetracker-admin-client
#
# Stage 1: CRA production build. Roots match the shipped Ambassador Mappings so Emissary
#   (not nginx) does the routing: REACT_APP_API_ROOT=/api/admin (admin-api, rewrite /),
#   REACT_APP_IMAGES_API_ROOT=/images (images-api, rewrite /). Single origin via the
#   k3d LB (localhost:8088) means no CORS. nginx here only serves the static SPA (no proxy).
FROM node:18-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
# Cypress is a devDependency used only for tests; its postinstall binary download fails in
# restricted-network builds (and Cypress does not support Alpine anyway).
ENV CYPRESS_INSTALL_BINARY=0
RUN npm install --no-audit --no-fund --legacy-peer-deps
COPY . .
ENV REACT_APP_API_ROOT="/api/admin" \
    REACT_APP_TREETRACKER_API_ROOT="/treetracker" \
    REACT_APP_QUERY_API_ROOT="/query" \
    REACT_APP_GROWER_QUERY_API_ROOT="/grower" \
    REACT_APP_IMAGES_API_ROOT="/images" \
    REACT_APP_REGION_API_ROOT="/region" \
    REACT_APP_WEBMAP_DOMAIN="" \
    REACT_APP_ENABLE_CAPTURE_MATCHING=false \
    REACT_APP_ENABLE_MESSAGING=false \
    REACT_APP_ENABLE_REGIONS=false \
    REACT_APP_ENABLE_STAKEHOLDERS=false \
    REACT_APP_ENABLE_TOOLTIPS=false \
    GENERATE_SOURCEMAP=false \
    CI=false
RUN npm run build

# Stage 2: nginx serves ONLY the static SPA build (Ambassador handles all API routing).
FROM nginx:1.27-alpine
COPY --from=localdeploy nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build /usr/share/nginx/html
EXPOSE 80
