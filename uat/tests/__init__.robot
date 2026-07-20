*** Settings ***
Documentation    KubeMicroVM UAT — User Guide Acceptance Tests
...
...    Validates that all user guide steps work exactly as documented.
...    Requires: operator deployed, namespace labelled, S3 fixtures uploaded.
...
...    Run all:  robot --outputdir results --exclude performance tests/
...    Run one:  robot --outputdir results tests/01_quick_start.robot
...    Smoke:    robot --outputdir results -i smoke tests/
...    Perf:     robot --outputdir results -i performance tests/
...
...    Performance tests are excluded by default (long-running, account-limit
...    dependent). Include explicitly with: -i performance
...
...    Each suite verifies cluster prerequisites before running.
...    If the operator is not installed, suites will fail with a clear message.
Resource         ../resources/cluster_setup.resource
Default Tags     functional
Suite Setup      Setup Cluster If Needed
