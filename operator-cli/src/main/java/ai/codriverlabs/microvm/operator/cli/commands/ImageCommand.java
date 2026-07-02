package ai.codriverlabs.microvm.operator.cli.commands;

import picocli.CommandLine;
import picocli.CommandLine.Command;

@Command(name = "image", description = "Manage MicroVM images",
    subcommands = {
        ImageCreateCommand.class,
        ImageListCommand.class,
        ImageDescribeCommand.class,
        ImageUpdateCommand.class,
        ImageDeleteCommand.class,
        ImageBaseImagesCommand.class,
        ImageVersionDeleteCommand.class
    },
    mixinStandardHelpOptions = true)
public class ImageCommand implements Runnable {

    @CommandLine.Spec
    CommandLine.Model.CommandSpec spec;

    @Override
    public void run() {
        // No subcommand given — print help
        spec.commandLine().usage(System.out);
    }
}
