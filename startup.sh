#!/bin/bash

export DOCKER_VOLUME=/docker/glseven

## elasticsearch
#mkdir -p $DOCKER_VOLUME/elasticsearch/data/ && chown -R 1000 $DOCKER_VOLUME/elasticsearch/data/

## nexus3
mkdir -p $DOCKER_VOLUME/nexus3/data/ && chown -R 200 $DOCKER_VOLUME/nexus3/data/

## prometheus
#mkdir -p $DOCKER_VOLUME/prometheus/data/ && chown -R 65534 $DOCKER_VOLUME/prometheus/data/

## jenkins
#mkdir -p $DOCKER_VOLUME/jenkins/home/ && chown -R 1000 $DOCKER_VOLUME/jenkins/home/

docker network create --driver=bridge --subnet=172.18.0.0/16 glseven

docker compose -f docker-compose-database.yml -p database up -d
docker compose -f docker-compose-kafka.yml -p kafka up -d
docker compose -f docker-compose-devops.yml -p devops up -d
#docker-compose -f docker-compose-manager.yml -p manager up -d
docker compose -f docker-compose-microservices.yml -p microservices up -d

#docker exec rap2-delos node scripts/init
