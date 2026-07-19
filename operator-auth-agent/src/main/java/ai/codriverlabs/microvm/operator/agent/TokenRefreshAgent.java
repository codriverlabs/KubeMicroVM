package ai.codriverlabs.microvm.operator.agent;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.quarkus.runtime.StartupEvent;
import io.quarkus.runtime.annotations.RegisterForReflection;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.*;
import java.nio.file.StandardOpenOption;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/**
 * MicroVM Auth Agent — sidecar that keeps a MicroVM auth token fresh on disk.
 *
 * Lifecycle:
 * 1. On startup: wait for MicroVM to be RUNNING (polls operator), then fetch first token
 * 2. Refresh loop: re-fetches token at 80% of expiry interval
 * 3. Writes to mount-path atomically (temp file + rename)
 *
 * Files written to mount-path:
 *   auth-token  — raw JWE string for X-aws-proxy-auth header
 *   endpoint    — MicroVM HTTPS hostname
 *   expires-at  — RFC3339 expiry timestamp
 *   .ready      — written once token is first available
 */
@ApplicationScoped
public class TokenRefreshAgent {

    private static final Logger LOG = Logger.getLogger(TokenRefreshAgent.class);
    private static final int STARTUP_POLL_INTERVAL_S = 5;
    private static final int STARTUP_MAX_WAIT_S = 300;

    @ConfigProperty(name = "microvm.agent.operator-url") String operatorUrl;
    @ConfigProperty(name = "microvm.agent.vm-name") String vmName;
    @ConfigProperty(name = "microvm.agent.namespace") String namespace;
    @ConfigProperty(name = "microvm.agent.mount-path") String mountPath;
    @ConfigProperty(name = "microvm.agent.expiry-minutes", defaultValue = "30") int expiryMinutes;
    @ConfigProperty(name = "microvm.agent.sa-token-path") String saTokenPath;

    private final HttpClient http = buildHttpClient();
    private final ObjectMapper json = new ObjectMapper();
    private volatile boolean running = true;

    private static HttpClient buildHttpClient() {
        try {
            // Trust all certs — operator uses a self-signed cert-manager certificate.
            // The connection is in-cluster (pod → operator service), so TLS provides
            // encryption; the self-signed cert is acceptable here.
            TrustManager[] trustAll = new TrustManager[]{
                new X509TrustManager() {
                    public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
                    public void checkClientTrusted(X509Certificate[] c, String a) {}
                    public void checkServerTrusted(X509Certificate[] c, String a) {}
                }
            };
            SSLContext sslCtx = SSLContext.getInstance("TLS");
            sslCtx.init(null, trustAll, new SecureRandom());
            return HttpClient.newBuilder()
                    .connectTimeout(Duration.ofSeconds(10))
                    .sslContext(sslCtx)
                    .build();
        } catch (Exception e) {
            throw new RuntimeException("Failed to build HTTP client", e);
        }
    }

    void onStart(@Observes StartupEvent ev) {
        Thread.ofVirtual().name("token-refresh-agent").start(this::run);
    }

    private void run() {
        try {
            Path mount = Path.of(mountPath);
            Files.createDirectories(mount);
            LOG.infof("Token agent starting for MicroVM %s/%s → %s", namespace, vmName, mountPath);

            // 1. Wait for token endpoint to be available (VM RUNNING)
            TokenResponse token = waitAndFetch();
            if (token == null) {
                LOG.error("Timed out waiting for MicroVM token — exiting");
                return;
            }
            writeToken(mount, token);

            // 2. Refresh loop
            while (running) {
                long refreshInSeconds = (long) (expiryMinutes * 60 * 0.8);
                Thread.sleep(Duration.ofSeconds(refreshInSeconds));
                try {
                    token = fetchToken();
                    if (token != null) {
                        writeToken(mount, token);
                        LOG.infof("Token refreshed, expires at %s", token.expiresAt);
                    }
                } catch (Exception e) {
                    LOG.warnf("Token refresh failed (will retry): %s", e.getMessage());
                }
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } catch (Exception e) {
            LOG.errorf(e, "Token agent failed");
        }
    }

    private TokenResponse waitAndFetch() throws InterruptedException {
        int waited = 0;
        while (waited < STARTUP_MAX_WAIT_S) {
            try {
                TokenResponse t = fetchToken();
                if (t != null) return t;
            } catch (Exception e) {
                LOG.debugf("Token not yet available (%s), retrying in %ds", e.getMessage(), STARTUP_POLL_INTERVAL_S);
            }
            Thread.sleep(Duration.ofSeconds(STARTUP_POLL_INTERVAL_S));
            waited += STARTUP_POLL_INTERVAL_S;
        }
        return null;
    }

    private TokenResponse fetchToken() throws Exception {
        String saToken = Files.readString(Path.of(saTokenPath)).trim();
        String url = String.format("%s/apis/lambda.aws.amazon.com/v1alpha1/namespaces/%s/microvms/%s/token",
                operatorUrl, namespace, vmName);
        String body = String.format("{\"expirationInMinutes\":%d,\"allowedPorts\":[{\"allPorts\":{}}]}", expiryMinutes);

        HttpRequest req = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .header("Authorization", "Bearer " + saToken)
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .timeout(Duration.ofSeconds(15))
                .build();

        HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (resp.statusCode() != 200) {
            throw new IOException("HTTP " + resp.statusCode() + ": " + resp.body());
        }
        return json.readValue(resp.body(), TokenResponse.class);
    }

    private void writeToken(Path mount, TokenResponse token) throws IOException {
        // Atomic write: write to temp file then rename (avoids partial reads)
        atomicWrite(mount.resolve("auth-token"), token.authToken);
        atomicWrite(mount.resolve("endpoint"), token.endpoint != null ? token.endpoint : "");
        atomicWrite(mount.resolve("expires-at"), token.expiresAt != null ? token.expiresAt : "");
        // Signal readiness on first write
        Path ready = mount.resolve(".ready");
        if (!Files.exists(ready)) Files.createFile(ready);
        LOG.infof("Token written to %s", mountPath);
    }

    private void atomicWrite(Path target, String content) throws IOException {
        Path tmp = target.resolveSibling(target.getFileName() + ".tmp");
        Files.writeString(tmp, content, StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
        Files.move(tmp, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    @RegisterForReflection
    public static class TokenResponse {
        public String authToken;
        public String endpoint;
        public String expiresAt;
    }
}
