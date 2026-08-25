# :local image for treetracker-web-map-client. Next.js inlines NEXT_PUBLIC_* at BUILD time from
# .env.production, so the client's committed .env.local-k3s (single-origin gateway paths) is
# copied over it before `next build` (the repo's own Dockerfile-dev/-test use the same pattern).
#
# Basemap (web-map-standalone decision 01): the npm treetracker-web-map-core bundle hardcodes a
# keyless Google satellite TileLayer. The sed below swaps it for a public OSM raster (default;
# override via BASEMAP_URL). The grep gates make the build FAIL LOUDLY if the core bundle drifts
# and the pattern no longer matches, instead of shipping the wrong basemap silently.
# Full (Debian) node image: git is preinstalled (leaflet-utfgrid is a git dependency) and the
# Alpine package CDN is DNS-blocked on restricted networks, so apk cannot be used.
FROM node:16
WORKDIR /app
COPY package.json package-lock.json ./
# --ignore-scripts: the repo's prepare script runs `husky install`, which dies without a usable
# .git in the image (the submodule checkout ships a gitdir pointer file); no dependency here
# needs install scripts (the git-sourced leaflet-utfgrid is consumed as-is).
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY . .
# Google-geometry guard (decision 06): wrap the unconditional Google Maps JS injection in an env
# gate. Done as gated seds (the injected lines quote the upstream-committed API key, which must
# not be copied into this repo, so no patch file). The uniqueness gates fail the build loudly if
# App.js drifts.
RUN f=src/components/App.js \
  && [ "$(grep -c "const script =" $f)" = 1 ] \
  && [ "$(grep -c "document.body.appendChild(script);" $f)" = 1 ] \
  && sed -i "s|const script =|if (process.env.NEXT_PUBLIC_GOOGLE_GEOMETRY_DISABLED !== 'true') { const script =|" $f \
  && sed -i "s|document.body.appendChild(script);|document.body.appendChild(script); }|" $f
ARG BASEMAP_URL='https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png'
RUN GOOGLE_URL='https://{s}.google.com/vt/lyrs=s,h&x={x}&y={y}&z={z}' \
  && CORE=node_modules/treetracker-web-map-core/dist/main.js \
  && grep -qF "$GOOGLE_URL" "$CORE" \
  && sed -i "s|$GOOGLE_URL|$BASEMAP_URL|" "$CORE" \
  && grep -qF "$BASEMAP_URL" "$CORE"
COPY --from=localdeploy env.local-k3s .env.production
# next build prerenders /top via getStaticProps, which fetches the featured lists from the API at
# BUILD time. Prod builds against the live prod API (absolute URLs); a hermetic :local build has
# no API to call, and the page's error path returns undefined, which kills the export. Empty
# props keep the build hermetic; /top is the leaderboard page, disabled in this env anyway.
RUN f=src/pages/top.js \
  && [ "$(grep -c "const props = await serverSideData(params);" $f)" = 1 ] \
  && sed -i "s|const props = await serverSideData(params);|const props = await serverSideData(params).catch(() => ({ trees: [], countries: [], planters: [], organizations: [], wallets: [] }));|" $f
RUN npm run build
CMD ["npm", "run", "start"]
