package ai.codriverlabs.microvm.operator.cli.commands;

import ai.codriverlabs.microvm.operator.core.model.MicroVMImage;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageSource;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageSpec;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.KubernetesClientException;
import jakarta.inject.Inject;
import picocli.CommandLine.Command;
import picocli.CommandLine.Option;

@Command(name = "update", description = "Update a MicroVM image with new source (triggers rebuild)", mixinStandardHelpOptions = true)
public class ImageUpdateCommand implements Runnable {

    @Option(names = {"--name"}, required = true, description = "Name of the MicroVMImage to update")
    String name;

    @Option(names = {"--s3-key"}, required = true, description = "New S3 key for the updated source zip")
    String s3Key;

    @Option(names = {"--s3-bucket"}, description = "S3 bucket (if changing)")
    String s3Bucket;

    @Option(names = {"--build-role-arn"}, description = "IAM role ARN Lambda assumes during image build")
    String buildRoleArn;

    @Option(names = {"--wait"}, description = "Wait for build to complete and print state transitions")
    boolean wait;

    @Option(names = {"--wait-timeout"}, defaultValue = "600", description = "Wait timeout in seconds (default: 600)")
    int waitTimeout;

    @Option(names = {"-n", "--namespace"}, defaultValue = "default", description = "Namespace")
    String namespace;

    @Inject
    KubernetesClient client;

    @Override
    public void run() {
        try {
            MicroVMImage image = client.resources(MicroVMImage.class)
                .inNamespace(namespace).withName(name).get();

            if (image == null) {
                System.err.printf("Error: MicroVMImage \"%s\" not found in namespace \"%s\"%n", name, namespace);
                System.exit(1);
                return;
            }

            MicroVMImageSource source = image.getSpec().getSource();
            if (s3Bucket != null) source.setS3Bucket(s3Bucket);
            source.setS3Key(s3Key);
            if (buildRoleArn != null) image.getSpec().setBuildRoleArn(buildRoleArn);

            client.resource(image).inNamespace(namespace).update();
            System.out.printf("microvm-image/%s updated (new source: s3://%s/%s) — build will start%n",
                name, source.getS3Bucket(), s3Key);

            if (wait) {
                boolean success = new ImageWaiter(client, name, namespace, waitTimeout).waitForBuild();
                if (!success) System.exit(1);
            }
        } catch (KubernetesClientException e) {
            System.err.println("Error updating MicroVMImage: " + e.getMessage());
            System.exit(1);
        }
    }
}
