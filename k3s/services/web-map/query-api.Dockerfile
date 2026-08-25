# :local image for treetracker-query-api. The repo Dockerfile copies a HOST-prebuilt dist/;
# this one compiles inside the image so the build is hermetic (and works on hosts whose
# filesystem cannot npm ci). Single stage: the devDependencies stay in the image, which is
# irrelevant locally and keeps the build simple (a prod-only reinstall stage failed opaquely).
# Runtime matches the repo image: npm start = node dist/server.js.
FROM node:16-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --silent
COPY . .
RUN npm run build
ENV NODE_ENV=production
CMD ["npm", "start"]
