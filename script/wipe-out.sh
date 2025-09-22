docker stop $(docker ps -a -q)
docker system prune -af --volumes
docker network prune -f
