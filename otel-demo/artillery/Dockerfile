# Replacement for the fork's src/artillery-load-generator/Dockerfile.
#
# The fork builds FROM artilleryio/artillery, which is amd64-only on all of its
# published tags, so the resulting image cannot run on an arm64 kind node — it
# builds "successfully" and then crash-loops with "exec format error". The
# Microsoft Playwright image is multi-arch and already ships the browsers the
# scenario drives, so we install the artillery CLI on top of it instead.
#
# Everything else — flows.js, load-test.template.yaml, the faker dependency —
# comes from the fork's own build context, unchanged.
FROM mcr.microsoft.com/playwright:v1.50.0-jammy

WORKDIR /app

RUN npm install -g artillery@2.0.34

COPY package.json package-lock.json ./
RUN npm install

RUN apt-get update \
 && apt-get install -y --no-install-recommends gettext-base \
 && rm -rf /var/lib/apt/lists/*

COPY flows.js load-test.template.yaml run.sh ./
RUN chmod +x run.sh

ENTRYPOINT ["/bin/sh", "./run.sh"]
