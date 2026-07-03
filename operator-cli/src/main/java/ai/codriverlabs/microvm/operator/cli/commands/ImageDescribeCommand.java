package ai.codriverlabs.microvm.operator.cli.commands;

import ai.codriverlabs.microvm.operator.core.model.MicroVMImage;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageStatus;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageVersionInfo;
import io.fabric8.kubernetes.client.KubernetesClient;
import jakarta.inject.Inject;
import picocli.CommandLine.Command;
import picocli.CommandLine.Option;
import picocli.CommandLine.Parameters;

@Command(name = "describe", description = "Show details of a MicroVM image", mixinStandardHelpOptions = true)
public class ImageDescribeCommand implements Runnable {

    @Parameters(index = "0", arity = "0..1", description = "Name of the MicroVMImage")
    String namePos;

    @Option(names = {"--name"}, description = "Name of the MicroVMImage")
    String nameOpt;

    @Option(names = {"-n", "--namespace"}, defaultValue = "default", description = "Namespace")
    String namespace;

    private String resolveName() {
        String n = nameOpt != null ? nameOpt : namePos;
        if (n == null || n.isBlank()) {
            System.err.println("Error: name required — pass as positional arg or --name");
            System.exit(1);
        }
        return n;
    }

    @Inject
    KubernetesClient client;

    @Override
    public void run() {
        String name = resolveName();
        MicroVMImage image = client.resources(MicroVMImage.class)
            .inNamespace(namespace).withName(name).get();

        if (image == null) {
            System.err.printf("Error: MicroVMImage \"%s\" not found in namespace \"%s\"%n", name, namespace);
            System.exit(1);
            return;
        }

        System.out.printf("Name:           %s%n", image.getMetadata().getName());
        System.out.printf("Namespace:      %s%n", image.getMetadata().getNamespace());

        if (image.getSpec().getSource() != null) {
            System.out.printf("Source:         s3://%s/%s%n",
                image.getSpec().getSource().getS3Bucket(), image.getSpec().getSource().getS3Key());
        }
        if (image.getSpec().getBaseImageArn() != null) {
            System.out.printf("Base Image:     %s%n", image.getSpec().getBaseImageArn());
        }
        System.out.printf("Build Timeout:  %ds%n",
            image.getSpec().getBuildTimeoutSeconds() != null ? image.getSpec().getBuildTimeoutSeconds() : 600);
        System.out.printf("Auto-Activate:  %s%n",
            image.getSpec().getAutoActivate() != null ? image.getSpec().getAutoActivate() : true);
        if (image.getSpec().getMemorySizeMiB() != null) {
            System.out.printf("Memory:         %d MiB%n", image.getSpec().getMemorySizeMiB());
        } else {
            System.out.printf("Memory:         default (2048 MiB)%n");
        }

        MicroVMImageStatus status = image.getStatus();
        if (status != null) {
            System.out.println();
            System.out.printf("State:          %s%n", status.getImageState() != null ? status.getImageState() : "-");
            if (status.getImageArn() != null) System.out.printf("Image ARN:      %s%n", status.getImageArn());
            if (status.getComputeProfile() != null) System.out.printf("Compute:        %s%n", status.getComputeProfile());
            System.out.printf("Active Version: %s%n", status.getActiveVersion() != null ? status.getActiveVersion() : "-");
            System.out.printf("Latest Version: %s%n", status.getLatestVersion() != null ? status.getLatestVersion() : "-");

            if (status.getVersions() != null && !status.getVersions().isEmpty()) {
                System.out.println();
                System.out.println("Versions:");
                System.out.printf("  %-8s %-14s %-25s %-25s%n", "VER", "STATE", "STARTED", "BUILT");
                for (MicroVMImageVersionInfo v : status.getVersions()) {
                    System.out.printf("  %-8s %-14s %-25s %-25s%n",
                        v.getVersion(),
                        v.getState() != null ? v.getState() : "-",
                        v.getStartedAt() != null ? v.getStartedAt() : "-",
                        v.getBuiltAt() != null ? v.getBuiltAt() : "-");
                    if (v.getFailureReason() != null) {
                        System.out.printf("           Reason: %s%n", v.getFailureReason());
                    }
                }
            }
        }
    }
}
