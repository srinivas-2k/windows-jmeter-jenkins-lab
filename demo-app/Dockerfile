# ShopLite API - system under test, packaged for Docker Desktop on the Jenkins host (192.168.0.11).
#
# Stage 1 compiles the single source file with a full JDK; stage 2 runs it on a smaller JRE image.
# (Java's source-file mode needs the compiler, which a JRE does not contain - so we compile here.)
FROM eclipse-temurin:21-jdk AS build
WORKDIR /src
COPY ShopLiteApi.java .
RUN javac -d /out ShopLiteApi.java

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /out/ /app/
# Never run a network service as root inside a container when you do not have to.
RUN useradd --system --uid 10001 shoplite
USER shoplite
EXPOSE 8081
ENTRYPOINT ["java", "-cp", "/app", "ShopLiteApi"]
# Extra arguments can be appended: docker run ... shoplite-api:1.0 --port 8081 --delay-ms 200
CMD ["--port", "8081"]
