package ai.codriverlabs.microvm.operator.cli.commands;

import ai.codriverlabs.microvm.aws.lambdamicrovms.LambdaMicrovmsClient;
import ai.codriverlabs.microvm.aws.lambdamicrovms.model.*;
import picocli.CommandLine.Command;
import picocli.CommandLine.Option;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;

import java.util.List;

/**
 * kubectl microvm image base-images — list available Lambda-managed MicroVM base images.
 *
 * Usage:
 *   kubectl microvm image base-images
 *   kubectl microvm image base-images --region us-east-1
 *   kubectl microvm image base-images --arn arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1
 */
@Command(name = "base-images",
        description = "List available Lambda-managed MicroVM base images",
        mixinStandardHelpOptions = true)
public class ImageBaseImagesCommand implements Runnable {

    @Option(names = {"--region"}, defaultValue = "us-east-1", description = "AWS region (default: us-east-1)")
    String region;

    @Option(names = {"--arn"}, description = "Show versions for a specific base image ARN")
    String imageArn;

    @Override
    public void run() {
        try (LambdaMicrovmsClient awsClient = LambdaMicrovmsClient.builder()
                .region(Region.of(region))
                .httpClient(UrlConnectionHttpClient.create())
                .build()) {

            if (imageArn != null) {
                // List versions of a specific base image
                List<ManagedMicrovmImageVersion> versions = awsClient
                        .listManagedMicrovmImageVersions(
                                ListManagedMicrovmImageVersionsRequest.builder()
                                        .imageIdentifier(imageArn).build())
                        .items();
                System.out.printf("%-20s  %-30s  %s%n", "VERSION", "CREATED", "ARN");
                for (var v : versions) {
                    System.out.printf("%-20s  %-30s  %s%n",
                            v.imageVersion() != null ? v.imageVersion() : "-",
                            v.createdAt() != null ? v.createdAt().toString() : "-",
                            v.imageArn() != null ? v.imageArn() : "-");
                }
            } else {
                // List all managed base images
                List<ManagedMicrovmImageSummary> images = awsClient
                        .listManagedMicrovmImages(ListManagedMicrovmImagesRequest.builder().build())
                        .items();
                System.out.printf("%-60s  %s%n", "ARN", "CREATED");
                for (var img : images) {
                    System.out.printf("%-60s  %s%n",
                            img.imageArn(),
                            img.createdAt() != null ? img.createdAt().toString() : "-");
                }
            }
        } catch (Exception e) {
            System.err.printf("Error listing base images: %s%n", e.getMessage());
            System.exit(1);
        }
    }
}
