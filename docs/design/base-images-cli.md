# Design: ListManagedMicrovmImages in CLI (`microvm image base-images`)

**Status**: Client exists, CLI command stub exists — wire-up needed  
**Branch**: `feature/base-images-cli`  
**Priority**: P2

---

## What Exists

- `MicroVMImageClient.listManagedImages()` — calls `ListManagedMicrovmImages`
- `MicroVMImageClient.listManagedImageVersions(imageArn)` — calls `ListManagedMicrovmImageVersions`
- `ImageBaseImagesCommand.java` — command skeleton exists

## What Is Missing

`ImageBaseImagesCommand` is not wired to the actual API calls. Currently it may print nothing or throw an error. The command is referenced in README (`microvm image base-images`).

## Implementation Plan

### `ImageBaseImagesCommand` (operator-cli)

```java
@Command(name = "base-images", description = "List AWS-managed base images")
public class ImageBaseImagesCommand implements Runnable {

    @Inject MicroVMImageClient imageClient;

    @Option(names = {"-o", "--output"}, defaultValue = "table")
    String output;

    @Override
    public void run() {
        try {
            List<ManagedImageSummary> images = imageClient.listManagedImages()
                .get(30, TimeUnit.SECONDS);
            if (images.isEmpty()) {
                System.out.println("No managed base images found.");
                return;
            }
            // Table format: ARN | Name | Description
            System.out.printf("%-65s  %-30s  %s%n", "ARN", "Name", "Description");
            System.out.println("-".repeat(120));
            for (var img : images) {
                System.out.printf("%-65s  %-30s  %s%n",
                    img.imageArn(), img.name(), img.description());
            }
        } catch (Exception e) {
            System.err.println("Error listing base images: " + e.getMessage());
            System.exit(1);
        }
    }
}
```

### `microvm image base-images --versions <arn>` (optional subcommand)

List versions of a specific managed image:
```bash
microvm image base-images --versions arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1
```

## Integration Test

```java
@Test
void baseImages_listsManagedImages() {
    when(mockImageClient.listManagedImages()).thenReturn(
        CompletableFuture.completedFuture(List.of(
            new ManagedImageSummary("arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1",
                "al2023-1", "Amazon Linux 2023 base image"))));

    // Execute command, verify output contains ARN and name
}
```

## E2E Test

```bash
microvm image base-images
# Expected: table with at least one row containing "al2023-1"
```

## Implementation Checklist

- [ ] Implement `ImageBaseImagesCommand.run()` — call `listManagedImages()`
- [ ] Table output format (ARN, Name, Description)
- [ ] JSON output with `--output json`
- [ ] Optional: `--versions <arn>` to list versions of a managed image
- [ ] Integration test
- [ ] E2E: `microvm image base-images` returns at least the al2023-1 image
- [ ] Update `docs/user-guides/cli-reference.md`
