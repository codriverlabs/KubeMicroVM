package ai.codriverlabs.microvm.operator.core.model;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

@JsonIgnoreProperties(ignoreUnknown = true)
public class MicroVMImageSpec {

    private MicroVMImageSource source;
    private String baseImageArn;
    private String buildRoleArn;
    private Integer buildTimeoutSeconds;
    private Boolean autoActivate;
    private String region;
    /** Baseline memory in MiB. Valid: 512, 1024, 2048, 4096, 8192. Omit for AWS default (2048). */
    private Integer memorySizeMiB;
    /**
     * Optional: maximum number of image versions to retain.
     * After each successful version activation, versions beyond this count
     * (oldest first) are automatically deleted via DeleteMicrovmImageVersion.
     * Must be >= 1 if set. Default: null (no automatic pruning).
     */
    private Integer maxVersionsToKeep;

    public MicroVMImageSource getSource() { return source; }
    public void setSource(MicroVMImageSource source) { this.source = source; }

    public String getBaseImageArn() { return baseImageArn; }
    public void setBaseImageArn(String baseImageArn) { this.baseImageArn = baseImageArn; }

    public String getBuildRoleArn() { return buildRoleArn; }
    public void setBuildRoleArn(String buildRoleArn) { this.buildRoleArn = buildRoleArn; }

    public Integer getBuildTimeoutSeconds() { return buildTimeoutSeconds; }
    public void setBuildTimeoutSeconds(Integer buildTimeoutSeconds) { this.buildTimeoutSeconds = buildTimeoutSeconds; }

    public Boolean getAutoActivate() { return autoActivate; }
    public void setAutoActivate(Boolean autoActivate) { this.autoActivate = autoActivate; }

    public String getRegion() { return region; }
    public void setRegion(String region) { this.region = region; }

    public Integer getMemorySizeMiB() { return memorySizeMiB; }
    public void setMemorySizeMiB(Integer memorySizeMiB) { this.memorySizeMiB = memorySizeMiB; }

    public Integer getMaxVersionsToKeep() { return maxVersionsToKeep; }
    public void setMaxVersionsToKeep(Integer maxVersionsToKeep) { this.maxVersionsToKeep = maxVersionsToKeep; }
}
