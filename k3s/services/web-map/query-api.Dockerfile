# :local image for treetracker-query-api. The repo Dockerfile copies a HOST-prebuilt dist/;
# this one compiles inside the image so the build is hermetic (and works on hosts whose
# filesystem cannot npm ci). Runtime matches the repo image: npm start = node dist/server.js.
FROM node:16-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --silent
COPY . .
RUN npm run build

FROM node:16-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --silent
COPY --from=build /app/dist ./dist
COPY --from=build /app/config ./config
CMD ["npm", "start"]
