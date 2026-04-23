package com.classyman.poc;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.localstack.LocalStackContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.CreateBucketRequest;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;

import static org.assertj.core.api.Assertions.assertThat;
import static org.testcontainers.containers.localstack.LocalStackContainer.Service.S3;

@Testcontainers
class PodmanInDockerTest {

    private static final String BUCKET = "podman-dind-poc-bucket";
    private static final String KEY = "hello.txt";
    private static final String CONTENT = "Hello from podman-in-docker!";

    @Container
    static final LocalStackContainer LOCALSTACK =
        new LocalStackContainer(DockerImageName.parse("localstack/localstack:3.8"))
            .withServices(S3);

    private static S3Client s3;

    @BeforeAll
    static void createClientAndBucket() {
        s3 = S3Client.builder()
            .endpointOverride(LOCALSTACK.getEndpointOverride(S3))
            .credentialsProvider(StaticCredentialsProvider.create(
                AwsBasicCredentials.create(LOCALSTACK.getAccessKey(), LOCALSTACK.getSecretKey())))
            .region(Region.of(LOCALSTACK.getRegion()))
            .build();
        s3.createBucket(CreateBucketRequest.builder().bucket(BUCKET).build());
    }

    @Test
    void localstackContainerIsRunning() {
        assertThat(LOCALSTACK.isRunning())
            .as("Testcontainers should have started the LocalStack container via the Podman docker-compat socket")
            .isTrue();
    }

    @Test
    void s3PutAndGetRoundTrip() {
        s3.putObject(
            PutObjectRequest.builder().bucket(BUCKET).key(KEY).build(),
            RequestBody.fromString(CONTENT));

        String retrieved = s3.getObjectAsBytes(
            GetObjectRequest.builder().bucket(BUCKET).key(KEY).build()
        ).asUtf8String();

        assertThat(retrieved)
            .as("S3 object retrieved from LocalStack should match what was put")
            .isEqualTo(CONTENT);
    }
}
