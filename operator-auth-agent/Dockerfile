FROM public.ecr.aws/amazoncorretto/amazoncorretto:27-al2023-headless
WORKDIR /app
COPY target/quarkus-app/lib/ /app/lib/
COPY target/quarkus-app/*.jar /app/
COPY target/quarkus-app/app/ /app/app/
COPY target/quarkus-app/quarkus/ /app/quarkus/
EXPOSE 8090
CMD ["java", "-XX:MaxRAMPercentage=80.0", "-jar", "/app/quarkus-run.jar"]
