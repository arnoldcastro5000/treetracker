# :local image for treetracker-query-api. The repo Dockerfile copies a HOST-prebuilt dist/;
# this one compiles inside the image so the build is hermetic (and works on hosts whose
# filesystem cannot npm ci). Single stage: the devDependencies stay in the image, which is
# irrelevant locally and keeps the build simple (a prod-only reinstall stage failed opaquely).
# Runtime matches the repo image: npm start = node dist/server.js.
FROM node:16-alpine
WORKDIR /app
COPY package.json package-lock.json ./
# The upstream lockfile pins 4 packages to registry.npmmirror.com (a mirror many networks cannot
# resolve); rewrite them to the canonical registry, in-image only. --ignore-scripts: the repo's
# prepare script is `husky install`, which dies without a usable .git in the image; no dependency
# here needs install scripts.
RUN sed -i -e 's|https://registry.npmmirror.com/cors/download/|https://registry.npmjs.org/cors/-/|g' \
           -e 's|https://registry.npmmirror.com|https://registry.npmjs.org|g' package-lock.json \
  && ! grep -q 'registry.npmmirror.com' package-lock.json \
  && npm ci --ignore-scripts --no-audit --no-fund
COPY . .
RUN npm run build
ENV NODE_ENV=production
CMD ["npm", "start"]
