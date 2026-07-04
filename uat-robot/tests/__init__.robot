*** Settings ***
Documentation    KubeMicroVM UAT — User Guide Acceptance Tests
...
...    Validates that all user guide steps work exactly as documented.
...    Requires: operator deployed, namespace labelled, S3 fixtures uploaded.
...
...    Run all:  robot --outputdir results tests/
...    Run one:  robot --outputdir results tests/01_quick_start.robot
...    Smoke:    robot --outputdir results -i smoke tests/
...
...    Each suite verifies cluster prerequisites before running.
...    If the operator is not installed, suites will fail with a clear message.
Resource         ../resources/cluster_setup.resource
Suite Setup      Setup Cluster If Needed
