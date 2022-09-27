#!/bin/bash

export DOCKER_VOLUME=/docker/glseven

## nexus3
mkdir -p $DOCKER_VOLUME/nexus3/data/ && chown -R 200 $DOCKER_VOLUME/nexus3/data/

docker network create --driver=bridge --subnet=172.18.0.0/16 glseven

docker compose -f docker-compose-database.yml -p database up -d
docker compose -f docker-compose-devops.yml -p devops up -d
docker compose -f docker-compose-microservices.yml -p microservices up -d