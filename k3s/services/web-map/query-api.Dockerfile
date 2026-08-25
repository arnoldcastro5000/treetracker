# :local image for treetracker-query-api. The repo Dockerfile copies a HOST-prebuilt dist/;
# this one compiles inside the image so the build is hermetic (and works on hosts whose
# filesystem cannot npm ci). Single stage: the devDependencies stay in the image, which is
# irrelevant locally and keeps the build simple (a prod-only reinstall stage failed opaquely).
# Runtime matches the repo image: npm start = node dist/server.js.
FROM node:16-alpine
WORKDIR /app
COPY package.json package-lock.json ./
# --ignore-scripts: the repo's prepare script is `husky install`, which dies without a usable
# .git in the image; no dependency here needs install scripts.
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY . .
RUN npm run build
ENV NODE_ENV=production
CMD ["npm", "start"]
