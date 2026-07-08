package ai.codriverlabs.microvm.operator.core.model;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.List;

@JsonInclude(JsonInclude.Include.NON_NULL)
public class MicroVMReplicaSetStatus {
    private Integer readyReplicas;       // state == RUNNING
    private Integer currentReplicas;     // total children
    private Integer desiredReplicas;     // from spec.replicas
    private Integer suspendedReplicas;   // state == SUSPENDED
    private Integer updatedReplicas;     // matching current template generation
    /** Hash of spec.template used to detect rolling update triggers. */
    private String currentTemplateHash;
    private Long observedGeneration;
    private List<Condition> conditions;

    public MicroVMReplicaSetStatus() {}

    public Integer getReadyReplicas() { return readyReplicas; }
    public void setReadyReplicas(Integer readyReplicas) { this.readyReplicas = readyReplicas; }
    public Integer getCurrentReplicas() { return currentReplicas; }
    public void setCurrentReplicas(Integer currentReplicas) { this.currentReplicas = currentReplicas; }
    public Integer getDesiredReplicas() { return desiredReplicas; }
    public void setDesiredReplicas(Integer desiredReplicas) { this.desiredReplicas = desiredReplicas; }
    public Integer getSuspendedReplicas() { return suspendedReplicas; }
    public void setSuspendedReplicas(Integer suspendedReplicas) { this.suspendedReplicas = suspendedReplicas; }
    public Integer getUpdatedReplicas() { return updatedReplicas; }
    public void setUpdatedReplicas(Integer updatedReplicas) { this.updatedReplicas = updatedReplicas; }
    public String getCurrentTemplateHash() { return currentTemplateHash; }
    public void setCurrentTemplateHash(String currentTemplateHash) { this.currentTemplateHash = currentTemplateHash; }
    public Long getObservedGeneration() { return observedGeneration; }
    public void setObservedGeneration(Long observedGeneration) { this.observedGeneration = observedGeneration; }
    public List<Condition> getConditions() { return conditions; }
    public void setConditions(List<Condition> conditions) { this.conditions = conditions; }
}
