# 用法：docker buildx build --platform linux/amd64 \
#   --build-arg JAR_FILE=boot/target/<service>-boot-<version>.jar \
#   -t 192.168.31.100:5000/docker-hosted/<project>-<service>:<tag> --push .
FROM eclipse-temurin:21-jre
ARG JAR_FILE
WORKDIR /app
RUN useradd --system --uid 10001 app
COPY ${JAR_FILE} /app/app.jar
USER 10001
ENV JAVA_OPTS="-Xms256m -Xmx512m"
EXPOSE 8080
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
