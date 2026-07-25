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
import software.amazon.awssdk.regions.Region;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;

/**
 * kubectl microvm token — generate a short-lived JWE auth token for connecting to a MicroVM.
 *
 * Fallback chain:
 * 1. Operator sub-resource (POST .../microvms/{name}/token) using kubeconfig credential — works
 *    in-cluster and locally without AWS credentials.
 * 2. Direct AWS SDK call (CreateMicrovmAuthToken) — requires AWS credentials in environment.
 *    Used when the operator endpoint is unavailable (404) or returns 501.
 *
 * Use --direct to skip the operator and call AWS directly (for debugging/testing).
 *
 * Usage:
 *   kubectl microvm token --name my-vm
 *   kubectl microvm token --name my-vm --expires 60 --port 8080
 *   kubectl microvm token --name my-vm --direct
 *
 * Pipe into curl:
 *   curl https://<endpoint>/ -H "X-aws-proxy-auth: $(kubectl microvm token --name my-vm)"
 */
@Command(name = "token",
        description = "Generate an auth token for connecting to a running MicroVM endpoint",
        mixinStandardHelpOptions = true)
public class TokenCommand implements Runnable {

    @Option(names = {"--name"}, required = true, description = "Name of the MicroVM CR")
    String name;

    @Option(names = {"-n", "--namespace"}, defaultValue = "default", description = "Namespace")
    String namespace;

    @Option(names = {"--expires"}, defaultValue = "30",
            description = "Token expiry in minutes (default: 30)")
    int expiresMinutes;

    @Option(names = {"--port"}, description = "Scope token to a specific port (default: all ports)")
    Integer port;

    @Option(names = {"--show-endpoint"}, description = "Also print the endpoint URL to stderr")
    boolean showEndpoint;

    @Option(names = {"--region"}, description = "AWS region (default: from MicroVM spec or us-east-1)")
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
            System.err.printf("Error: MicroVM \"%s\" not found in namespace \"%s\"%n", name, namespace);
            System.exit(1); return;
        }
        if (vm.getStatus() == null || vm.getStatus().getMicroVmId() == null) {
            System.err.printf("MicroVM '%s' has no microvmId in status (state: %s)%n",
                    name, vm.getStatus() != null ? vm.getStatus().getState() : "unknown");
            System.exit(1); return;
        }

        String endpoint = vm.getStatus().getEndpointUrl();

        if (!direct) {
            // Try operator sub-resource first
            OperatorTokenResult result = tryOperatorEndpoint();
            if (result != null) {
                if (result.error != null) {
                    System.err.println("Error: " + result.error);
                    System.exit(1); return;
                }
                if (showEndpoint && endpoint != null) System.err.println("endpoint: " + endpoint);
                System.out.println(result.token);
                return;
            }
            // Operator endpoint unavailable — fall back to AWS
            System.err.println("[token] Operator endpoint unavailable, falling back to AWS SDK");
        }

        // Direct AWS call
        callAwsDirect(vm, endpoint);
    }

    private OperatorTokenResult tryOperatorEndpoint() {
        try {
            // Resolve k8s API server URL and Bearer token from kubeconfig/in-cluster config
            String apiServer = client.getConfiguration().getMasterUrl();
            String bearerToken = client.getConfiguration().getOauthToken();
            if (bearerToken == null || bearerToken.isBlank()) {
                // In-cluster: read from projected service account
                Path saToken = Path.of("/var/run/secrets/kubernetes.io/serviceaccount/token");
                if (Files.exists(saToken)) bearerToken = Files.readString(saToken).trim();
            }
            if (bearerToken == null || bearerToken.isBlank()) return null;

            String portsJson = port != null
                    ? String.format("[{\"port\":%d}]", port)
                    : "[{\"allPorts\":{}}]";
            String body = String.format(
                    "{\"expirationInMinutes\":%d,\"allowedPorts\":%s}", expiresMinutes, portsJson);

            String url = String.format("%s/apis/lambda.aws.amazon.com/v1alpha1/namespaces/%s/microvms/%s/token",
                    apiServer.replaceAll("/$", ""), namespace, name);

            HttpClient http = HttpClient.newBuilder()
                    .connectTimeout(Duration.ofSeconds(5))
                    .build();
            HttpRequest req = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .header("Authorization", "Bearer " + bearerToken)
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(body))
                    .timeout(Duration.ofSeconds(10))
                    .build();

            HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
            int status = resp.statusCode();

            if (status == 200) {
                JsonNode node = JSON.readTree(resp.body());
                return new OperatorTokenResult(node.path("authToken").asText(null), null);
            } else if (status == 403) {
                JsonNode node = JSON.readTree(resp.body());
                return new OperatorTokenResult(null, node.path("error").asText(
                        "not authorized — ask your admin for microvm-token-requester Role on " + name));
            } else if (status == 404 || status == 501 || status == 503) {
                return null; // endpoint not available — fall back to AWS
            } else {
                JsonNode node = JSON.readTree(resp.body());
                return new OperatorTokenResult(null, "operator returned HTTP " + status
                        + ": " + node.path("error").asText(resp.body()));
            }
        } catch (java.net.ConnectException | java.net.http.HttpConnectTimeoutException e) {
            return null; // operator not reachable — fall back to AWS
        } catch (Exception e) {
            return null; // any other error — fall back to AWS
        }
    }

    private void callAwsDirect(MicroVM vm, String endpoint) {
        String microvmId = vm.getStatus().getMicroVmId();
        String awsRegion = region != null ? region
                : (vm.getSpec().getRegion() != null ? vm.getSpec().getRegion() : "us-east-1");

        PortSpecification portSpec = port != null
                ? PortSpecification.builder().port(port).build()
                : PortSpecification.builder().allPorts(Unit.builder().build()).build();

        try (LambdaMicrovmsClient awsClient = LambdaMicrovmsClient.builder()
                .region(Region.of(awsRegion)).build()) {
            var response = awsClient.createMicrovmAuthToken(
                    CreateMicrovmAuthTokenRequest.builder()
                            .microvmIdentifier(microvmId)
                            .expirationInMinutes(expiresMinutes)
                            .allowedPorts(portSpec)
                            .build());
            if (showEndpoint && endpoint != null) System.err.println("endpoint: " + endpoint);
            String token = response.authToken().getOrDefault("X-aws-proxy-auth",
                    response.authToken().values().iterator().next());
            System.out.println(token);
        } catch (Exception e) {
            System.err.printf("Error creating auth token for MicroVM '%s': %s%n", name, e.getMessage());
            System.exit(1);
        }
    }

    private record OperatorTokenResult(String token, String error) {}
}
