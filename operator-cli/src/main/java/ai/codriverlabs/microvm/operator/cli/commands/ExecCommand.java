package ai.codriverlabs.microvm.operator.cli.commands;

import software.amazon.awssdk.services.lambdamicrovms.LambdaMicrovmsClient;
import software.amazon.awssdk.services.lambdamicrovms.model.*;
import ai.codriverlabs.microvm.operator.core.model.MicroVM;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.fabric8.kubernetes.client.KubernetesClient;
import jakarta.inject.Inject;
import picocli.CommandLine.Command;
import picocli.CommandLine.Option;
import picocli.CommandLine.Parameters;
import software.amazon.awssdk.regions.Region;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;

/**
 * kubectl microvm exec — get shell access credentials for a running MicroVM.
 *
 * Prints the shell auth token and WebSocket endpoint.
 * Full terminal session requires an external WebSocket client.
 *
 * Fallback chain (same as `token`):
 * 1. Operator sub-resource POST .../token (works in-cluster without AWS credentials)
 * 2. AWS SDK CreateMicrovmShellAuthToken (requires AWS credentials)
 *
 * Usage:
 *   kubectl microvm exec my-vm
 *   kubectl microvm exec my-vm --show-token   # raw token only (pipeable)
 *   kubectl microvm exec my-vm --direct       # skip operator, call AWS directly
 */
@Command(name = "exec", description = "Get shell access credentials for a running MicroVM",
        mixinStandardHelpOptions = true)
public class ExecCommand implements Runnable {

    @Parameters(index = "0", description = "Name of the MicroVM")
    String name;

    @Parameters(index = "1..*", description = "Command hint (display only)", arity = "0..*")
    List<String> command;

    @Option(names = {"-n", "--namespace"}, defaultValue = "default")
    String namespace;

    @Option(names = {"--expires"}, defaultValue = "30", description = "Token expiry in minutes")
    int expiresMinutes;

    @Option(names = {"--show-token"}, description = "Print raw shell auth token only")
    boolean showToken;

    @Option(names = {"--region"}, description = "AWS region")
    String region;

    @Option(names = {"--direct"}, description = "Skip operator, call AWS directly (requires AWS credentials)")
    boolean direct;

    @Inject
    KubernetesClient client;

    private static final ObjectMapper JSON = new ObjectMapper();

    @Override
    public void run() {
        MicroVM vm = client.resources(MicroVM.class).inNamespace(namespace).withName(name).get();
        if (vm == null) {
            System.err.printf("MicroVM \"%s\" not found%n", name); System.exit(1); return;
        }
        if (vm.getStatus() == null || vm.getStatus().getMicroVmId() == null) {
            System.err.printf("MicroVM '%s' has no microvmId (state: %s)%n",
                    name, vm.getStatus() != null ? vm.getStatus().getState() : "unknown");
            System.exit(1); return;
        }

        String endpoint = vm.getStatus().getEndpointUrl();

        if (!direct) {
            // Shell tokens go through the same operator endpoint with allPorts
            String token = tryOperatorEndpoint();
            if (token != null) {
                printShellAccess(token, endpoint); return;
            }
            System.err.println("[exec] Operator endpoint unavailable, falling back to AWS SDK");
        }
        callAwsDirect(vm, endpoint);
    }

    private String tryOperatorEndpoint() {
        try {
            String apiServer = client.getConfiguration().getMasterUrl();
            String bearerToken = client.getConfiguration().getOauthToken();
            if (bearerToken == null || bearerToken.isBlank()) {
                Path saToken = Path.of("/var/run/secrets/kubernetes.io/serviceaccount/token");
                if (Files.exists(saToken)) bearerToken = Files.readString(saToken).trim();
            }
            if (bearerToken == null || bearerToken.isBlank()) return null;

            String body = String.format(
                    "{\"expirationInMinutes\":%d,\"allowedPorts\":[{\"allPorts\":{}}]}", expiresMinutes);
            String url = String.format("%s/apis/lambda.aws.amazon.com/v1alpha1/namespaces/%s/microvms/%s/token",
                    apiServer.replaceAll("/$", ""), namespace, name);

            HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
            HttpRequest req = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .header("Authorization", "Bearer " + bearerToken)
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(body))
                    .timeout(Duration.ofSeconds(10))
                    .build();

            HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
            if (resp.statusCode() == 200) {
                JsonNode node = JSON.readTree(resp.body());
                return node.path("authToken").asText(null);
            } else if (resp.statusCode() == 403) {
                JsonNode node = JSON.readTree(resp.body());
                System.err.println("Error: " + node.path("error").asText("not authorized"));
                System.exit(1); return null;
            }
            return null; // fall back to AWS
        } catch (Exception e) {
            return null;
        }
    }

    private void callAwsDirect(MicroVM vm, String endpoint) {
        String microvmId = vm.getStatus().getMicroVmId();
        String awsRegion = region != null ? region
                : (vm.getSpec().getRegion() != null ? vm.getSpec().getRegion() : "us-east-1");
        try (LambdaMicrovmsClient awsClient = LambdaMicrovmsClient.builder()
                .region(Region.of(awsRegion)).build()) {
            var response = awsClient.createMicrovmShellAuthToken(
                    CreateMicrovmShellAuthTokenRequest.builder()
                            .microvmIdentifier(microvmId)
                            .expirationInMinutes(expiresMinutes)
                            .build());
            String token = response.authToken().getOrDefault("X-aws-proxy-auth",
                    response.authToken().values().iterator().next());
            printShellAccess(token, endpoint);
        } catch (Exception e) {
            System.err.printf("Error creating shell token: %s%n", e.getMessage());
            System.exit(1);
        }
    }

    private void printShellAccess(String token, String endpoint) {
        if (showToken) {
            System.out.println(token); return;
        }
        System.out.printf("MicroVM: %s%n", name);
        System.out.printf("Endpoint: wss://%s/aws/lambda-microvms/runtime/v1/shell%n", endpoint);
        System.out.printf("Token (X-aws-proxy-auth): %s%n", token);
        System.out.println();
        System.out.println("Connect with subprotocols:");
        System.out.printf("  lambda-microvms%n");
        System.out.printf("  lambda-microvms.authentication.%s%n", token);
    }
}
