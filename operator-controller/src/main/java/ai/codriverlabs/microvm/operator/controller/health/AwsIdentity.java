package ai.codriverlabs.microvm.operator.controller.health;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * Stores AWS account identity resolved at startup via STS GetCallerIdentity.
 * Used by reconcilers to construct resource ARNs from names.
 */
@ApplicationScoped
public class AwsIdentity {

    private volatile String accountId;
    private volatile String region;

    public void set(String accountId, String region) {
        this.accountId = accountId;
        this.region = region;
    }

    public String getAccountId() {
        return accountId;
    }

    public String getRegion() {
        return region;
    }

    /**
     * Constructs a MicroVM image ARN from a short name.
     * Returns null if account identity has not been resolved yet.
     */
    public String constructImageArn(String imageName) {
        if (accountId == null || region == null) return null;
        return String.format("arn:aws:lambda:%s:%s:microvm-image:%s", region, accountId, imageName);
    }

    /**
     * Constructs a network connector ARN from a short name.
     * Returns null if account identity has not been resolved yet.
     */
    public String constructNetworkConnectorArn(String connectorName) {
        if (accountId == null || region == null) return null;
        return String.format("arn:aws:lambda:%s:%s:network-connector:%s", region, accountId, connectorName);
    }
}
