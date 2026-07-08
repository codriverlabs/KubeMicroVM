package ai.codriverlabs.microvm.operator.core.model;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.List;
import java.util.Map;
import java.util.Objects;

@JsonInclude(JsonInclude.Include.NON_NULL)
public class MicroVMNetworkSpec {
    private List<String> subnetIds;
    private List<String> securityGroupIds;
    /** IAM role ARN that Lambda assumes to create ENIs in the customer VPC. */
    private String operatorRoleArn;
    /** IPv4 (default) or DualStack */
    private String networkProtocol = "IPv4";
    private String region;
    private Map<String, String> tags;
    /**
     * Optional: the AWS-side connector name to use for creation and adoption.
     *
     * When set, this exact name is used as the Lambda Core network connector name,
     * enabling import of connectors created outside Kubernetes (e.g. via AWS CLI).
     *
     * When not set, the connector name defaults to {@code <namespace>-<CR-name>}
     * (e.g. CR "my-connector" in namespace "default" → AWS name "default-my-connector").
     *
     * Immutable after creation — changing this field after the connector is created
     * would cause a name mismatch between spec and the actual AWS resource.
     */
    private String connectorName;

    public MicroVMNetworkSpec() {}

    public List<String> getSubnetIds() { return subnetIds; }
    public void setSubnetIds(List<String> subnetIds) { this.subnetIds = subnetIds; }
    public List<String> getSecurityGroupIds() { return securityGroupIds; }
    public void setSecurityGroupIds(List<String> securityGroupIds) { this.securityGroupIds = securityGroupIds; }
    public String getOperatorRoleArn() { return operatorRoleArn; }
    public void setOperatorRoleArn(String operatorRoleArn) { this.operatorRoleArn = operatorRoleArn; }
    public String getNetworkProtocol() { return networkProtocol; }
    public void setNetworkProtocol(String networkProtocol) { this.networkProtocol = networkProtocol; }
    public String getRegion() { return region; }
    public void setRegion(String region) { this.region = region; }
    public Map<String, String> getTags() { return tags; }
    public void setTags(Map<String, String> tags) { this.tags = tags; }
    public String getConnectorName() { return connectorName; }
    public void setConnectorName(String connectorName) { this.connectorName = connectorName; }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (o == null || getClass() != o.getClass()) return false;
        MicroVMNetworkSpec s = (MicroVMNetworkSpec) o;
        return Objects.equals(subnetIds, s.subnetIds)
                && Objects.equals(securityGroupIds, s.securityGroupIds)
                && Objects.equals(operatorRoleArn, s.operatorRoleArn)
                && Objects.equals(networkProtocol, s.networkProtocol)
                && Objects.equals(region, s.region);
    }

    @Override
    public int hashCode() { return Objects.hash(subnetIds, securityGroupIds, operatorRoleArn, networkProtocol, region); }
}
