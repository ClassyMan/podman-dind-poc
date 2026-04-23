# More Testcontainers examples

Copy-paste-ready Testcontainers patterns covering the five idioms you're most likely to need: a SQL database, an event broker, a cache/KV store, a document DB, and the `GenericContainer` escape hatch for any HTTP service. All use AssertJ for assertions.

Every example assumes the setup in the [main README](./README.md) — rootless Podman running inside your Docker CI agent, the three Testcontainers env vars set by the entrypoint, and the six `docker run` flags. The test code itself is identical to what you'd write against a vanilla Docker daemon.

- [PostgreSQL (SQL over JDBC)](#postgresql-sql-over-jdbc)
- [Kafka (produce + consume)](#kafka-produce--consume)
- [Redis (Jedis key/value)](#redis-jedis-keyvalue)
- [MongoDB (document insert/find)](#mongodb-document-insertfind)
- [GenericContainer (any image, HTTP probe via nginx)](#genericcontainer-any-image-http-probe-via-nginx)
- [Your own Spring Boot app (WAR in Tomcat, or executable JAR)](#your-own-spring-boot-app-war-in-tomcat-or-executable-jar)

---

## PostgreSQL (SQL over JDBC)

**Use when:** your service talks to a relational database and you want an integration test against the real engine (not H2).

**Maven deps:**

```xml
<dependency>
  <groupId>org.testcontainers</groupId>
  <artifactId>postgresql</artifactId>
  <version>1.20.4</version>
  <scope>test</scope>
</dependency>
<dependency>
  <groupId>org.postgresql</groupId>
  <artifactId>postgresql</artifactId>
  <version>42.7.4</version>
  <scope>test</scope>
</dependency>
```

**Test:**

```java
package com.classyman.poc;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;

import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers
class PostgresTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES =
        new PostgreSQLContainer<>("postgres:16-alpine");

    @Test
    void selectReturnsExpectedValue() throws Exception {
        try (Connection conn = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
             Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT 42 AS answer")) {

            assertThat(rs.next()).isTrue();
            assertThat(rs.getInt("answer")).isEqualTo(42);
        }
    }
}
```

---

## Kafka (produce + consume)

**Use when:** your service produces or consumes Kafka messages and you want a real broker (with real leader-election, real offsets) for integration.

**Maven deps:**

```xml
<dependency>
  <groupId>org.testcontainers</groupId>
  <artifactId>kafka</artifactId>
  <version>1.20.4</version>
  <scope>test</scope>
</dependency>
<dependency>
  <groupId>org.apache.kafka</groupId>
  <artifactId>kafka-clients</artifactId>
  <version>3.8.1</version>
  <scope>test</scope>
</dependency>
```

**Test:**

```java
package com.classyman.poc;

import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.KafkaContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.time.Duration;
import java.util.List;
import java.util.Properties;

import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers
class KafkaTest {

    private static final String TOPIC = "test-topic";
    private static final String PAYLOAD = "hello-kafka";

    @Container
    static final KafkaContainer KAFKA =
        new KafkaContainer(DockerImageName.parse("confluentinc/cp-kafka:7.6.1"));

    @Test
    void producedMessageIsConsumable() throws Exception {
        Properties producerProps = new Properties();
        producerProps.put("bootstrap.servers", KAFKA.getBootstrapServers());
        producerProps.put("key.serializer", StringSerializer.class.getName());
        producerProps.put("value.serializer", StringSerializer.class.getName());

        try (KafkaProducer<String, String> producer = new KafkaProducer<>(producerProps)) {
            producer.send(new ProducerRecord<>(TOPIC, "k", PAYLOAD)).get();
        }

        Properties consumerProps = new Properties();
        consumerProps.put("bootstrap.servers", KAFKA.getBootstrapServers());
        consumerProps.put("key.deserializer", StringDeserializer.class.getName());
        consumerProps.put("value.deserializer", StringDeserializer.class.getName());
        consumerProps.put("group.id", "test-group");
        consumerProps.put("auto.offset.reset", "earliest");

        try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(consumerProps)) {
            consumer.subscribe(List.of(TOPIC));
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofSeconds(10));

            assertThat(records).hasSize(1);
            assertThat(records.iterator().next().value()).isEqualTo(PAYLOAD);
        }
    }
}
```

---

## Redis (Jedis key/value)

**Use when:** your service caches to Redis, uses it for pub/sub, rate limiting, session storage, etc. Redis doesn't have a dedicated Testcontainers module; `GenericContainer` is the right pattern.

**Maven deps:**

```xml
<dependency>
  <groupId>org.testcontainers</groupId>
  <artifactId>testcontainers</artifactId>
  <version>1.20.4</version>
  <scope>test</scope>
</dependency>
<dependency>
  <groupId>redis.clients</groupId>
  <artifactId>jedis</artifactId>
  <version>5.2.0</version>
  <scope>test</scope>
</dependency>
```

**Test:**

```java
package com.classyman.poc;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;
import redis.clients.jedis.Jedis;

import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers
class RedisTest {

    private static final int REDIS_PORT = 6379;
    private static final String KEY = "greeting";
    private static final String VALUE = "hello-redis";

    @Container
    static final GenericContainer<?> REDIS =
        new GenericContainer<>(DockerImageName.parse("redis:7-alpine"))
            .withExposedPorts(REDIS_PORT);

    @Test
    void setAndGetRoundTrip() {
        try (Jedis jedis = new Jedis(REDIS.getHost(), REDIS.getMappedPort(REDIS_PORT))) {
            jedis.set(KEY, VALUE);

            assertThat(jedis.get(KEY)).isEqualTo(VALUE);
        }
    }
}
```

---

## MongoDB (document insert/find)

**Use when:** your service writes to MongoDB and you want a real mongod (not `fongo` or `de.bwaldvogel.mongo`).

**Maven deps:**

```xml
<dependency>
  <groupId>org.testcontainers</groupId>
  <artifactId>mongodb</artifactId>
  <version>1.20.4</version>
  <scope>test</scope>
</dependency>
<dependency>
  <groupId>org.mongodb</groupId>
  <artifactId>mongodb-driver-sync</artifactId>
  <version>5.2.1</version>
  <scope>test</scope>
</dependency>
```

**Test:**

```java
package com.classyman.poc;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import org.bson.Document;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.MongoDBContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers
class MongoTest {

    private static final String DATABASE = "test";
    private static final String COLLECTION = "docs";
    private static final int ANSWER = 42;

    @Container
    static final MongoDBContainer MONGO =
        new MongoDBContainer(DockerImageName.parse("mongo:7"));

    @Test
    void insertedDocumentIsFindable() {
        try (MongoClient client = MongoClients.create(MONGO.getConnectionString())) {
            MongoCollection<Document> collection =
                client.getDatabase(DATABASE).getCollection(COLLECTION);

            collection.insertOne(new Document("name", "podman-in-docker").append("answer", ANSWER));

            Document found = collection.find(new Document("name", "podman-in-docker")).first();

            assertThat(found).isNotNull();
            assertThat(found.getInteger("answer")).isEqualTo(ANSWER);
        }
    }
}
```

---

## GenericContainer (any image, HTTP probe via nginx)

**Use when:** there's no dedicated Testcontainers module for what you want, and the target exposes its API over HTTP. The pattern works for any single-container service — swap nginx for the image you actually need.

**Maven deps:** just Testcontainers; `java.net.http.HttpClient` is in the JDK, no extra client needed.

```xml
<dependency>
  <groupId>org.testcontainers</groupId>
  <artifactId>testcontainers</artifactId>
  <version>1.20.4</version>
  <scope>test</scope>
</dependency>
```

**Test:**

```java
package com.classyman.poc;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers
class NginxTest {

    private static final int HTTP_PORT = 80;

    @Container
    static final GenericContainer<?> NGINX =
        new GenericContainer<>(DockerImageName.parse("nginx:1.27-alpine"))
            .withExposedPorts(HTTP_PORT)
            .waitingFor(Wait.forHttp("/").forStatusCode(200));

    @Test
    void servesDefaultIndexPage() throws Exception {
        URI endpoint = URI.create(
            "http://" + NGINX.getHost() + ":" + NGINX.getMappedPort(HTTP_PORT) + "/");

        HttpResponse<String> response = HttpClient.newHttpClient().send(
            HttpRequest.newBuilder(endpoint).build(),
            HttpResponse.BodyHandlers.ofString());

        assertThat(response.statusCode()).isEqualTo(200);
        assertThat(response.body()).contains("Welcome to nginx");
    }
}
```

---

## Your own Spring Boot app (WAR in Tomcat, or executable JAR)

**Use when:** you want a black-box integration test against your actual deployed artefact — the real Spring context wired up, the real servlet container, the real embedded server. Two common shapes depending on how you build.

### Shape A — you ship a WAR, drop it into Tomcat

Simplest when you've already got a `target/myapp.war` and you want a plain vanilla servlet container around it.

```java
package com.classyman.poc;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;
import org.testcontainers.utility.MountableFile;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers
class SpringBootWarTest {

    private static final int HTTP_PORT = 8080;
    private static final Path WAR_PATH = Path.of("target/myapp.war");

    @Container
    static final GenericContainer<?> APP =
        new GenericContainer<>(DockerImageName.parse("tomcat:10.1-jdk21"))
            .withCopyFileToContainer(
                MountableFile.forHostPath(WAR_PATH),
                "/usr/local/tomcat/webapps/ROOT.war")
            .withExposedPorts(HTTP_PORT)
            // Spring Boot apps usually expose /actuator/health; swap for your readiness probe.
            .waitingFor(Wait.forHttp("/actuator/health").forStatusCode(200));

    @Test
    void greetingEndpointRespondsOk() throws Exception {
        URI endpoint = URI.create(
            "http://" + APP.getHost() + ":" + APP.getMappedPort(HTTP_PORT) + "/greeting");

        HttpResponse<String> response = HttpClient.newHttpClient().send(
            HttpRequest.newBuilder(endpoint).build(),
            HttpResponse.BodyHandlers.ofString());

        assertThat(response.statusCode()).isEqualTo(200);
        assertThat(response.body()).contains("hello");
    }
}
```

**Maven ordering gotcha:** Surefire (unit tests) runs *before* `package`, so at `mvn test` time the WAR doesn't exist yet. Either:

- Name the test `*IT.java` and let Failsafe run it during `mvn verify` (after the WAR is packaged), **or**
- Add `maven-war-plugin` execution to an earlier phase, **or**
- Run `mvn package` explicitly before invoking the tests.

### Shape B — Spring Boot executable JAR, no servlet container image

If your Spring Boot app uses the default embedded Tomcat/Jetty (most do), skip the Tomcat image and just build a minimal JRE image around your JAR. This is simpler and faster to start.

```java
@Container
static final GenericContainer<?> APP =
    new GenericContainer<>(
        new org.testcontainers.images.builder.ImageFromDockerfile()
            .withFileFromPath("myapp.jar", Path.of("target/myapp.jar"))
            .withDockerfileFromBuilder(b -> b
                .from("eclipse-temurin:21-jre")
                .add("myapp.jar", "/app/myapp.jar")
                .entryPoint("java", "-jar", "/app/myapp.jar")
                .build()))
        .withExposedPorts(8080)
        .waitingFor(Wait.forHttp("/actuator/health").forStatusCode(200));
```

This builds a one-off image on each test run (not great for throughput). In a real CI pipeline you'd usually:

1. Have `mvn package` (or `bootBuildImage`) produce `myapp:${build.number}`.
2. Reference the pre-built tag from the test with `new GenericContainer<>("myapp:${build.number}")`.

### Caveats specific to Spring Boot

- **Cold start.** JVM + Spring context init is slower than a bare service; bump the wait-strategy timeout to 60–120 s for anything real.
- **Memory.** Tomcat + Spring easily passes 500 MB RSS. If your CI agent is tight, give the container an explicit limit via `.withCreateContainerCmdModifier(...)` or a compose file.
- **Profiles and config.** Pass test-specific config via env vars: `.withEnv("SPRING_PROFILES_ACTIVE", "integration")`, `.withEnv("SPRING_DATASOURCE_URL", ...)`. Testcontainers plays nicely with spring-boot-testcontainers (the Spring Boot integration module) if you want `@ServiceConnection` wiring.
- **Build–test ordering** is the thing people hit most often — see the Surefire/Failsafe note above.
