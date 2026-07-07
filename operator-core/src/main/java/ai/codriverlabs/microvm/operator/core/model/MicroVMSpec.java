package ai.codriverlabs.microvm.operator.core.model;

import ai.codriverlabs.microvm.operator.core.enums.DesiredState;
import com.fasterxml.jackson.annotation.*;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Spec for MicroVM CR — aligned with AWS Lambda MicroVMs RunMicrovm API (2025-09-09).
 * Memory/vCPU sizing is inherited from the referenced MicroVMImage.
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public class MicroVMSpec {

    // Image reference
    private String imageRef;
    private String imageVersion;

    /**
     * Optional reference to a MicroVMClass that defines runtime defaults
     * (idle policy, networking, sizing). Fields explicitly set in this spec
     * take precedence over the class values.
     */
    private String className;

    // Networking — ARNs for inbound/outbound connectors (see docs/aws-microvms-official/05-networking.md)
    private List<String> ingressNetworkConnectors = new ArrayList<>();
    private List<String> egressNetworkConnectors = new ArrayList<>();
    /** Reference to a MicroVMNetwork CR (operator resolves to egress connector ARN) */
    private String networkRef;

    // Runtime
    private String executionRoleArn;
    private String runHookPayload;
    private String templateRef;
    private DesiredState desiredState;
    private String region;
    /**
     * Optional: import an existing MicroVM into Kubernetes management.
     * When set and status.microVmId is null, the reconciler calls GetMicrovm
     * to adopt the existing VM rather than calling RunMicrovm.
     * Immutable after creation. Must match pattern: microvm-[a-f0-9-]{36}
     */
    private String importMicroVmId;

    // Idle policy
    private Integer maxIdleDurationSeconds;
    private Integer suspendedDurationSeconds;
    private Boolean autoResumeEnabled;
    private Integer maximumDurationSeconds;

    // Tags
    private Map<String, String> tags;

    @JsonIgnore
    private final Map<String, Object> additionalProperties = new LinkedHashMap<>();

    public MicroVMSpec() {}

    public String getImageRef() { return imageRef; }
    public void setImageRef(String imageRef) { this.imageRef = imageRef; }

    public String getImageVersion() { return imageVersion; }
    public void setImageVersion(String imageVersion) { this.imageVersion = imageVersion; }

    public String getClassName() { return className; }
    public void setClassName(String className) { this.className = className; }

    public List<String> getIngressNetworkConnectors() { return ingressNetworkConnectors; }
    public void setIngressNetworkConnectors(List<String> v) { this.ingressNetworkConnectors = v; }

    public List<String> getEgressNetworkConnectors() { return egressNetworkConnectors; }
    public void setEgressNetworkConnectors(List<String> v) { this.egressNetworkConnectors = v; }

    public String getNetworkRef() { return networkRef; }
    public void setNetworkRef(String networkRef) { this.networkRef = networkRef; }

    public String getExecutionRoleArn() { return executionRoleArn; }
    public void setExecutionRoleArn(String executionRoleArn) { this.executionRoleArn = executionRoleArn; }

    public String getRunHookPayload() { return runHookPayload; }
    public void setRunHookPayload(String runHookPayload) { this.runHookPayload = runHookPayload; }

    public String getTemplateRef() { return templateRef; }
    public void setTemplateRef(String templateRef) { this.templateRef = templateRef; }

    public DesiredState getDesiredState() { return desiredState; }
    public void setDesiredState(DesiredState desiredState) { this.desiredState = desiredState; }

    public String getRegion() { return region; }
    public void setRegion(String region) { this.region = region; }

    public String getImportMicroVmId() { return importMicroVmId; }
    public void setImportMicroVmId(String importMicroVmId) { this.importMicroVmId = importMicroVmId; }

    public Integer getMaxIdleDurationSeconds() { return maxIdleDurationSeconds; }
    public void setMaxIdleDurationSeconds(Integer maxIdleDurationSeconds) { this.maxIdleDurationSeconds = maxIdleDurationSeconds; }

    public Integer getSuspendedDurationSeconds() { return suspendedDurationSeconds; }
    public void setSuspendedDurationSeconds(Integer suspendedDurationSeconds) { this.suspendedDurationSeconds = suspendedDurationSeconds; }

    public Boolean getAutoResumeEnabled() { return autoResumeEnabled; }
    public void setAutoResumeEnabled(Boolean autoResumeEnabled) { this.autoResumeEnabled = autoResumeEnabled; }

    public Integer getMaximumDurationSeconds() { return maximumDurationSeconds; }
    public void setMaximumDurationSeconds(Integer maximumDurationSeconds) { this.maximumDurationSeconds = maximumDurationSeconds; }

    public Map<String, String> getTags() { return tags; }
    public void setTags(Map<String, String> tags) { this.tags = tags; }

    @JsonAnyGetter
    public Map<String, Object> getAdditionalProperties() { return additionalProperties; }

    @JsonAnySetter
    public void setAdditionalProperty(String name, Object value) { additionalProperties.put(name, value); }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof MicroVMSpec that)) return false;
        return Objects.equals(imageRef, that.imageRef) &&
               Objects.equals(desiredState, that.desiredState) &&
               Objects.equals(ingressNetworkConnectors, that.ingressNetworkConnectors);
    }

    @Override
    public int hashCode() { return Objects.hash(imageRef, desiredState, ingressNetworkConnectors); }

    @Override
    public String toString() {
        return "MicroVMSpec{imageRef=" + imageRef + ", desiredState=" + desiredState + "}";
    }
}
