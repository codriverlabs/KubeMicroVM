package ai.codriverlabs.microvm.operator.cli.commands;

import software.amazon.awssdk.services.lambdamicrovms.LambdaMicrovmsClient;
import software.amazon.awssdk.services.lambdamicrovms.model.*;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImage;
import io.fabric8.kubernetes.client.KubernetesClient;
import jakarta.inject.Inject;
import picocli.CommandLine;
import picocli.CommandLine.Command;
import picocli.CommandLine.Option;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;

/**
 * kubectl microvm image version-delete — delete a specific MicroVM image version.
 *
 * Usage:
 *   kubectl microvm image version-delete --name my-image --version 1.0
 */
@Command(name = "version-delete",
        description = "Delete a specific MicroVM image version",
        mixinStandardHelpOptions = true)
public class ImageVersionDeleteCommand implements Runnable {

    @Option(names = {"--name"}, description = "Name of the MicroVMImage CR")
    String name;

    @Option(names = {"--version"}, description = "Image version to delete (e.g. 1.0)")
    String version;

    @Option(names = {"-n", "--namespace"}, defaultValue = "default", description = "Namespace")
    String namespace;

    @Option(names = {"--region"}, description = "AWS region")
    String region;

    @CommandLine.Spec
    CommandLine.Model.CommandSpec spec;

    @Option(names = {"-h", "--help"}, usageHelp = true, description = "Show this help message and exit.")
    boolean helpRequested;

    @Inject
    KubernetesClient client;

    @Override
    public void run() {
        // Validate required options manually so --help works cleanly
        if (name == null || name.isBlank()) {
            System.err.println("Error: --name is required");
            spec.commandLine().usage(System.err);
            System.exit(1); return;
        }
        if (version == null || version.isBlank()) {
            System.err.println("Error: --version is required");
            spec.commandLine().usage(System.err);
            System.exit(1); return;
        }
        MicroVMImage image = client.resources(MicroVMImage.class)
                .inNamespace(namespace).withName(name).get();
        if (image == null) {
            System.err.printf("Error: MicroVMImage \"%s\" not found in namespace \"%s\"%n", name, namespace);
            System.exit(1);
            return;
        }
        if (image.getStatus() == null || image.getStatus().getImageArn() == null) {
            System.err.printf("MicroVMImage '%s' has no imageArn in status%n", name);
            System.exit(1);
            return;
        }

        String imageArn = image.getStatus().getImageArn();
        String awsRegion = region != null ? region
                : (image.getSpec().getRegion() != null ? image.getSpec().getRegion() : "us-east-1");

        try (LambdaMicrovmsClient awsClient = LambdaMicrovmsClient.builder()
                .region(Region.of(awsRegion))
                .httpClient(UrlConnectionHttpClient.create())
                .build()) {
            awsClient.deleteMicrovmImageVersion(DeleteMicrovmImageVersionRequest.builder()
                    .imageIdentifier(imageArn)
                    .imageVersion(version)
                    .build());
            System.out.printf("microvm-image/%s version %s deleted%n", name, version);
        } catch (Exception e) {
            System.err.printf("Error deleting image version: %s%n", e.getMessage());
            System.exit(1);
        }
    }
}
