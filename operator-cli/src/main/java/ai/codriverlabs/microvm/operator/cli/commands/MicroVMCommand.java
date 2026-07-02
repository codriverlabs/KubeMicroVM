package ai.codriverlabs.microvm.operator.cli.commands;

import io.quarkus.picocli.runtime.annotations.TopCommand;
import picocli.CommandLine;
import picocli.CommandLine.Command;

/**
 * Root command for the microvm CLI.
 * Installed as 'microvm' (primary) with a 'kubectl-microvm' symlink
 * so both `microvm` and `kubectl microvm` work.
 */
@TopCommand
@Command(
    name = "microvm",
    description = "CLI for managing AWS Lambda MicroVMs on Kubernetes",
    mixinStandardHelpOptions = true,
    version = "1.0.0-SNAPSHOT",
    subcommands = {
        CreateCommand.class,
        ListCommand.class,
        DescribeCommand.class,
        DeleteCommand.class,
        PauseCommand.class,
        ResumeCommand.class,
        StopCommand.class,
        StartCommand.class,
        LogsCommand.class,
        ExecCommand.class,
        ReplicaSetCommand.class,
        ImageCommand.class,
        TokenCommand.class,
        NetworkCommand.class
    }
)
public class MicroVMCommand implements Runnable {

    @CommandLine.Spec
    CommandLine.Model.CommandSpec spec;

    @Override
    public void run() {
        spec.commandLine().usage(System.out);
    }
}
