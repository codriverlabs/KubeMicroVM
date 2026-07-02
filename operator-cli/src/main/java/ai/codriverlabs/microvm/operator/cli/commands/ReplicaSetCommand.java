package ai.codriverlabs.microvm.operator.cli.commands;

import ai.codriverlabs.microvm.operator.core.model.MicroVMReplicaSet;
import ai.codriverlabs.microvm.operator.core.model.MicroVMReplicaSetStatus;
import io.fabric8.kubernetes.client.KubernetesClient;
import jakarta.inject.Inject;
import picocli.CommandLine;
import picocli.CommandLine.Command;
import picocli.CommandLine.Option;
import picocli.CommandLine.Parameters;

import java.util.List;

/**
 * kubectl microvm rs — manage MicroVMReplicaSet resources.
 *
 * Usage:
 *   kubectl microvm rs list
 *   kubectl microvm rs describe --name my-rs
 *   kubectl microvm rs scale --name my-rs --replicas 5
 */
@Command(name = "rs", description = "Manage MicroVMReplicaSet resources",
        mixinStandardHelpOptions = true,
        subcommands = {
                ReplicaSetCommand.RsListCommand.class,
                ReplicaSetCommand.RsDescribeCommand.class,
                ReplicaSetCommand.RsScaleCommand.class
        })
public class ReplicaSetCommand implements Runnable {

    @CommandLine.Spec
    CommandLine.Model.CommandSpec spec;

    @Override
    public void run() {
        spec.commandLine().usage(System.out);
    }

    @Command(name = "list", description = "List MicroVMReplicaSet resources", mixinStandardHelpOptions = true)
    public static class RsListCommand implements Runnable {

        @Option(names = {"-n", "--namespace"}, defaultValue = "default")
        String namespace;

        @Option(names = {"-A", "--all-namespaces"})
        boolean allNamespaces;

        @Inject KubernetesClient client;

        @Override
        public void run() {
            List<MicroVMReplicaSet> list = allNamespaces
                    ? client.resources(MicroVMReplicaSet.class).inAnyNamespace().list().getItems()
                    : client.resources(MicroVMReplicaSet.class).inNamespace(namespace).list().getItems();

            if (list.isEmpty()) { System.out.println("No MicroVMReplicaSet resources found."); return; }

            System.out.printf("%-30s  %7s  %7s  %7s  %s%n",
                    "NAME", "DESIRED", "CURRENT", "READY", "STATE");
            for (var rs : list) {
                MicroVMReplicaSetStatus s = rs.getStatus();
                System.out.printf("%-30s  %7s  %7s  %7s  %s%n",
                        rs.getMetadata().getName(),
                        rs.getSpec() != null ? rs.getSpec().getReplicas() : "-",
                        s != null ? s.getCurrentReplicas() : "-",
                        s != null ? s.getReadyReplicas() : "-",
                        rs.getSpec() != null ? rs.getSpec().getDesiredReplicaSetState() : "Running");
            }
        }
    }

    @Command(name = "describe", description = "Show details of a MicroVMReplicaSet", mixinStandardHelpOptions = true)
    public static class RsDescribeCommand implements Runnable {

        @Option(names = {"--name"}, required = true) String name;
        @Option(names = {"-n", "--namespace"}, defaultValue = "default") String namespace;

        @Inject KubernetesClient client;

        @Override
        public void run() {
            var rs = client.resources(MicroVMReplicaSet.class).inNamespace(namespace).withName(name).get();
            if (rs == null) {
                System.err.printf("MicroVMReplicaSet '%s' not found%n", name); System.exit(1); return;
            }
            var spec = rs.getSpec();
            var s = rs.getStatus();
            System.out.printf("Name:      %s%n", name);
            System.out.printf("Namespace: %s%n", namespace);
            System.out.println("\nSpec:");
            if (spec != null) {
                System.out.printf("  Replicas:           %s%n", spec.getReplicas());
                System.out.printf("  MinReady:           %s%n", spec.getMinReady());
                System.out.printf("  MaxSurge:           %s%n", spec.getMaxSurge());
                System.out.printf("  DesiredState:       %s%n", spec.getDesiredReplicaSetState());
                if (spec.getScaleDown() != null) {
                    System.out.printf("  ScaleDown.Policy:   %s%n", spec.getScaleDown().getPolicy());
                    System.out.printf("  ScaleDown.Window:   %ss%n",
                            spec.getScaleDown().getStabilizationWindowSeconds());
                }
            }
            System.out.println("\nStatus:");
            if (s == null) { System.out.println("  (not yet reconciled)"); }
            else {
                System.out.printf("  Ready/Current/Desired: %s/%s/%s%n",
                        s.getReadyReplicas(), s.getCurrentReplicas(), s.getDesiredReplicas());
                System.out.printf("  Suspended:             %s%n", s.getSuspendedReplicas());
                if (s.getConditions() != null) {
                    for (var c : s.getConditions()) {
                        System.out.printf("  %s=%s (%s)%n", c.getType(), c.getStatus(), c.getReason());
                    }
                }
            }
        }
    }

    @Command(name = "scale", description = "Scale a MicroVMReplicaSet", mixinStandardHelpOptions = true)
    public static class RsScaleCommand implements Runnable {

        @Parameters(index = "0", description = "ReplicaSet name")
        String name;

        @Option(names = {"--replicas"}, required = true) int replicas;
        @Option(names = {"-n", "--namespace"}, defaultValue = "default") String namespace;

        @Inject KubernetesClient client;

        @Override
        public void run() {
            var rs = client.resources(MicroVMReplicaSet.class).inNamespace(namespace).withName(name).get();
            if (rs == null) {
                System.err.printf("MicroVMReplicaSet '%s' not found%n", name); System.exit(1); return;
            }
            rs.getSpec().setReplicas(replicas);
            client.resource(rs).patch();
            System.out.printf("microvmreplicaset/%s scaled to %d%n", name, replicas);
        }
    }
}
