#!/usr/bin/env python3
"""Append a simulator-only UI test target without affecting device builds."""
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "ios/project.yml"
text = path.read_text()
text = text.replace("        SWIFT_OBJC_BRIDGING_HEADER:", "        CODE_SIGN_ENTITLEMENTS: NodeScope/Simulator.entitlements\n        SWIFT_OBJC_BRIDGING_HEADER:")
target = """  NodeScopeTests:
    type: bundle.unit-test
    platform: iOS
    sources: [NodeScopeTests]
    dependencies:
      - target: NodeScope
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.nodescope.tests
        GENERATE_INFOPLIST_FILE: YES
  NodeScopeUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: [NodeScopeUITests]
    dependencies:
      - target: NodeScope
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.nodescope.uitests
        GENERATE_INFOPLIST_FILE: YES
        TEST_TARGET_NAME: NodeScope
"""
text = text.replace("schemes:\n", target + "schemes:\n")
text = text.replace("    run:\n", "    test:\n      targets: [NodeScopeTests, NodeScopeUITests]\n    run:\n")
path.write_text(text)
