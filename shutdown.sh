#!/bin/bash

#docker-compose -f docker-compose-devops.yml -p devops down

#docker-compose -f docker-compose-manager.yml -p manager down

docker-compose -f docker-compose-microservices.yml -p microservices down
docker-compose -f docker-compose-kafka.yml -p kafka down
docker-compose -f docker-compose-database.yml -p database down

docker network rm glseven
