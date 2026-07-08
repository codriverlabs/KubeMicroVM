package ai.codriverlabs.microvm.operator.core.model;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.Objects;

@JsonInclude(JsonInclude.Include.NON_NULL)
public class MicroVMReplicaSetSpec {
    private Integer replicas;
    private MicroVMSpec template;
    private Integer minReady;
    private Integer maxSurge;
    /** Scale-down behaviour configuration. */
    private ScaleDownSpec scaleDown;
    /** Desired state for all child MicroVMs: Running (default) | Suspended. */
    private String desiredReplicaSetState = "Running";
    /**
     * Update strategy type: RollingUpdate (default) | Recreate.
     * RollingUpdate: creates new VMs one-by-one, terminates old ones after new are Running.
     * Recreate: terminates all existing VMs then creates new ones.
     */
    private String updateStrategyType = "RollingUpdate";
    /**
     * Maximum number of VMs that can be unavailable during a rolling update. Default: 1.
     * Only used when updateStrategyType=RollingUpdate.
     */
    private Integer maxUnavailable = 1;

    public MicroVMReplicaSetSpec() {}

    public Integer getReplicas() { return replicas; }
    public void setReplicas(Integer replicas) { this.replicas = replicas; }
    public MicroVMSpec getTemplate() { return template; }
    public void setTemplate(MicroVMSpec template) { this.template = template; }
    public Integer getMinReady() { return minReady; }
    public void setMinReady(Integer minReady) { this.minReady = minReady; }
    public Integer getMaxSurge() { return maxSurge; }
    public void setMaxSurge(Integer maxSurge) { this.maxSurge = maxSurge; }
    public ScaleDownSpec getScaleDown() { return scaleDown; }
    public void setScaleDown(ScaleDownSpec scaleDown) { this.scaleDown = scaleDown; }
    public String getDesiredReplicaSetState() { return desiredReplicaSetState; }
    public void setDesiredReplicaSetState(String desiredReplicaSetState) { this.desiredReplicaSetState = desiredReplicaSetState; }
    public String getUpdateStrategyType() { return updateStrategyType; }
    public void setUpdateStrategyType(String updateStrategyType) { this.updateStrategyType = updateStrategyType; }
    public Integer getMaxUnavailable() { return maxUnavailable; }
    public void setMaxUnavailable(Integer maxUnavailable) { this.maxUnavailable = maxUnavailable; }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (o == null || getClass() != o.getClass()) return false;
        MicroVMReplicaSetSpec s = (MicroVMReplicaSetSpec) o;
        return Objects.equals(replicas, s.replicas) && Objects.equals(template, s.template)
                && Objects.equals(minReady, s.minReady) && Objects.equals(maxSurge, s.maxSurge)
                && Objects.equals(scaleDown, s.scaleDown)
                && Objects.equals(desiredReplicaSetState, s.desiredReplicaSetState);
    }

    @Override
    public int hashCode() {
        return Objects.hash(replicas, template, minReady, maxSurge, scaleDown, desiredReplicaSetState);
    }

    @JsonInclude(JsonInclude.Include.NON_NULL)
    public static class ScaleDownSpec {
        /** MostRecentFirst (default) | OldestFirst | Random */
        private String policy = "MostRecentFirst";
        private Integer stabilizationWindowSeconds = 60;

        public ScaleDownSpec() {}

        public String getPolicy() { return policy; }
        public void setPolicy(String policy) { this.policy = policy; }
        public Integer getStabilizationWindowSeconds() { return stabilizationWindowSeconds; }
        public void setStabilizationWindowSeconds(Integer s) { this.stabilizationWindowSeconds = s; }
    }
}
