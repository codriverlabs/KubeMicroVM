package ai.codriverlabs.microvm.operator.cli.commands;

import ai.codriverlabs.microvm.operator.core.model.MicroVMNetwork;
import io.fabric8.kubernetes.client.KubernetesClient;
import jakarta.inject.Inject;
import picocli.CommandLine;
import picocli.CommandLine.Command;
import picocli.CommandLine.Option;

import java.util.List;

/**
 * kubectl microvm network — inspect MicroVMNetwork CRs.
 *
 * Create/delete are done via kubectl apply/delete (YAML-driven).
 * This command surfaces operator-managed status: connectorArn, connectorState, conditions.
 *
 * Usage:
 *   kubectl microvm network list
 *   kubectl microvm network list -n my-namespace
 *   kubectl microvm network describe --name my-vpc-egress
 */
@Command(name = "network", description = "Inspect MicroVMNetwork resources",
        mixinStandardHelpOptions = true,
        subcommands = {NetworkCommand.NetworkListCommand.class, NetworkCommand.NetworkDescribeCommand.class})
public class NetworkCommand implements Runnable {

    @CommandLine.Spec
    CommandLine.Model.CommandSpec spec;

    @Override
    public void run() {
        spec.commandLine().usage(System.out);
    }

    @Command(name = "list", description = "List MicroVMNetwork resources", mixinStandardHelpOptions = true)
    public static class NetworkListCommand implements Runnable {

        @Option(names = {"-n", "--namespace"}, defaultValue = "default", description = "Namespace (default: default)")
        String namespace;

        @Option(names = {"-A", "--all-namespaces"}, description = "List across all namespaces")
        boolean allNamespaces;

        @Inject
        KubernetesClient client;

        @Override
        public void run() {
            List<MicroVMNetwork> networks = allNamespaces
                    ? client.resources(MicroVMNetwork.class).inAnyNamespace().list().getItems()
                    : client.resources(MicroVMNetwork.class).inNamespace(namespace).list().getItems();

            if (networks.isEmpty()) {
                System.out.println("No MicroVMNetwork resources found.");
                return;
            }

            String fmt = allNamespaces
                    ? "%-20s  %-30s  %-10s  %s%n"
                    : "%-30s  %-10s  %s%n";

            if (allNamespaces) {
                System.out.printf(fmt, "NAMESPACE", "NAME", "STATE", "CONNECTOR ARN");
            } else {
                System.out.printf(fmt, "NAME", "STATE", "CONNECTOR ARN");
            }

            for (MicroVMNetwork n : networks) {
                String name = n.getMetadata().getName();
                String ns = n.getMetadata().getNamespace();
                String state = n.getStatus() != null ? orDash(n.getStatus().getConnectorState()) : "-";
                String arn = n.getStatus() != null ? orDash(n.getStatus().getConnectorArn()) : "-";
                if (allNamespaces) {
                    System.out.printf(fmt, ns, name, state, arn);
                } else {
                    System.out.printf(fmt, name, state, arn);
                }
            }
        }
    }

    @Command(name = "describe", description = "Show details of a MicroVMNetwork", mixinStandardHelpOptions = true)
    public static class NetworkDescribeCommand implements Runnable {

        @Option(names = {"--name"}, required = true, description = "Name of the MicroVMNetwork")
        String name;

        @Option(names = {"-n", "--namespace"}, defaultValue = "default", description = "Namespace")
        String namespace;

        @Inject
        KubernetesClient client;

        @Override
        public void run() {
            MicroVMNetwork network = client.resources(MicroVMNetwork.class)
                    .inNamespace(namespace).withName(name).get();

            if (network == null) {
                System.err.printf("Error: MicroVMNetwork \"%s\" not found in namespace \"%s\"%n", name, namespace);
                System.exit(1);
                return;
            }

            var spec = network.getSpec();
            var status = network.getStatus();

            System.out.printf("Name:       %s%n", name);
            System.out.printf("Namespace:  %s%n", namespace);
            System.out.println();
            System.out.println("Spec:");
            if (spec != null) {
                System.out.printf("  SubnetIds:       %s%n", spec.getSubnetIds());
                System.out.printf("  SecurityGroups:  %s%n", spec.getSecurityGroupIds());
                System.out.printf("  Protocol:        %s%n", orDash(spec.getNetworkProtocol()));
                System.out.printf("  OperatorRoleArn: %s%n", orDash(spec.getOperatorRoleArn()));
                System.out.printf("  Region:          %s%n", orDash(spec.getRegion()));
            }
            System.out.println();
            System.out.println("Status:");
            if (status == null) {
                System.out.println("  (not yet reconciled)");
            } else {
                System.out.printf("  ConnectorArn:   %s%n", orDash(status.getConnectorArn()));
                System.out.printf("  ConnectorId:    %s%n", orDash(status.getConnectorId()));
                System.out.printf("  State:          %s%n", orDash(status.getConnectorState()));
                if (status.getStateReason() != null) {
                    System.out.printf("  StateReason:    %s%n", status.getStateReason());
                }
                if (status.getConditions() != null && !status.getConditions().isEmpty()) {
                    System.out.println("  Conditions:");
                    for (var c : status.getConditions()) {
                        System.out.printf("    %s=%s (%s)%n",
                                c.getType(), c.getStatus(), orDash(c.getReason()));
                    }
                }
            }
        }
    }

    private static String orDash(String s) {
        return s != null ? s : "-";
    }
}
