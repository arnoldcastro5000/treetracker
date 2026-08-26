# :local image for node-mapnik-1 (the live tile server). Same as the repo Dockerfile except node
# 14 comes from the official Docker Hub image instead of a nodejs.org download: restricted
# networks (registry-sourcing decision, standalone-env 13) allow the registry but may block
# nodejs.org. Version pinned identically (14.21.3).
FROM node:14.21.3-buster-slim AS node14

FROM dadiorchen/tile2:first
WORKDIR /app
ENV PATH /app/node_modules/.bin:$PATH
COPY . ./
# Best-effort: restricted networks block the Debian mirrors; the tile2 base already carries the
# toolchain that built its mapnik SDK, so a blocked apt is tolerated and the compile decides.
RUN sudo apt-get update && sudo apt-get -y install build-essential zlib1g-dev ca-certificates \
  || echo "apt unavailable (restricted network); relying on the base image toolchain"
COPY --from=node14 /usr/local /usr/local
# node-gyp normally downloads the node headers from nodejs.org (blocked here); the official node
# image already ships them at /usr/local/include/node, so build against those in place.
ENV npm_config_nodedir=/usr/local
RUN make release_base
CMD [ "npm", "start" ]
