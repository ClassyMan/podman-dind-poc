package com.classyman.poc;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

@Testcontainers
class PodmanInDockerTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES =
        new PostgreSQLContainer<>("postgres:16-alpine");

    @Test
    void postgresContainerIsRunning() {
        assertTrue(POSTGRES.isRunning(),
            "Testcontainers should have started the Postgres container via the Podman docker-compat socket");
    }

    @Test
    void postgresAcceptsQueriesOverJdbc() throws Exception {
        try (Connection conn = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
             Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT 42 AS answer")) {
            assertTrue(rs.next(), "Postgres should have returned at least one row");
            assertEquals(42, rs.getInt("answer"),
                "The Postgres container is reachable and returns real query results");
        }
    }
}
