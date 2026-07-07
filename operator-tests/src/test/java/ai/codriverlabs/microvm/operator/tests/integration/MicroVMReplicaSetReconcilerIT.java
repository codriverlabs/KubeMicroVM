package ai.codriverlabs.microvm.operator.tests.integration;

import ai.codriverlabs.microvm.operator.controller.quota.QuotaGuard;
import ai.codriverlabs.microvm.operator.controller.reconciler.MicroVMReplicaSetReconciler;
import ai.codriverlabs.microvm.operator.controller.spi.DefaultQuotaPolicy;
import ai.codriverlabs.microvm.operator.core.enums.DesiredState;
import ai.codriverlabs.microvm.operator.core.enums.MicroVMState;
import ai.codriverlabs.microvm.operator.core.model.*;
import io.fabric8.kubernetes.api.model.ObjectMetaBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.server.mock.EnableKubernetesMockClient;
import io.javaoperatorsdk.operator.api.reconciler.Context;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

@EnableKubernetesMockClient(crud = true)
class MicroVMReplicaSetReconcilerIT {

    KubernetesClient client;
    MicroVMReplicaSetReconciler reconciler;

    /** Standard QuotaGuard for most tests — AWS defaults, no rate-limiting delay. */
    private static QuotaGuard testQuotaGuard() {
        // Use rate=100 for all limits so tests don't block on token bucket waits
        return new QuotaGuard(new DefaultQuotaPolicy(),
                100, 100, 100, 100, 100, 100, 100, 10, 200);
    }

    @BeforeEach
    void setUp() {
        reconciler = new MicroVMReplicaSetReconciler(client, testQuotaGuard());
    }

    // ── Original 5 tests (updated: QuotaGuard injected via testQuotaGuard()) ───

    @Test
    @DisplayName("SCALE-UP: creates N children when currentReplicas < spec.replicas")
    void scaleUp_createsChildren() {
        var rs = testReplicaSet("my-rs", 3);
        client.resource(rs).create();

        // With rate=100, maxCreatesPerCycle=50. 3 children created in first cycle.
        reconciler.reconcile(rs, mockContext());

        List<MicroVM> children = client.resources(MicroVM.class).inNamespace("default")
                .withLabel(MicroVMReplicaSetReconciler.OWNER_LABEL, "my-rs").list().getItems();
        assertEquals(3, children.size(), "Should have created 3 child MicroVMs");
        children.forEach(c -> assertFalse(c.getMetadata().getOwnerReferences().isEmpty()));
    }

    @Test
    @DisplayName("SCALE-DOWN: sets desiredState=Terminated on excess children")
    void scaleDown_terminatesExcess() {
        var rs = testReplicaSet("my-rs", 2);
        client.resource(rs).create();
        for (int i = 0; i < 4; i++) {
            client.resource(runningChild("my-rs", "child-" + i)).create();
        }

        reconciler.reconcile(rs, mockContext());

        List<MicroVM> terminated = client.resources(MicroVM.class).inNamespace("default")
                .withLabel(MicroVMReplicaSetReconciler.OWNER_LABEL, "my-rs").list().getItems()
                .stream()
                .filter(c -> c.getSpec() != null
                        && DesiredState.TERMINATED == c.getSpec().getDesiredState())
                .toList();
        assertEquals(2, terminated.size(), "Should have set 2 children to TERMINATED");
    }

    @Test
    @DisplayName("HEALTH EVICTION: unexpected TERMINATED child (desired=Running) is deleted and replaced")
    void healthEviction_replacesUnexpectedlyTerminatedChild() {
        var rs = testReplicaSet("my-rs", 1);
        client.resource(rs).create();
        var terminated = runningChild("my-rs", "child-terminated");
        terminated.getSpec().setDesiredState(DesiredState.RUNNING);
        terminated.getStatus().setState(MicroVMState.TERMINATED);
        client.resource(terminated).create();

        reconciler.reconcile(rs, mockContext());

        List<MicroVM> children = client.resources(MicroVM.class).inNamespace("default")
                .withLabel(MicroVMReplicaSetReconciler.OWNER_LABEL, "my-rs").list().getItems();
        boolean unexpectedChildGone = children.stream()
                .noneMatch(c -> "child-terminated".equals(c.getMetadata().getName()));
        assertTrue(unexpectedChildGone, "Unexpectedly terminated child should have been evicted");
        assertEquals(1, children.size(), "A replacement child should have been created");
    }

    @Test
    @DisplayName("SUSPEND CASCADE: sets desiredState=Suspended on all children")
    void suspendCascade_patchesAllChildren() {
        var rs = testReplicaSet("my-rs", 2);
        rs.getSpec().setDesiredReplicaSetState("Suspended");
        client.resource(rs).create();
        for (int i = 0; i < 2; i++) {
            client.resource(runningChild("my-rs", "child-" + i)).create();
        }

        reconciler.reconcile(rs, mockContext());

        List<MicroVM> children = client.resources(MicroVM.class).inNamespace("default")
                .withLabel(MicroVMReplicaSetReconciler.OWNER_LABEL, "my-rs").list().getItems();
        children.forEach(c -> assertEquals(DesiredState.SUSPENDED, c.getSpec().getDesiredState(),
                "All children should be Suspended"));
    }

    @Test
    @DisplayName("STATUS: updates readyReplicas and currentReplicas correctly")
    void status_updatedAfterReconcile() {
        var rs = testReplicaSet("my-rs", 2);
        client.resource(rs).create();
        for (int i = 0; i < 2; i++) {
            client.resource(runningChild("my-rs", "child-" + i)).create();
        }

        reconciler.reconcile(rs, mockContext());

        assertNotNull(rs.getStatus());
        assertEquals(2, rs.getStatus().getCurrentReplicas());
        assertEquals(2, rs.getStatus().getReadyReplicas());
        assertEquals(2, rs.getStatus().getDesiredReplicas());
    }

    // ── QuotaGuard wiring tests ───────────────────────────────────────────────

    @Test
    @DisplayName("QUOTA: suspend cascade acquires suspendMicrovm rate-limit once per child")
    void suspendCascade_acquiresRateLimitPerChild() {
        AtomicInteger suspendAcquireCount = new AtomicInteger(0);
        var countingGuard = new QuotaGuard(new DefaultQuotaPolicy(),
                100, 100, 100, 100, 100, 100, 100, 10, 200) {
            @Override
            public <T> CompletableFuture<T> suspendMicrovm(Supplier<CompletableFuture<T>> call) {
                suspendAcquireCount.incrementAndGet();
                return call.get();
            }
        };
        var rec = new MicroVMReplicaSetReconciler(client, countingGuard);

        var rs = testReplicaSet("rs-suspend", 3);
        rs.getSpec().setDesiredReplicaSetState("Suspended");
        client.resource(rs).create();
        for (int i = 0; i < 3; i++) {
            client.resource(runningChild("rs-suspend", "child-" + i)).create();
        }

        rec.reconcile(rs, mockContext());

        assertEquals(3, suspendAcquireCount.get(),
                "suspendMicrovm rate-limit should be acquired once per child being suspended");
    }

    @Test
    @DisplayName("QUOTA: resume cascade acquires resumeMicrovm rate-limit once per child")
    void resumeCascade_acquiresRateLimitPerChild() {
        AtomicInteger resumeAcquireCount = new AtomicInteger(0);
        var countingGuard = new QuotaGuard(new DefaultQuotaPolicy(),
                100, 100, 100, 100, 100, 100, 100, 10, 200) {
            @Override
            public <T> CompletableFuture<T> resumeMicrovm(Supplier<CompletableFuture<T>> call) {
                resumeAcquireCount.incrementAndGet();
                return call.get();
            }
        };
        var rec = new MicroVMReplicaSetReconciler(client, countingGuard);

        var rs = testReplicaSet("rs-resume", 2);
        rs.getSpec().setDesiredReplicaSetState("Running");
        client.resource(rs).create();
        // Children are currently Suspended — need to be resumed
        for (int i = 0; i < 2; i++) {
            var child = runningChild("rs-resume", "child-" + i);
            child.getSpec().setDesiredState(DesiredState.SUSPENDED);
            child.getStatus().setState(MicroVMState.SUSPENDED);
            client.resource(child).create();
        }

        rec.reconcile(rs, mockContext());

        assertEquals(2, resumeAcquireCount.get(),
                "resumeMicrovm rate-limit should be acquired once per child being resumed");
    }

    @Test
    @DisplayName("QUOTA: maxCreatesPerCycle derived from RunMicrovm rate")
    void maxCreatesPerCycle_derivedFromRunMicrovmRate() {
        // rate=2 → max(1, 2/2)=1; rate=5 → max(1, 5/2)=2; rate=10 → max(1, 10/2)=5
        assertMaxCreatesForRate(2, 1);
        assertMaxCreatesForRate(5, 2);
        assertMaxCreatesForRate(10, 5);
    }

    @Test
    @DisplayName("QUOTA: reconciler construction with QuotaGuard — runMicrovmRatePerSecond() accessible")
    void construction_withQuotaGuard_rateAccessible() {
        var guard = new QuotaGuard(new DefaultQuotaPolicy(), 5, 10, 2, 5, 100, 50, 5, 10, 200);
        var rec = new MicroVMReplicaSetReconciler(client, guard);
        assertNotNull(rec, "Reconciler should be constructable with QuotaGuard");
        assertEquals(5, guard.runMicrovmRatePerSecond(),
                "runMicrovmRatePerSecond() should return configured value");
    }

    // --- helpers ---

    private void assertMaxCreatesForRate(int runMicrovmRate, int expectedMax) {
        var guard = new QuotaGuard(new DefaultQuotaPolicy(),
                runMicrovmRate, 10, 2, 5, 100, 50, 5, 10, 200);
        var rec = new MicroVMReplicaSetReconciler(client, guard);

        String rsName = "rs-creates-" + runMicrovmRate;
        var rs = testReplicaSet(rsName, 100);
        client.resource(rs).create();

        rec.reconcile(rs, mockContext());

        int created = client.resources(MicroVM.class).inNamespace("default")
                .withLabel(MicroVMReplicaSetReconciler.OWNER_LABEL, rsName)
                .list().getItems().size();
        assertEquals(expectedMax, created,
                "With RunMicrovm rate=" + runMicrovmRate + ", should create " + expectedMax + " per cycle");

        client.resources(MicroVM.class).inNamespace("default")
                .withLabel(MicroVMReplicaSetReconciler.OWNER_LABEL, rsName).delete();
        client.resource(rs).delete();
    }

    private MicroVMReplicaSet testReplicaSet(String name, int replicas) {
        var rs = new MicroVMReplicaSet();
        rs.setMetadata(new ObjectMetaBuilder()
                .withName(name).withNamespace("default")
                .withUid("uid-" + name).withGeneration(1L).build());
        var spec = new MicroVMReplicaSetSpec();
        spec.setReplicas(replicas);
        var template = new MicroVMSpec();
        template.setImageRef("arn:aws:lambda:us-east-1:123:microvm-image:test");
        spec.setTemplate(template);
        rs.setSpec(spec);
        return rs;
    }

    private MicroVM runningChild(String rsName, String childName) {
        var vm = new MicroVM();
        vm.setMetadata(new ObjectMetaBuilder()
                .withName(childName).withNamespace("default")
                .addToLabels(MicroVMReplicaSetReconciler.OWNER_LABEL, rsName)
                .withCreationTimestamp("2026-06-29T00:00:00Z")
                .build());
        var spec = new MicroVMSpec();
        spec.setImageRef("arn:aws:lambda:us-east-1:123:microvm-image:test");
        spec.setDesiredState(DesiredState.RUNNING);
        vm.setSpec(spec);
        var status = new MicroVMStatus();
        status.setState(MicroVMState.RUNNING);
        vm.setStatus(status);
        return vm;
    }

    @SuppressWarnings("unchecked")
    private Context<MicroVMReplicaSet> mockContext() {
        Context<MicroVMReplicaSet> ctx = mock(Context.class);
        when(ctx.getClient()).thenReturn(client);
        return ctx;
    }
}
